import AppKit
import Combine
import Foundation
import SoundIsleCore
import UniformTypeIdentifiers

/// What the sidebar has selected. One value instead of a pile of booleans so
/// the list, the title and playback all agree on the current source.
enum LibrarySelection: Hashable {
    case allMusic
    case recentlyAdded
    case folder(URL)
    case playlist(UUID)
}

/// App-wide state: the library on disk, the audio engine, the playback queue
/// and the UI selections that tie them together.
///
/// Everything runs on the main actor. Scanning and metadata reads suspend off
/// the main actor inside `LibraryStore`, so the window stays responsive.
@MainActor
final class AppModel: ObservableObject {
    let library: LibraryStore
    let engine: PlayerEngine
    /// In-memory playlist operations; every change is persisted through
    /// `library.savePlaylists()`, the only writer of `playlists.json`.
    let playlists: PlaylistStore

    @Published private(set) var queue = PlaybackQueue(trackIDs: [])
    @Published private(set) var currentTrack: Track?
    /// Position remembered from the last session until the engine loads the
    /// track on first play.
    @Published private(set) var restoredPosition: TimeInterval = 0
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var isScanning = false
    @Published var selection: LibrarySelection = .allMusic
    @Published var searchText = ""
    @Published private(set) var sort: TrackSort = .title
    @Published private(set) var sortAscending = true
    /// Playlists keep their manual order until the user clicks a column header.
    @Published private(set) var playlistSorting = false
    @Published var statusMessage: String?
    @Published var isSettingsPresented = false
    /// Lyrics overlay state. Task 8 renders the overlay; the menu bar already
    /// drives these through the hooks below.
    @Published private(set) var isLyricsVisible = false
    @Published private(set) var isLyricsLocked = false
    /// Parsed lyrics for the current track; nil means "暂无歌词".
    @Published private(set) var lyrics: Lyrics?
    /// Where `lyrics` came from, so the UI can offer the right actions.
    @Published private(set) var lyricsOrigin: LyricsOrigin = .none
    @Published private(set) var isResolvingLyrics = false
    @Published private(set) var currentLyricLineIndex: Int?
    /// The overlay controller is created by `AppDelegate`; the menu bar and
    /// main window both go through the hooks below.
    weak var lyricsOverlay: LyricsOverlayWindowController?
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
    /// Lyrics resolution is fully async; switching tracks cancels the previous
    /// lookup and ignores its late result.
    private let lyricsCache: LyricsCache
    private let lyricsService: LyricsService
    private var lyricsTask: Task<Void, Never>?

    // MARK: - Lifecycle

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let library = LibraryStore(directory: directory)
        library.load()

        self.library = library
        self.engine = PlayerEngine()
        self.playlists = PlaylistStore(playlists: library.playlists) { [weak library] playlists in
            guard let library else { return }
            library.playlists = playlists
            library.savePlaylists()
        }
        let lyricsCache = LyricsCache(
            directory: directory.appendingPathComponent("lyrics", isDirectory: true)
        )
        self.lyricsCache = lyricsCache
        self.lyricsService = LyricsService(cache: lyricsCache, client: LRCLIBClient())

