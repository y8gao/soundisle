import AVFoundation
import Combine
import Foundation

/// Plays one file at a time on an `AVAudioEngine`, publishing position,
/// duration and (when enabled) a 24-band spectrum.
///
/// All published state is updated on the main queue. Spectrum analysis is
/// opt-in so normal playback pays for neither the tap nor the FFT.
public final class PlayerEngine: ObservableObject {
    public static let bandCount = SpectrumAnalyzer.bandCount

    @Published public private(set) var isPlaying = false
    @Published public private(set) var position: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var spectrum: [Float] = Array(repeating: 0, count: PlayerEngine.bandCount)
    /// Reason for the most recent load/start/seek failure, for the UI.
    @Published public private(set) var lastError: String?

    /// Called on the main queue after the scheduled segment finishes naturally.
    public var onFinish: (() -> Void)?

    /// Set by the app when a spectrum view is on screen (mini window visible
    /// or the main player bar spectrum enabled). The tap is only installed
    /// while this is true *and* audio is playing, so paused playback costs
    /// nothing.
    public var isSpectrumEnabled = false {
        didSet {
            guard isSpectrumEnabled != oldValue else { return }
            updateTapInstallation()
            if !isSpectrumEnabled {
                startSpectrumDecay()
            }
        }
    }

    private static let spectrumInterval: TimeInterval = 1.0 / 20.0

