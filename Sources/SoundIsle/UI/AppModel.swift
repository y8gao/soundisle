import AppKit
import Combine
import Foundation
import SoundIsleCore

/// App-wide state: the library on disk, the audio engine, the playback queue
/// and the UI selections that tie them together.
///
/// Everything runs on the main actor. Scanning and metadata reads suspend off
/// the main actor inside `LibraryStore`, so the window stays responsive.
@MainActor
final class AppModel: ObservableObject {
    let library: LibraryStore
    let engine: PlayerEngine

    @Published private(set) var queue = PlaybackQueue(trackIDs: [])
    @Published private(set) var currentTrack: Track?
    /// Position remembered from the last session until the engine loads the
    /// track on first play.
    @Published private(set) var restoredPosition: TimeInterval = 0
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var isScanning = false
    @Published var selectedFolder: URL?
    @Published var statusMessage: String?
    @Published var isSettingsPresented = false
    @Published var searchFocusRequest = UUID()
    @Published var endSearchFocusRequest = UUID()
    /// Mirrors the SwiftUI focus state of the search field so the local key
    /// monitor knows when space belongs to text entry instead of playback.
    @Published var isSearchFocused = false
    @Published var volume: Double = 0.8 {
        didSet { engine.setVolume(Float(volume)) }
    }

    private var cancellables = Set<AnyCancellable>()
    private var saveTimer: Timer?
    private var keyMonitor: Any?
    private var didStart = false

    // MARK: - Lifecycle

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let library = LibraryStore(directory: directory)
        library.load()

        self.library = library
        self.engine = PlayerEngine()