        restorePlaybackState()
        isLyricsLocked = library.settings.lyricsLocked
        engine.setVolume(Float(volume))
        observeEngine()
        loadLyrics(for: currentTrack)
        installKeyMonitor()
    }

    deinit {
        lyricsTask?.cancel()
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

    var isPlaylistSelection: Bool {
        if case .playlist = selection { return true }
        return false
    }

    /// Column sorting has no visible effect on a manually ordered playlist.
    var sortsColumns: Bool {
        !isPlaylistSelection || playlistSorting
    }

    /// Reordering is only meaningful against the playlist's own order.
    var canReorderPlaylist: Bool {
        guard isPlaylistSelection, !playlistSorting else { return false }
        return searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var visibleTracks: [Track] {
        let source: [Track]
        switch selection {
        case .allMusic, .recentlyAdded:
            source = tracks
        case .folder(let folder):
            let prefix = folder.standardizedFileURL.path + "/"
            source = tracks.filter { $0.url.standardizedFileURL.path.hasPrefix(prefix) }
        case .playlist(let id):
            guard let playlist = playlists.playlists.first(where: { $0.id == id }) else { return [] }
            var byID: [UUID: Track] = [:]
            for track in tracks { byID[track.id] = track }
            source = playlist.trackIDs.compactMap { byID[$0] }
            if !playlistSorting {
                return TrackQuery.filter(source, query: searchText)
            }
        }
        return TrackQuery.apply(source, query: searchText, sort: sort, ascending: sortAscending)
    }

    func select(_ newSelection: LibrarySelection) {
        selection = newSelection
        switch newSelection {
        case .recentlyAdded:
            sort = .dateAdded
            sortAscending = false
        case .playlist:
            playlistSorting = false
        case .allMusic, .folder:
            break
        }
    }

    func toggleSort(_ newSort: TrackSort) {
        if sort == newSort {
            sortAscending.toggle()
        } else {
            sort = newSort
            sortAscending = newSort != .dateAdded
        }
        if isPlaylistSelection {
            playlistSorting = true
        }
    }

    // MARK: - Playlists

    @discardableResult
    func createPlaylist(named name: String) -> Playlist {
        let playlist = playlists.create(name: name)
        objectWillChange.send()
        return playlist
    }

    func renamePlaylist(id: UUID, to name: String) {
        playlists.rename(id: id, to: name)
        objectWillChange.send()
    }

    func deletePlaylist(id: UUID) {
        playlists.delete(id: id)
        if selection == .playlist(id) {
            select(.allMusic)
        }
        objectWillChange.send()
    }

    func addToPlaylist(_ playlistID: UUID, trackIDs: [UUID]) {
        guard !trackIDs.isEmpty else { return }
        playlists.add(trackIDs: trackIDs, to: playlistID)
        objectWillChange.send()
        if let playlist = playlists.playlists.first(where: { $0.id == playlistID }) {
            statusMessage = "已添加到「\(playlist.name)」"
        }
    }

    func removeFromPlaylist(_ playlistID: UUID, trackID: UUID) {
        playlists.remove(trackID: trackID, from: playlistID)
        objectWillChange.send()
    }

    /// Drag-to-reorder inside a playlist: the dragged track takes the target's
    /// slot in the playlist's own order.
    func moveTrack(_ draggedID: UUID, onto targetID: UUID) {
        guard case .playlist(let playlistID) = selection,
              let playlist = playlists.playlists.first(where: { $0.id == playlistID }),
              draggedID != targetID,
              let from = playlist.trackIDs.firstIndex(of: draggedID),
              let to = playlist.trackIDs.firstIndex(of: targetID) else { return }
        playlists.move(from: from, to: to, in: playlistID)
        objectWillChange.send()
    }

    /// AppKit saves us from macOS 13-only SwiftUI alert text fields.
    func promptCreatePlaylist() {
        guard let name = promptForPlaylistName(
            title: "新建播放列表",
            message: "输入播放列表名称。",
            value: ""
        ) else { return }
        let playlist = createPlaylist(named: name)
        select(.playlist(playlist.id))
    }

    func promptRenamePlaylist(id: UUID) {
        guard let existing = playlists.playlists.first(where: { $0.id == id }),
              let name = promptForPlaylistName(
                  title: "重命名播放列表",
                  message: "输入新的名称。",
                  value: existing.name
              ) else { return }
        renamePlaylist(id: id, to: name)
    }

    func confirmDeletePlaylist(id: UUID) {
        guard let existing = playlists.playlists.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "删除播放列表「\(existing.name)」？"
        alert.informativeText = "只会删除播放列表，歌曲文件不受影响。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard response == .alertFirstButtonReturn else { return }
        deletePlaylist(id: id)
    }

    private func promptForPlaylistName(title: String, message: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 230, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue
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
        // Folder removal prunes playlist entries inside `LibraryStore`; mirror
        // that so the in-memory store never resurrects deleted track IDs.
        playlists.reload(library.playlists)
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
        if engine.isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Explicit play, for the media-key "play" command (as opposed to the
    /// toggle command that F8 sends).
    func play() {
        if let current = currentTrack {
            if engine.duration > 0 {
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

    func pause() {
        engine.pause()
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

    // MARK: - Playback modes

    func setPlaybackMode(_ mode: PlaybackMode) {
        guard queue.mode != mode else { return }
        var updated = queue
        updated.setMode(mode)
        queue = updated
        savePlaybackState()
    }

    // MARK: - Lyrics

    func toggleLyricsVisibility() {
        setLyricsVisible(!isLyricsVisible)
    }

    func setLyricsVisible(_ visible: Bool) {
        guard isLyricsVisible != visible else { return }
        isLyricsVisible = visible
        lyricsOverlay?.setVisible(visible)
    }

    func toggleLyricsLock() {
        setLyricsLocked(!isLyricsLocked)
    }

    func setLyricsLocked(_ locked: Bool) {
        guard isLyricsLocked != locked else { return }
        isLyricsLocked = locked
        library.settings.lyricsLocked = locked
        library.saveSettings()
        lyricsOverlay?.setLocked(locked)
    }

    func setLyricsOpacity(_ opacity: Double) {
        let clamped = min(max(opacity, 0.05), 0.9)
        guard library.settings.lyricsOpacity != clamped else { return }
        library.settings.lyricsOpacity = clamped
        library.saveSettings()
        objectWillChange.send()
    }

    func setLyricsOutline(_ outline: Bool) {
        guard library.settings.lyricsOutline != outline else { return }
        library.settings.lyricsOutline = outline
        library.saveSettings()
        objectWillChange.send()
    }

    func setLyricsLineMode(_ mode: String) {
        guard mode == "one" || mode == "two", library.settings.lyricsLineMode != mode else { return }
        library.settings.lyricsLineMode = mode
        library.saveSettings()
        objectWillChange.send()
    }

    /// Current synced line, or the first line before playback reaches it.
    var currentLyricText: String? {
        guard let lyrics, !lyrics.lines.isEmpty else { return nil }
        guard lyrics.isSynced else { return lyrics.lines.first?.text }
        let index = currentLyricLineIndex ?? 0
        guard lyrics.lines.indices.contains(index) else { return nil }
        return lyrics.lines[index].text
    }

    var nextLyricText: String? {
        guard let lyrics, lyrics.isSynced, !lyrics.lines.isEmpty else { return nil }
        let index = (currentLyricLineIndex ?? 0) + 1
        guard lyrics.lines.indices.contains(index) else { return nil }
        return lyrics.lines[index].text
    }

    var hasLyricsOverride: Bool {
        lyricsOrigin == .override
    }

    /// A silent online miss leaves `lyrics == nil`; the overlay and menus then
    /// offer this retry entry.
    var canRetryLyrics: Bool {
        currentTrack != nil && lyrics == nil && !isResolvingLyrics
    }

    /// 「更换歌词…」: import `.lrc` or plain `.txt`, store it as the track's
    /// manual override and show it immediately.
    func promptImportLyrics() {
        guard let track = currentTrack else {
            statusMessage = "先播放一首歌曲，再导入歌词。"
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "导入"
        panel.message = "选择 .lrc 或 .txt 歌词文件"
        var types: [UTType] = [.plainText]
        if let lrc = UTType(filenameExtension: "lrc") {
            types.insert(lrc, at: 0)
        }
        panel.allowedContentTypes = types
        let response = panel.runModal()
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard response == .OK, let url = panel.url else { return }
        guard let text = LyricsService.readText(at: url) else {
            statusMessage = "无法读取歌词文件。"
            return
        }

        let parsed = Self.parseImportedLyrics(
            text,
            forcePlain: url.pathExtension.lowercased() != "lrc"
        )
        guard !parsed.lines.isEmpty else {
            statusMessage = "歌词文件没有可用内容。"
            return
        }

        do {
            try lyricsCache.saveOverride(parsed, for: track.id)
        } catch {
            statusMessage = "无法保存歌词：\(error.localizedDescription)"
            return
        }
        // The open panel is modal, but a media key can still change tracks.
        guard currentTrack?.id == track.id else {
            loadLyrics(for: currentTrack)
            return
        }
        lyricsTask?.cancel()
        isResolvingLyrics = false
        apply(ResolvedLyrics(lyrics: parsed, origin: .override, sourceURL: url))
        statusMessage = "已导入歌词"
    }

    /// 「恢复自动匹配」: drop the override and resolve the normal priority
    /// chain again (sidecar, cache, then online).
    func restoreAutomaticLyrics() {
        guard let track = currentTrack else { return }
        try? lyricsCache.removeOverride(for: track.id)
        loadLyrics(for: track)
        statusMessage = "已恢复自动匹配"
    }

    /// User-initiated retry after a silent online miss.
    func retryLyrics() {
        guard let track = currentTrack else { return }
        loadLyrics(for: track)
    }

    /// Loads lyrics off the main actor. A previous track's lookup is cancelled
    /// so a slow network response can never overwrite the current track's
    /// lyrics.
    private func loadLyrics(for track: Track?) {
        lyricsTask?.cancel()
        lyricsTask = nil
        guard let track, !track.isMissing else {
            isResolvingLyrics = false
            apply(nil)
            return
        }

        lyricsService.isOnlineEnabled = library.settings.onlineLyricsEnabled
        isResolvingLyrics = true
        lyricsTask = Task { [weak self] in
            guard let self else { return }
            let resolved = await self.lyricsService.resolve(for: track)
            guard !Task.isCancelled else { return }
            self.isResolvingLyrics = false
            guard self.currentTrack?.id == track.id else { return }
            self.apply(resolved)
        }
    }

    private func apply(_ resolved: ResolvedLyrics?) {
        lyrics = resolved?.lyrics
        lyricsOrigin = resolved?.origin ?? .none
        currentLyricLineIndex = nil
        updateCurrentLyricLine(at: engine.position)
    }

    /// `.lrc` keeps its timestamps; plain text is shown line-by-line even if
    /// the file happens to contain bracket-looking text.
    private static func parseImportedLyrics(_ text: String, forcePlain: Bool) -> Lyrics {
        let parsed = LRCParser.parse(text)
        guard forcePlain else { return parsed }
        return Lyrics(
            lines: parsed.lines.map { LyricLine(time: 0, text: $0.text) },
            isSynced: false
        )
    }

    private func updateCurrentLyricLine(at time: TimeInterval) {
        let index = lyrics?.index(at: time)
        guard currentLyricLineIndex != index else { return }
        currentLyricLineIndex = index
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

        $currentTrack
            .sink { [weak self] track in
                Task { @MainActor [weak self] in
                    self?.loadLyrics(for: track)
                }
            }
            .store(in: &cancellables)

        // The engine publishes at ~2 Hz, which is ample for per-line changes.
        engine.$position
            .sink { [weak self] position in
                Task { @MainActor [weak self] in
                    self?.updateCurrentLyricLine(at: position)
                }
            }
            .store(in: &cancellables)
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