    /// Created on first use. Building an `AVAudioEngine` talks to CoreAudio's
    /// HAL, which can block for seconds during app launch; deferring it keeps
    /// the first window frame instant and playback startup predictable.
    private var engine: AVAudioEngine?
    private let playerNode = AVAudioPlayerNode()
    private var analyzer = SpectrumAnalyzer()
    private var monoBuffer = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize)
    private var bandScratch = [Float](repeating: 0, count: PlayerEngine.bandCount)

    public init() {}

    private var file: AVAudioFile?
    private var segmentStartFrame: AVAudioFramePosition = 0
    private var segmentScheduled = false
    private var pausedPosition: TimeInterval = 0
    /// Bumped whenever playback is stopped or rescheduled so stale completion
    /// callbacks from `playerNode.stop()` are ignored.
    private var generation = 0
    private var positionTimer: Timer?
    private var tapInstalled = false
    private var lastSpectrumPublish: TimeInterval = 0
    private var spectrumDecayTimer: Timer?

    deinit {
        positionTimer?.invalidate()
        spectrumDecayTimer?.invalidate()
        if let engine {
            engine.stop()
            if tapInstalled {
                engine.mainMixerNode.removeTap(onBus: 0)
            }
        }
    }

    private func ensureEngine() -> AVAudioEngine {
        if let engine { return engine }
        let engine = AVAudioEngine()
        engine.attach(playerNode)
        // On some LaunchServices sessions CoreAudio's HAL blocks inside
        // `mainMixerNode`/the output unit. This call is synchronous, so the app
        // cannot surface that as an error; it only reports success once
        // `isPlaying` becomes true after `play()`.
        if isSpectrumEnabled && isPlaying {
            installTap(on: engine)
        }
        self.engine = engine
        return engine
    }

    private func installTap(on engine: AVAudioEngine) {
        guard !tapInstalled else { return }
        engine.mainMixerNode.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(SpectrumAnalyzer.fftSize),
            format: nil
        ) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }
        tapInstalled = true
    }

    /// Taps exist only while someone consumes spectrum data and audio is
    /// running; pausing or hiding the last spectrum view removes the tap.
    private func updateTapInstallation() {
        guard let engine else { return }
        if isSpectrumEnabled && isPlaying {
            if !tapInstalled {
                installTap(on: engine)
            }
        } else if tapInstalled {
            engine.mainMixerNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    // MARK: - Controls

    public func load(url: URL) throws {
        lastError = nil
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            lastError = Lf("无法读取音频文件（%@）", error.localizedDescription)
            throw error
        }

        generation += 1
        playerNode.stop()
        engine?.stop()
        stopPositionTimer()

        self.file = file
        duration = Double(file.length) / file.processingFormat.sampleRate
        pausedPosition = 0
        position = 0
        isPlaying = false
        updateTapInstallation()
        stopSpectrumDecay()
        spectrum = Array(repeating: 0, count: Self.bandCount)

        let engine = ensureEngine()
        engine.connect(playerNode, to: engine.mainMixerNode, format: file.processingFormat)
        scheduleSegment(fromFrame: 0)
    }

    public func play() {
        lastError = nil
        guard file != nil else {
            lastError = L("没有加载音频文件")
            return
        }
        let engine = ensureEngine()
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                lastError = Lf("音频引擎启动失败（%@）", error.localizedDescription)
                isPlaying = false
                return
            }
        }

        if !segmentScheduled {
            scheduleSegment(fromFrame: 0)
            pausedPosition = 0
            position = 0
        }

        playerNode.play()
        isPlaying = true
        stopSpectrumDecay()
        updateTapInstallation()
        startPositionTimer()
    }

    public func pause() {
        guard isPlaying else { return }
        let current = currentPlaybackPosition
        playerNode.pause()
        pausedPosition = current
        position = current
        isPlaying = false
        updateTapInstallation()
        startSpectrumDecay()
        stopPositionTimer()
    }

    /// Drops the loaded file. Used while a non-native track is being prepared,
    /// so the player bar shows the pending track instead of the previous one
    /// and pressing play cannot resume the old song.
    public func unload() {
        generation += 1
        playerNode.stop()
        engine?.stop()
        stopPositionTimer()
        file = nil
        segmentScheduled = false
        duration = 0
        position = 0
        pausedPosition = 0
        isPlaying = false
        updateTapInstallation()
        stopSpectrumDecay()
        spectrum = Array(repeating: 0, count: Self.bandCount)
    }

    public func seek(to time: TimeInterval) {
        guard let file else { return }
        lastError = nil
        let engine = ensureEngine()
        let wasPlaying = isPlaying
        let clamped = min(max(time, 0), duration)
        let frame = min(AVAudioFramePosition(clamped * file.processingFormat.sampleRate), file.length)

        scheduleSegment(fromFrame: frame)
        pausedPosition = clamped
        position = clamped

        if wasPlaying, segmentScheduled {
            if !engine.isRunning {
                engine.prepare()
                do {
                    try engine.start()
                } catch {
                    lastError = Lf("音频引擎启动失败（%@）", error.localizedDescription)
                    isPlaying = false
                    updateTapInstallation()
                    stopPositionTimer()
                    return
                }
            }
            playerNode.play()
            isPlaying = true
            stopSpectrumDecay()
            updateTapInstallation()
            startPositionTimer()
        } else {
            isPlaying = false
            updateTapInstallation()
            startSpectrumDecay()
            stopPositionTimer()
        }
    }

    public func setVolume(_ volume: Float) {
        playerNode.volume = min(max(volume, 0), 1)
    }

    // MARK: - Scheduling

    private func scheduleSegment(fromFrame frame: AVAudioFramePosition) {
        guard let file else { return }

        generation += 1
        let generationAtSchedule = generation
        playerNode.stop()
        stopPositionTimer()

        segmentStartFrame = frame
        let remaining = file.length - frame
        guard remaining > 0 else {
            segmentScheduled = false
            return
        }

        file.framePosition = frame
        playerNode.scheduleSegment(
            file,
            startingFrame: frame,
            frameCount: AVAudioFrameCount(remaining),
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == generationAtSchedule else { return }
                self.finishPlayback()
            }
        }
        segmentScheduled = true
    }

    private func finishPlayback() {
        generation += 1
        playerNode.stop()
        segmentScheduled = false
        stopPositionTimer()
        isPlaying = false
        updateTapInstallation()
        startSpectrumDecay()
        pausedPosition = duration
        position = duration
        onFinish?()
    }

    // MARK: - Position

    private var currentPlaybackPosition: TimeInterval {
        guard let file,
              let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return pausedPosition
        }
        let playedFrames = max(0, Double(playerTime.sampleTime))
        let seconds = (Double(segmentStartFrame) + playedFrames) / file.processingFormat.sampleRate
        return min(max(seconds, 0), duration)
    }

    private func startPositionTimer() {
        stopPositionTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.isPlaying else { return }
            self.position = self.currentPlaybackPosition
            self.pausedPosition = self.position
        }
        RunLoop.main.add(timer, forMode: .common)
        positionTimer = timer
    }

    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    // MARK: - Spectrum

    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        // Runs on CoreAudio's render thread. The two published flags are read
        // as a best-effort gate and the scratch buffers are audio-thread-only;
        // they are not touched from the main thread, so the only race is the
        // benign one on `isSpectrumEnabled`/`isPlaying` (a stale read just
        // drops or emits one extra frame). TSan will flag the flag reads.
        guard isSpectrumEnabled, isPlaying, let channels = buffer.floatChannelData else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastSpectrumPublish >= Self.spectrumInterval else { return }
        lastSpectrumPublish = now

        let frameCount = min(Int(buffer.frameLength), monoBuffer.count)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }

        // Downmix into the reusable mono buffer on the audio thread.
        for frame in 0..<frameCount {
            monoBuffer[frame] = 0
        }
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for frame in 0..<frameCount {
                monoBuffer[frame] += samples[frame]
            }
        }
        if channelCount > 1 {
            let scale = 1 / Float(channelCount)
            for frame in 0..<frameCount {
                monoBuffer[frame] *= scale
            }
        }

        monoBuffer.withUnsafeBufferPointer { samples in
            analyzer.process(
                UnsafeBufferPointer(start: samples.baseAddress, count: frameCount),
                sampleRate: buffer.format.sampleRate,
                into: &bandScratch
            )
        }
        // One small copy per published frame; the large FFT buffers are reused.
        let bands = bandScratch
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isSpectrumEnabled, self.isPlaying else { return }
            self.stopSpectrumDecay()
            // Decay smoothing: rise instantly, fall gradually.
            self.spectrum = zip(bands, self.spectrum).map { max($0, $1 * 0.72) }
        }
    }

    /// Fades the last frame to rest after pausing; the tap is already gone, so
    /// this runs at the same ~20 fps for well under a second.
    private func startSpectrumDecay() {
        stopSpectrumDecay()
        guard spectrum.contains(where: { $0 > 0 }) else { return }
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let next = self.spectrum.map { $0 * 0.68 }
            if next.allSatisfy({ $0 < 0.01 }) {
                self.spectrum = Array(repeating: 0, count: Self.bandCount)
                self.stopSpectrumDecay()
            } else {
                self.spectrum = next
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        spectrumDecayTimer = timer
    }

    private func stopSpectrumDecay() {
        spectrumDecayTimer?.invalidate()
        spectrumDecayTimer = nil
    }
}