        restorePlaybackState()
        engine.setVolume(Float(volume))
        observeEngine()
        installKeyMonitor()
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        saveTimer?.invalidate()
    }

    /// Production wiring: `~/Library/Application Support/SoundIsle/`.
    static func production() -> AppModel {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = base.appendingPathComponent("SoundIsle", isDirectory: true)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        return AppModel(directory: directory)
    }

    /// Called once the window appears: loads were read in `init`, then the
    /// library refreshes incrementally without blocking the first frame.
    func start() {
        guard !didStart else { return }
        didStart = true
        guard !library.index.folders.isEmpty else { return }
        Task { await rescan() }
    }

    // MARK: - Derived library state

    var folders: [URL] { library.index.folders }

    /// What the player bar should show: live engine state once a track is
    /// loaded, otherwise the position remembered from the last session.
    var displayPosition: TimeInterval {
        engine.duration > 0 ? engine.position : restoredPosition
    }

    var displayDuration: TimeInterval {
        engine.duration > 0 ? engine.duration : (currentTrack?.duration ?? 0)
    }

    var visibleTracks: [Track] {
        guard let folder = selectedFolder else { return tracks }
        let prefix = folder.standardizedFileURL.path + "/"
        return tracks.filter { $0.url.standardizedFileURL.path.hasPrefix(prefix) }
    }

    func trackCount(in folder: URL) -> Int {
        let prefix = folder.standardizedFileURL.path + "/"
        return tracks.filter { $0.url.standardizedFileURL.path.hasPrefix(prefix) }.count
    }

    // MARK: - Import

    /// Opens the system folder picker. The caller hands the URLs back to
    /// `importFolders(_:)`.
    func openFolders() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "导入"
        panel.message = "选择包含音乐的文件夹"
        let response = panel.runModal()
        // The search field is the only text field in the window and AppKit may
        // hand it focus when the panel closes, which would swallow space/arrow
        // playback shortcuts. Leave focus on the window itself.
        NSApp.keyWindow?.makeFirstResponder(nil)
        return response == .OK ? panel.urls : []
    }

    /// Accepts folders, or files dropped from Finder (whose containing folder
    /// is imported because the library is folder-based).
    func importFolders(_ urls: [URL]) {
        let manager = FileManager.default
        let folders = urls.map { url -> URL in
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return url
            }
            return url.deletingLastPathComponent()
        }
        let unique = Array(Set(folders.map(\.standardizedFileURL)))
        guard !unique.isEmpty else { return }
        guard !isScanning else {
            statusMessage = "正在扫描音乐库，请稍后再导入。"
            return
        }
        Task { await importFoldersAndScan(unique) }
    }

    private func importFoldersAndScan(_ urls: [URL]) async {
        isScanning = true
        for url in urls {
            await library.addFolder(url)
        }
        isScanning = false
        refreshFromLibrary()
    }

    func rescan() async {
        guard !isScanning else { return }
        isScanning = true
        await library.rescan()
        isScanning = false
        refreshFromLibrary()
    }

    private func refreshFromLibrary() {
        tracks = library.index.tracks
        guard let id = currentTrack?.id else { return }
        if let updated = tracks.first(where: { $0.id == id }) {
            currentTrack = updated
            if updated.isMissing {
                engine.pause()
                restoredPosition = 0
                statusMessage = "《\(updated.title)》文件缺失，仍保留在列表中。"
            }
        } else {
            currentTrack = nil
            restoredPosition = 0
            engine.pause()
        }
    }

    // MARK: - Playback

    func play(trackID: UUID) {
        guard let index = visibleTracks.firstIndex(where: { $0.id == trackID }) else { return }
        let track = visibleTracks[index]

        if currentTrack?.id == track.id {
            togglePlayPause()
            return
        }
        if track.isMissing {
            statusMessage = "《\(track.title)》文件缺失，无法播放。"
            return
        }

        var updated = queue
        updated.replace(with: visibleTracks.map(\.id), startAt: index)
        queue = updated
        _ = playFromQueue(track.id)
        savePlaybackState()
    }

    func togglePlayPause() {
        if let current = currentTrack {
            if engine.isPlaying {
                engine.pause()
            } else if engine.duration > 0 {
                engine.play()
                if engine.isPlaying {
                    statusMessage = nil
                } else {
                    statusMessage = startFailureStatus
                }
            } else {
                resumeCurrent(current)
            }
            return
        }

        if let first = visibleTracks.first {
            play(trackID: first.id)
        } else {
            statusMessage = "音乐库是空的，先导入一个文件夹。"
        }
    }

    private var startFailureStatus: String {
        "无法开始播放：\(engine.lastError ?? "未知错误")"
    }

    /// First play after a restore: the engine was deliberately left unloaded
    /// at launch, so load now and jump to the remembered position.
    private func resumeCurrent(_ track: Track) {
        guard !track.isMissing else {
            statusMessage = "《\(track.title)》文件缺失，无法播放。"
            return
        }
        do {
            try engine.load(url: track.url)
        } catch {
            statusMessage = "无法播放《\(track.title)》：\(engine.lastError ?? "未知错误")"
            return
        }
        if restoredPosition > 0 {
            engine.seek(to: restoredPosition)
        }
        engine.play()
        if engine.isPlaying {
            restoredPosition = 0
            statusMessage = nil
        } else {
            statusMessage = startFailureStatus
        }
    }

    func next() {
        var updated = queue
        var attempts = 0
        while attempts < max(updated.trackIDs.count, 1) {
            guard let id = updated.next() else { break }
            attempts += 1
            if playFromQueue(id) { break }
        }
        queue = updated
        savePlaybackState()
    }

    func previous() {
        var updated = queue
        var attempts = 0
        while attempts < max(updated.trackIDs.count, 1) {
            guard let id = updated.previous() else { break }
            attempts += 1
            if playFromQueue(id) { break }
        }
        queue = updated
        savePlaybackState()
    }

    func seek(to time: TimeInterval) {
        guard let current = currentTrack else { return }
        if engine.duration > 0 {
            engine.seek(to: time)
            if let error = engine.lastError {
                statusMessage = "无法跳转播放位置：\(error)"
            }
        } else {
            let upper = current.duration > 0 ? current.duration : time
            restoredPosition = min(max(time, 0), upper)
        }
        savePlaybackState()
    }

    func seek(by delta: TimeInterval) {
        seek(to: displayPosition + delta)
    }

    private func playFromQueue(_ id: UUID) -> Bool {
        guard let track = tracks.first(where: { $0.id == id }) else {
            statusMessage = "曲目不在音乐库中。"
            return false
        }
        guard !track.isMissing else {
            statusMessage = "《\(track.title)》文件缺失，已跳过。"
            return false
        }
        do {
            try engine.load(url: track.url)
        } catch {
            statusMessage = "无法播放《\(track.title)》：\(engine.lastError ?? "未知错误")"
            return false
        }
        currentTrack = track
        restoredPosition = 0
        engine.play()
        if engine.isPlaying {
            statusMessage = nil
        } else {
            statusMessage = startFailureStatus
        }
        // The file loaded, so keep the queue on this track even if the audio
        // engine could not start; skipping ahead would hide the failure.
        return true
    }

    // MARK: - Persistence

    /// Writes queue, current track and position into `AppSettings` so the next
    /// launch restores the session without autoplaying.
    func savePlaybackState() {
        var settings = library.settings
        settings.lastQueue = queue.trackIDs
        settings.lastTrackID = currentTrack?.id
        settings.lastPosition = max(0, displayPosition)
        settings.playbackMode = queue.mode.rawValue
        library.settings = settings
        library.saveSettings()
    }

    private func restorePlaybackState() {
        tracks = library.index.tracks
        let settings = library.settings

        var ids = settings.lastQueue.filter { id in tracks.contains { $0.id == id } }
        if let id = settings.lastTrackID,
           tracks.contains(where: { $0.id == id }),
           !ids.contains(id) {
            ids.insert(id, at: 0)
        }
        let mode = PlaybackMode(rawValue: settings.playbackMode) ?? .sequential
        let currentIndex = settings.lastTrackID.flatMap { ids.firstIndex(of: $0) } ?? 0
        queue = PlaybackQueue(trackIDs: ids, currentIndex: currentIndex, mode: mode)

        guard let id = settings.lastTrackID,
              let track = tracks.first(where: { $0.id == id }) else { return }
        currentTrack = track
        guard !track.isMissing else {
            statusMessage = "《\(track.title)》文件缺失，仍保留在列表中。"
            return
        }
        // Deliberately do not load the file yet: the audio engine is created on
        // first play, so launch stays fast and never autoplays.
        restoredPosition = max(0, settings.lastPosition)
    }

    // MARK: - Engine observation

    private func observeEngine() {
        engine.$isPlaying
            .sink { [weak self] playing in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isPlaying = playing
                    if playing {
                        self.startSaveTimer()
                    } else {
                        self.stopSaveTimer()
                        self.savePlaybackState()
                    }
                }
            }
            .store(in: &cancellables)

        engine.onFinish = { [weak self] in
            Task { @MainActor [weak self] in
                self?.next()
            }
        }
    }

    private func startSaveTimer() {
        guard saveTimer == nil else { return }
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.savePlaybackState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        saveTimer = timer
    }

    private func stopSaveTimer() {
        saveTimer?.invalidate()
        saveTimer = nil
    }

    // MARK: - Keyboard shortcuts

    func requestSearchFocus() {
        searchFocusRequest = UUID()
    }

    private func endSearchFocus() {
        endSearchFocusRequest = UUID()
    }

    func dismissStatus() {
        statusMessage = nil
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyEvent(event) ? nil : event
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        if NSApp.modalWindow == nil, event.keyCode == 53, isSearchFocused {
            endSearchFocus()
            return true
        }
        guard NSApp.modalWindow == nil, !isSettingsPresented, !isSearchFocused, !isEditingText else { return false }
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }

        switch event.keyCode {
        case 49: // space
            guard !event.isARepeat else { return true }
            togglePlayPause()
            return true
        case 123: // left arrow
            seek(by: -5)
            return true
        case 124: // right arrow
            seek(by: 5)
            return true
        default:
            return false
        }
    }

    private var isEditingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }
}
