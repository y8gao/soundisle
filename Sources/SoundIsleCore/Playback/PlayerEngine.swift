import Accelerate
import AVFoundation
import Combine
import Foundation

/// Plays one file at a time on an `AVAudioEngine`, publishing position,
/// duration and (when enabled) a 24-band spectrum.
///
/// All published state is updated on the main queue. Spectrum analysis is
/// opt-in so normal playback pays for neither the tap nor the FFT.
public final class PlayerEngine: ObservableObject {
    public static let bandCount = 24

    @Published public private(set) var isPlaying = false
    @Published public private(set) var position: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var spectrum: [Float] = Array(repeating: 0, count: PlayerEngine.bandCount)
    /// Reason for the most recent load/start/seek failure, for the UI.
    @Published public private(set) var lastError: String?

    /// Called on the main queue after the scheduled segment finishes naturally.
    public var onFinish: (() -> Void)?

    /// The main window does not draw a spectrum yet, so the tap is not
    /// installed by default. Task 14 turns this on when a spectrum view exists.
    public var isSpectrumEnabled = false {
        didSet {
            guard isSpectrumEnabled != oldValue else { return }
            if isSpectrumEnabled {
                if let engine { installTap(on: engine) }
            } else if tapInstalled, let engine {
                engine.mainMixerNode.removeTap(onBus: 0)
                tapInstalled = false
            }
        }
    }

    private static let fftSize = 1024
    private static let spectrumInterval: TimeInterval = 1.0 / 20.0

    /// Created on first use. Building an `AVAudioEngine` talks to CoreAudio's
    /// HAL, which can block for seconds during app launch; deferring it keeps
    /// the first window frame instant and playback startup predictable.
    private var engine: AVAudioEngine?
    private let playerNode = AVAudioPlayerNode()
    private let fft = vDSP.FFT(log2n: vDSP_Length(10), radix: .radix2, ofType: DSPSplitComplex.self)
    private let window: [Float]

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

    public init() {
        var window = [Float](repeating: 0, count: Self.fftSize)
        vDSP_hann_window(&window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
        self.window = window
    }

    deinit {
        positionTimer?.invalidate()
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
        if isSpectrumEnabled {
            installTap(on: engine)
        }
        self.engine = engine
        return engine
    }

    private func installTap(on engine: AVAudioEngine) {
        guard !tapInstalled else { return }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(Self.fftSize), format: nil) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }
        tapInstalled = true
    }

    // MARK: - Controls

    public func load(url: URL) throws {
        lastError = nil
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            lastError = "无法读取音频文件（\(error.localizedDescription)）"
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
        spectrum = Array(repeating: 0, count: Self.bandCount)

        let engine = ensureEngine()
        engine.connect(playerNode, to: engine.mainMixerNode, format: file.processingFormat)
        scheduleSegment(fromFrame: 0)
    }

    public func play() {
        lastError = nil
        guard file != nil else {
            lastError = "没有加载音频文件"
            return
        }
        let engine = ensureEngine()
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                lastError = "音频引擎启动失败（\(error.localizedDescription)）"
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
        startPositionTimer()
    }

    public func pause() {
        guard isPlaying else { return }
        let current = currentPlaybackPosition
        playerNode.pause()
        pausedPosition = current
        position = current
        isPlaying = false
        stopPositionTimer()
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
                    lastError = "音频引擎启动失败（\(error.localizedDescription)）"
                    isPlaying = false
                    stopPositionTimer()
                    return
                }
            }
            playerNode.play()
            isPlaying = true
            startPositionTimer()
        } else {
            isPlaying = false
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
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
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
        guard isSpectrumEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastSpectrumPublish >= Self.spectrumInterval else { return }
        lastSpectrumPublish = now

        guard let channels = buffer.floatChannelData, fft != nil else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }

        var mono = [Float](repeating: 0, count: frameCount)
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for frame in 0..<frameCount {
                mono[frame] += samples[frame]
            }
        }
        if channelCount > 1 {
            var scale = 1 / Float(channelCount)
            vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(frameCount))
        }

        var windowed = [Float](repeating: 0, count: Self.fftSize)
        let copied = min(frameCount, Self.fftSize)
        windowed.replaceSubrange(0..<copied, with: mono[0..<copied])
        vDSP.multiply(windowed, window, result: &windowed)

        var real = [Float](repeating: 0, count: Self.fftSize / 2)
        var imaginary = [Float](repeating: 0, count: Self.fftSize / 2)
        var magnitudes = [Float](repeating: 0, count: Self.fftSize / 2)

        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var input = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { samples in
                    samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.fftSize / 2) { complex in
                        vDSP_ctoz(complex, 2, &input, 1, vDSP_Length(Self.fftSize / 2))
                    }
                }
                var outputReal = [Float](repeating: 0, count: Self.fftSize / 2)
                var outputImaginary = [Float](repeating: 0, count: Self.fftSize / 2)
                outputReal.withUnsafeMutableBufferPointer { outputRealPointer in
                    outputImaginary.withUnsafeMutableBufferPointer { outputImaginaryPointer in
                        var output = DSPSplitComplex(realp: outputRealPointer.baseAddress!, imagp: outputImaginaryPointer.baseAddress!)
                        fft?.forward(input: input, output: &output)
                        vDSP_zvabs(&output, 1, &magnitudes, 1, vDSP_Length(Self.fftSize / 2))
                    }
                }
            }
        }

        let bands = Self.computeBands(magnitudes: magnitudes, sampleRate: buffer.format.sampleRate)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Decay smoothing: rise instantly, fall gradually.
            self.spectrum = zip(bands, self.spectrum).map { max($0, $1 * 0.72) }
        }
    }

    private static func computeBands(magnitudes: [Float], sampleRate: Double) -> [Float] {
        let binCount = magnitudes.count
        let minimumFrequency = 40.0
        let maximumFrequency = min(16000.0, sampleRate / 2)
        guard binCount > 0, maximumFrequency > minimumFrequency else {
            return Array(repeating: 0, count: bandCount)
        }

        let frequencyRatio = maximumFrequency / minimumFrequency
        let hertzPerBin = sampleRate / 2 / Double(binCount)
        var bands = [Float](repeating: 0, count: bandCount)

        for band in 0..<bandCount {
            let low = minimumFrequency * pow(frequencyRatio, Double(band) / Double(bandCount))
            let high = minimumFrequency * pow(frequencyRatio, Double(band + 1) / Double(bandCount))
            let lowBin = min(max(Int(low / hertzPerBin), 0), binCount - 1)
            let highBin = min(max(Int(high / hertzPerBin), lowBin), binCount - 1)

            var peak: Float = 0
            for bin in lowBin...highBin {
                peak = max(peak, magnitudes[bin])
            }
            // vDSP's real FFT is unnormalized; a full-scale sine peaks near
            // fftSize / 2 after the Hann window.
            let normalized = peak * 2 / Float(fftSize)
            bands[band] = min(1, sqrt(normalized))
        }
        return bands
    }
}
