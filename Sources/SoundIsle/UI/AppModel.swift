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

/// A pending tag-editor sheet. `Identifiable` so `.sheet(item:)` recreates the
/// editor whenever the user opens it for a different selection.
struct TagEditorRequest: Identifiable {
    let id = UUID()
    let tracks: [Track]
}

/// A pending file-organizer preview. Built once per presentation so editing
/// the template re-plans against a stable selection.
struct OrganizerRequest: Identifiable {
    let id = UUID()
    let tracks: [Track]
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
    let tagService = TagService()
    let tagUndoStore: TagEditUndoStore
    let organizer: FileOrganizer
    /// Serial background transcoder for formats AVFoundation cannot read.
    let transcode: TranscodeQueue

    @Published private(set) var queue = PlaybackQueue(trackIDs: [])
    @Published private(set) var currentTrack: Track?
    /// Position remembered from the last session until the engine loads the
    /// track on first play.
    @Published private(set) var restoredPosition: TimeInterval = 0
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var isScanning = false
    @Published var selection: LibrarySelection = .allMusic
    /// Multi-selection: ⌘-click toggles, Shift-click extends from the anchor.
    /// A plain click still plays and collapses the selection to one row.
    @Published private(set) var selectedTrackIDs: Set<UUID> = []
    @Published var tagEditorRequest: TagEditorRequest?
    @Published private(set) var tagUndoCount = 0
    @Published var organizerRequest: OrganizerRequest?
    @Published private(set) var organizeUndoCount = 0
    @Published var searchText = ""
    @Published private(set) var sort: TrackSort = .title
    @Published private(set) var sortAscending = true
    /// Playlists keep their manual order until the user clicks a column header.
    @Published private(set) var playlistSorting = false
    @Published var statusMessage: String?
    /// Live progress for long file work (tag writes / organize). Non-nil also
    /// means a file operation is in flight, so sheets can disable their action.
    @Published private(set) var fileWorkProgress: String?
    /// The missing-ffmpeg banner adds install/retry/choose-path actions.
    @Published private(set) var showsFFmpegInstallPrompt = false
    @Published private(set) var transcodeCacheBytes: Int64 = 0
    @Published var isSettingsPresented = false
    /// Lyrics overlay state. Task 8 renders the overlay; the menu bar already
    /// drives these through the hooks below.
    @Published private(set) var isLyricsVisible = false
    @Published private(set) var isLyricsLocked = false
    /// Lyrics display state for the current track. Starting a lookup for a
    /// different track clears the old lyrics synchronously, so a slow network
    /// response never leaves the previous song's lines on screen.
    @Published private(set) var lyricsState = LyricsDisplayState()
    @Published private(set) var currentLyricLineIndex: Int?

    var lyrics: Lyrics? { lyricsState.lyrics }
    var lyricsOrigin: LyricsOrigin { lyricsState.origin }
    var isResolvingLyrics: Bool { lyricsState.isResolving }
    /// The overlay controller is created by `AppDelegate`; the menu bar and
    /// main window both go through the hooks below.
    weak var lyricsOverlay: LyricsOverlayWindowController?
    /// Set by `AppDelegate` so preference changes reach the mini panel.
    weak var miniPlayer: MiniPlayerWindowController?
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
    private var customAccentSaveTask: Task<Void, Never>?
    private var lyricsOpacitySaveTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var didStart = false
    /// Anchor row for Shift-click range selection.
    private var selectionAnchorID: UUID?
    /// Lyrics resolution is fully async; switching tracks cancels the previous
    /// lookup and ignores its late result.
    private let lyricsCache: LyricsCache
    private let lyricsService: LyricsService
    private var lyricsTask: Task<Void, Never>?
    /// Set after a successful override removal so the resolve outcome can
    /// replace the status message.
    private var pendingRestoreTrackID: UUID?
    private let transcodeRoot: URL
    /// The non-native track waiting for ffmpeg, retried once it is found.
    private var pendingTranscodeTrack: Track?
    private var preparingTrackID: UUID?

    // MARK: - Lifecycle

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let library = LibraryStore(directory: directory)
        library.load()

        self.library = library
        self.engine = PlayerEngine()
        let undoDirectory = directory.appendingPathComponent("undo", isDirectory: true)
        self.tagUndoStore = TagEditUndoStore(directory: undoDirectory)
        self.organizer = FileOrganizer(undo: OrganizeUndoStore(directory: undoDirectory))
        let transcodeRoot = directory.appendingPathComponent("transcode", isDirectory: true)
        try? FileManager.default.createDirectory(at: transcodeRoot, withIntermediateDirectories: true)
        self.transcodeRoot = transcodeRoot
        self.transcode = TranscodeQueue(
            cacheRoot: transcodeRoot,
            ffmpeg: FFmpegLocator.find(customPath: library.settings.ffmpegPath)
        )
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
        tagUndoCount = tagUndoStore.entries.count
        organizeUndoCount = organizer.undo.entries.count
        isLyricsLocked = library.settings.lyricsLocked
        engine.setVolume(Float(volume))
        observeEngine()
        loadLyrics(for: currentTrack)
        installKeyMonitor()
        refreshTranscodeCacheSize()
        applyAppearance()

        // Recovery is never silent: index/settings/playlist fallbacks and a
        // corrupt undo history all surface in the existing status banner.
        let startupNotices = [
            library.recoveryNotice,
            tagUndoStore.loadNotice,
            organizer.undo.loadNotice,
        ].compactMap { $0 }
        if !startupNotices.isEmpty {
            statusMessage = startupNotices.joined(separator: " ")
        }
    }

    deinit {
        lyricsTask?.cancel()
        customAccentSaveTask?.cancel()
        lyricsOpacitySaveTask?.cancel()
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
        selectedTrackIDs = []
        selectionAnchorID = nil
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

    // MARK: - Track selection

    /// A row click. ⌘ toggles one row, Shift extends from the last clicked
    /// row, and a plain click keeps the usual single-click playback while
    /// collapsing the selection.
    func handleTrackClick(_ trackID: UUID, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        if modifiers.contains(.command) {
            if selectedTrackIDs.contains(trackID) {
                selectedTrackIDs.remove(trackID)
            } else {
                selectedTrackIDs.insert(trackID)
            }
            selectionAnchorID = trackID
            return
        }
        if modifiers.contains(.shift), let anchor = selectionAnchorID,
           let from = visibleTracks.firstIndex(where: { $0.id == anchor }),
           let to = visibleTracks.firstIndex(where: { $0.id == trackID }) {
            let range = from <= to ? from...to : to...from
            selectedTrackIDs = Set(visibleTracks[range].map(\.id))
            return
        }
        selectedTrackIDs = [trackID]
        selectionAnchorID = trackID
        play(trackID: trackID)
    }

    /// Rows a context-menu action applies to: the whole selection when the
    /// clicked row belongs to it, otherwise only the clicked row.
    func contextTrackIDs(for trackID: UUID) -> [UUID] {
        guard selectedTrackIDs.contains(trackID) else { return [trackID] }
        let ordered = visibleTracks.map(\.id).filter { selectedTrackIDs.contains($0) }
        return ordered.isEmpty ? [trackID] : ordered
    }

    // MARK: - Tag editing

    func beginTagEdit(trackIDs: [UUID]) {
        let ids = Set(trackIDs)
        let targets = visibleTracks.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        tagEditorRequest = TagEditorRequest(tracks: targets)
    }

    var canUndoTagEdit: Bool { tagUndoCount > 0 }

    @discardableResult
    func clearTagUndoHistory() -> String {
        do {
            try tagUndoStore.clear()
            tagUndoCount = 0
            let message = "已清空编辑撤销记录。"
            statusMessage = message
            return message
        } catch {
            let message = "清空编辑撤销记录失败：\(error.localizedDescription)"
            statusMessage = message
            return message
        }
    }

    @discardableResult
    func undoLastTagEdit() -> String {
        do {
            guard let entry = try tagUndoStore.undoLast() else {
                let message = "没有可撤销的标签编辑。"
                statusMessage = message
                return message
            }
            tagUndoCount = tagUndoStore.entries.count
            updateIndex(
                for: entry.url,
                fields: entry.before,
                artworkChanged: entry.before.artworkBase64 != entry.after.artworkBase64
            )
            refreshFromLibrary()
            let message = "已撤销对《\(entry.url.lastPathComponent)》的标签编辑。"
            statusMessage = message
            return message
        } catch {
            tagUndoCount = tagUndoStore.entries.count
            let message = "撤销失败：\(error.localizedDescription)"
            statusMessage = message
            return message
        }
    }

    /// Applies `edits` to every track. Fields left nil are not modified.
    /// Returns a Chinese summary on failure, or nil when every write succeeded.
    ///
    /// TagLib reads/writes happen one file at a time in a detached task, so a
    /// large batch never freezes the window; progress and the index update run
    /// back on the main actor.
    func applyTagEdit(_ edits: TagFields, to tracks: [Track]) async -> String? {
        guard !tracks.isEmpty else { return "没有选择歌曲。" }
        guard fileWorkProgress == nil else { return "已有文件操作正在进行。" }

        let total = tracks.count
        fileWorkProgress = "正在写入 0/\(total)…"
        var changed: [(track: Track, before: TagFields, after: TagFields)] = []
        var failures: [String] = []
        var undoFailures = 0

        for (index, track) in tracks.enumerated() {
            fileWorkProgress = "正在写入 \(index + 1)/\(total)…"
            let result = await Task.detached(priority: .userInitiated) { () -> TagEditFileResult in
                let service = TagService()
                guard let before = service.read(from: track.url) else {
                    return TagEditFileResult(changed: nil, failure: "《\(track.title)》无法读取标签")
                }
                var after = before
                if let value = edits.title { after.title = Self.nonEmpty(value) }
                if let value = edits.artist { after.artist = Self.nonEmpty(value) }
                if let value = edits.album { after.album = Self.nonEmpty(value) }
                if let value = edits.albumArtist { after.albumArtist = Self.nonEmpty(value) }
                if let value = edits.genre { after.genre = Self.nonEmpty(value) }
                if let value = edits.year { after.year = value > 0 ? value : nil }
                if let value = edits.trackNumber { after.trackNumber = value > 0 ? value : nil }
                if let value = edits.artworkBase64 {
                    after.artworkBase64 = value.isEmpty ? nil : value
                }
                guard after != before else { return TagEditFileResult(changed: nil, failure: nil) }

                do {
                    // Partial write: TagService leaves omitted fields untouched,
                    // and the C bridge swaps in a temporary copy atomically.
                    try service.write(edits, to: track.url)
                } catch {
                    return TagEditFileResult(
                        changed: nil,
                        failure: "《\(track.title)》：\(error.localizedDescription)"
                    )
                }
                return TagEditFileResult(
                    changed: (track, before, after),
                    failure: nil
                )
            }.value

            if let failure = result.failure {
                failures.append(failure)
            }
            if let change = result.changed {
                changed.append(change)
                do {
                    try tagUndoStore.record(
                        TagUndoEntry(url: change.track.url, before: change.before, after: change.after)
                    )
                } catch {
                    undoFailures += 1
                }
            }
        }

        fileWorkProgress = nil
        tagUndoCount = tagUndoStore.entries.count
        for item in changed {
            updateIndex(
                for: item.track.url,
                fields: item.after,
                artworkChanged: item.before.artworkBase64 != item.after.artworkBase64
            )
        }
        if !changed.isEmpty {
            refreshFromLibrary()
        }

        var notes = failures
        if undoFailures > 0 {
            notes.append("\(undoFailures) 首的撤销记录保存失败")
        }
        guard !notes.isEmpty else {
            statusMessage = changed.isEmpty ? "没有需要修改的标签。" : "已更新 \(changed.count) 首歌曲的标签。"
            return nil
        }
        let summary = "已更新 \(changed.count) 首，\(notes.count) 项失败：\(notes.prefix(2).joined(separator: "；"))"
        statusMessage = summary
        return summary
    }

    /// One file's outcome from the background tag-write loop.
    private struct TagEditFileResult {
        var changed: (track: Track, before: TagFields, after: TagFields)?
        var failure: String?
    }

    /// A writable file whose tag fields can be repaired, plus preview text.
    private struct MojibakeRepairCandidate {
        let track: Track
        let fields: TagFields
        let changes: [String]
    }

    /// 「修复乱码标签…」: reads tags (not display strings) on writable files,
    /// previews the repaired fields, then writes each repaired snapshot through
    /// the normal tag pipeline so undo records are kept. Non-writable formats
    /// (e.g. INFO-only WAV) are skipped; the list still shows them repaired.
    func promptRepairMojibake(trackIDs: [UUID]) {
        let ids = Set(trackIDs)
        let targets = visibleTracks.filter { ids.contains($0.id) }
        guard !targets.isEmpty else {
            statusMessage = "没有选择歌曲。"
            return
        }
        Task {
            guard fileWorkProgress == nil else {
                statusMessage = "已有文件操作正在进行。"
                return
            }
            fileWorkProgress = "正在检查乱码 0/\(targets.count)…"
            let candidates = await Task.detached(priority: .userInitiated) {
                () -> [MojibakeRepairCandidate] in
                let service = TagService()
                var found: [MojibakeRepairCandidate] = []
                for (index, track) in targets.enumerated() {
                    defer {
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.fileWorkProgress != nil else { return }
                            self.fileWorkProgress = "正在检查乱码 \(index + 1)/\(targets.count)…"
                        }
                    }
                    let capabilities = TagFormatCapabilities.capabilities(for: track.url)
                    guard capabilities.canWrite,
                          let before = service.read(from: track.url) else { continue }

                    var edits = TagFields()
                    var changes: [String] = []
                    if let value = before.title,
                       let fixed = MojibakeRepair.repaired(value) {
                        edits.title = fixed
                        changes.append("标题：\(value) → \(fixed)")
                    }
                    if let value = before.artist,
                       let fixed = MojibakeRepair.repaired(value) {
                        edits.artist = fixed
                        changes.append("歌手：\(value) → \(fixed)")
                    }
                    if let value = before.album,
                       let fixed = MojibakeRepair.repaired(value) {
                        edits.album = fixed
                        changes.append("专辑：\(value) → \(fixed)")
                    }
                    if capabilities.canWriteAlbumArtist,
                       let value = before.albumArtist,
                       let fixed = MojibakeRepair.repaired(value) {
                        edits.albumArtist = fixed
                        changes.append("专辑歌手：\(value) → \(fixed)")
                    }
                    guard !changes.isEmpty else { continue }
                    found.append(
                        MojibakeRepairCandidate(track: track, fields: edits, changes: changes)
                    )
                }
                return found
            }.value
            fileWorkProgress = nil

            guard !candidates.isEmpty else {
                statusMessage = "没有检测到可修复的乱码标签。"
                return
            }

            let alert = NSAlert()
            alert.messageText = "修复 \(candidates.count) 首歌曲的乱码标签？"
            let preview = candidates.prefix(5).flatMap { candidate in
                candidate.changes.map { "《\(candidate.track.title)》\($0)" }
            }
            var detail = preview.joined(separator: "\n")
            if candidates.count > 5 {
                detail += "\n…"
            }
            alert.informativeText = detail
                + "\n\n只写入支持标签编辑的格式，音频内容不会改变；可撤销。"
            alert.addButton(withTitle: "修复")
            alert.addButton(withTitle: "取消")
            let response = alert.runModal()
            NSApp.keyWindow?.makeFirstResponder(nil)
            guard response == .alertFirstButtonReturn else { return }

            var failures: [String] = []
            for candidate in candidates {
                if let error = await applyTagEdit(candidate.fields, to: [candidate.track]) {
                    failures.append(error)
                }
            }
            statusMessage = failures.isEmpty
                ? "已修复 \(candidates.count) 首歌曲的乱码标签。"
                : "已尝试修复 \(candidates.count) 首，\(failures.count) 项失败：\(failures.prefix(2).joined(separator: "；"))"
        }
    }

    /// Keeps the library index in step with the file that was just written so
    /// the list shows new values without a full rescan.
    private func updateIndex(for url: URL, fields: TagFields, artworkChanged: Bool) {
        let standardized = url.standardizedFileURL
        guard let track = library.index.tracks.first(where: {
            $0.url.standardizedFileURL == standardized
        }) else { return }

        var updated = TrackFactory.applying(fields, to: track)
        // Filename fallbacks live in TrackFactory so an untagged
        // `Artist - Title.mp3` keeps its scanned artist after an album edit.
        if artworkChanged {
            library.setArtwork(
                fields.artworkBase64.flatMap { Data(base64Encoded: $0) },
                for: track.id
            )
            updated.artworkFileName = library.index.tracks
                .first(where: { $0.id == track.id })?.artworkFileName
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: standardized.path)
        if let size = (attributes?[.size] as? NSNumber)?.int64Value {
            updated.fileSize = size
        }
        if let date = attributes?[.modificationDate] as? Date {
            updated.modifiedAt = date
        }
        library.updateTrack(updated)
    }

    nonisolated private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - File organizing

    func beginOrganize(trackIDs: [UUID]) {
        let ids = Set(trackIDs)
        let targets = visibleTracks.filter { ids.contains($0.id) && !$0.isMissing }
        guard !targets.isEmpty else {
            statusMessage = "没有可整理的歌曲。"
            return
        }
        organizerRequest = OrganizerRequest(tracks: targets)
    }

    var canUndoOrganize: Bool { organizeUndoCount > 0 }

    /// Executes a previewed plan and points the affected tracks at their new
    /// URLs. Returns a Chinese error for the sheet, or nil on success.
    /// `destinationRoot` is added to the imported folders when it was outside
    /// them, so a later rescan does not mark the moved tracks missing.
    ///
    /// The copy/move loop runs in a detached task; cross-volume copies report
    /// progress instead of freezing the window.
    func performOrganize(
        _ items: [OrganizePlanItem],
        copy: Bool,
        destinationRoot: URL
    ) async -> String? {
        guard !items.isEmpty else { return "没有需要整理的文件。" }
        guard fileWorkProgress == nil else { return "已有文件操作正在进行。" }

        let total = items.count
        fileWorkProgress = "正在整理 0/\(total)…"
        let organizer = self.organizer
        let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            do {
                try organizer.apply(items, copy: copy) { completed, count in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.fileWorkProgress != nil else { return }
                        self.fileWorkProgress = "正在整理 \(completed)/\(count)…"
                    }
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value
        fileWorkProgress = nil

        switch result {
        case .success:
            applyTrackURLs(for: items)
            library.ensureFoldersCovering([destinationRoot])
            organizeUndoCount = organizer.undo.entries.count
            surfacePersistenceError()
            statusMessage = copy
                ? "已复制 \(items.count) 个文件。"
                : "已移动 \(items.count) 个文件，可用「撤销上次整理」恢复。"
            return nil
        case .failure(let error):
            // A mid-run failure still moved the earlier rows; keep the index
            // truthful for those before showing the error.
            if let organizeError = error as? OrganizeError,
               case let .applyFailed(applied, _) = organizeError,
               !applied.isEmpty {
                applyTrackURLs(for: applied)
                library.ensureFoldersCovering([destinationRoot])
            }
            organizeUndoCount = organizer.undo.entries.count
            surfacePersistenceError()
            let message = error.localizedDescription
            statusMessage = message
            return message
        }
    }

    @discardableResult
    func undoLastOrganize() -> String {
        guard fileWorkProgress == nil else {
            let message = "正在整理，请稍后再撤销。"
            statusMessage = message
            return message
        }
        let wasCopy = organizer.undo.entries.last?.copy ?? false
        do {
            guard let items = try organizer.undoLast() else {
                let message = "没有可撤销的整理。"
                statusMessage = message
                return message
            }
            restoreTrackURLs(for: items)
            organizeUndoCount = organizer.undo.entries.count
            let message: String
            if items.isEmpty {
                message = wasCopy ? "没有可删除的副本。" : "没有可恢复的文件。"
            } else if wasCopy {
                message = "已删除 \(items.count) 个副本，原文件保留。"
            } else {
                message = "已恢复 \(items.count) 个文件到原位置。"
            }
            statusMessage = message
            return message
        } catch {
            organizeUndoCount = organizer.undo.entries.count
            // A partially failed undo already put some files back. Point those
            // tracks at their sources now; otherwise the next rescan would
            // mark them missing and re-add them with new IDs.
            var message = error.localizedDescription
            if let organizeError = error as? OrganizeError,
               case let .undoFailed(restored, _) = organizeError,
               !restored.isEmpty {
                restoreTrackURLs(for: restored)
                message += "（已恢复 \(restored.count) 个文件，其余保留在目标位置）"
            }
            statusMessage = message
            return message
        }
    }

    private func applyTrackURLs(for items: [OrganizePlanItem]) {
        guard !items.isEmpty else { return }
        library.updateTrackURLs(OrganizeURLMapping.apply(items))
        refreshFromLibrary()
    }

    private func restoreTrackURLs(for items: [OrganizePlanItem]) {
        guard !items.isEmpty else { return }
        library.updateTrackURLs(OrganizeURLMapping.undo(items))
        // Restored files normally land back in an imported folder; cover them
        // anyway so undo never leaves a track unscanned.
        library.ensureFoldersCovering(
            items
                .map { $0.source.deletingLastPathComponent().standardizedFileURL }
                .filter { $0.path != "/" }
        )
        refreshFromLibrary()
    }

    // MARK: - Playlists

    @discardableResult
    func createPlaylist(named name: String) -> Playlist {
        let playlist = playlists.create(name: name)
        objectWillChange.send()
        surfacePersistenceError()
        return playlist
    }

    func renamePlaylist(id: UUID, to name: String) {
        playlists.rename(id: id, to: name)
        objectWillChange.send()
        surfacePersistenceError()
    }

    func deletePlaylist(id: UUID) {
        playlists.delete(id: id)
        surfacePersistenceError()
        if selection == .playlist(id) {
            select(.allMusic)
        }
        objectWillChange.send()
    }

    func addToPlaylist(_ playlistID: UUID, trackIDs: [UUID]) {
        guard !trackIDs.isEmpty else { return }
        playlists.add(trackIDs: trackIDs, to: playlistID)
        objectWillChange.send()
        surfacePersistenceError()
        if let playlist = playlists.playlists.first(where: { $0.id == playlistID }) {
            statusMessage = "已添加到「\(playlist.name)」"
        }
    }

    func removeFromPlaylist(_ playlistID: UUID, trackID: UUID) {
        playlists.remove(trackID: trackID, from: playlistID)
        objectWillChange.send()
        surfacePersistenceError()
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
        surfacePersistenceError()
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

    /// Playlist rows can keep IDs for tracks that were later removed; the
    /// sidebar count should match what the playlist can actually show.
    func resolvableTrackCount(in playlist: Playlist) -> Int {
        let ids = Set(tracks.map(\.id))
        return playlist.trackIDs.filter { ids.contains($0) }.count
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
        prepareLibraryFormats()
    }

    func rescan() async {
        guard !isScanning else { return }
        isScanning = true
        await library.rescan()
        isScanning = false
        refreshFromLibrary()
        prepareLibraryFormats()
    }

    /// Sidebar refresh on a single folder row. Uses the folder-scoped core
    /// rescan so other imported folders are never touched.
    func rescanFolder(_ folder: URL) async {
        guard !isScanning else { return }
        isScanning = true
        await library.rescan(folder: folder)
        isScanning = false
        refreshFromLibrary()
        prepareLibraryFormats()
    }

    private func refreshFromLibrary() {
        tracks = library.index.tracks
        // Folder removal prunes playlist entries inside `LibraryStore`; mirror
        // that so the in-memory store never resurrects deleted track IDs.
        playlists.reload(library.playlists)
        let validIDs = Set(tracks.map(\.id))
        let pruned = selectedTrackIDs.intersection(validIDs)
        if pruned != selectedTrackIDs {
            selectedTrackIDs = pruned
        }
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
    /// at launch, so load now and jump to the remembered position. Non-native
    /// tracks that are already cached take the same path; uncached ones are
    /// prepared first.
    private func resumeCurrent(_ track: Track) {
        guard !track.isMissing else {
            statusMessage = "《\(track.title)》文件缺失，无法播放。"
            return
        }
        let position = restoredPosition
        let url: URL?
        if AudioFormatSupport.isNative(track.url) {
            url = track.url
        } else {
            url = transcode.cachedURL(for: track)
        }
        guard let url else {
            _ = startTrack(track, startAt: position)
            return
        }
        guard loadAndPlay(track, url: url, startAt: position) else { return }
        restoredPosition = 0
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
        return startTrack(track)
    }

    /// Starts a track, routing fallback formats through the transcode cache.
    /// Returns true when the track was accepted, including the asynchronous
    /// "preparing" case, so `next()`/`previous()` do not skip past it.
    /// `startAt` carries a restored position through the async preparation.
    @discardableResult
    private func startTrack(_ track: Track, startAt: TimeInterval = 0) -> Bool {
        guard !track.isMissing else {
            statusMessage = "《\(track.title)》文件缺失，已跳过。"
            return false
        }

        if AudioFormatSupport.isNative(track.url) {
            showsFFmpegInstallPrompt = false
            pendingTranscodeTrack = nil
            return loadAndPlay(track, url: track.url, startAt: startAt)
        }
        if let cached = transcode.cachedURL(for: track) {
            showsFFmpegInstallPrompt = false
            pendingTranscodeTrack = nil
            return loadAndPlay(track, url: cached, startAt: startAt)
        }
        guard let ffmpeg = FFmpegLocator.find(customPath: library.settings.ffmpegPath) else {
            // Leave the current song alone: a missing dependency must never
            // freeze the UI or block formats AVFoundation can play.
            pendingTranscodeTrack = track
            showsFFmpegInstallPrompt = true
            statusMessage = "需要 FFmpeg 才能播放此格式（《\(track.title)》）。"
            return true
        }

        transcode.updateFFmpeg(ffmpeg)
        engine.unload()
        currentTrack = track
        restoredPosition = startAt
        showsFFmpegInstallPrompt = false
        statusMessage = "正在准备《\(track.title)》…"
        preparingTrackID = track.id

        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.transcode.ensureCached(track)
                guard self.preparingTrackID == track.id,
                      self.currentTrack?.id == track.id else { return }
                self.preparingTrackID = nil
                _ = self.loadAndPlay(track, url: url, startAt: startAt)
            } catch {
                guard self.preparingTrackID == track.id else { return }
                self.preparingTrackID = nil
                if case TranscodeError.ffmpegMissing = error {
                    self.pendingTranscodeTrack = track
                    self.showsFFmpegInstallPrompt = true
                    self.statusMessage = "需要 FFmpeg 才能播放此格式（《\(track.title)》）。"
                } else {
                    self.statusMessage = "无法准备《\(track.title)》：\(error.localizedDescription)"
                }
            }
        }
        return true
    }

    /// Loads `url`, optionally seeks while paused, then starts playback so a
    /// restored position never plays a fragment from the start of the song.
    private func loadAndPlay(
        _ track: Track,
        url: URL,
        startAt: TimeInterval = 0
    ) -> Bool {
        preparingTrackID = nil
        do {
            try engine.load(url: url)
        } catch {
            statusMessage = "无法播放《\(track.title)》：\(engine.lastError ?? "未知错误")"
            return false
        }
        if startAt > 0 {
            engine.seek(to: startAt)
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

    // MARK: - Transcode cache & FFmpeg

    var ffmpegPathText: String {
        FFmpegLocator.find(customPath: library.settings.ffmpegPath)?.path ?? "未找到"
    }

    var transcodeCacheSizeText: String {
        transcodeCacheBytes > 0
            ? ByteCountFormatter.string(fromByteCount: transcodeCacheBytes, countStyle: .file)
            : "0 MB"
    }

    func refreshTranscodeCacheSize() {
        transcodeCacheBytes = TranscodeCache.directorySize(transcodeRoot)
    }

    @discardableResult
    func clearTranscodeCache() -> String {
        let message: String
        do {
            let freed = TranscodeCache.directorySize(transcodeRoot)
            try transcode.clearCache()
            refreshTranscodeCacheSize()
            let size = freed > 0
                ? ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
                : "0 MB"
            message = "已清理转码缓存（\(size)）。"
        } catch let transcodeError as TranscodeError {
            message = transcodeError.localizedDescription
        } catch {
            message = "清理转码缓存失败：\(error.localizedDescription)"
        }
        statusMessage = message
        return message
    }

    /// 「重新检测」: users normally run `brew install ffmpeg` and come back.
    @discardableResult
    func redetectFFmpeg() -> String {
        guard let found = FFmpegLocator.find(customPath: library.settings.ffmpegPath) else {
            showsFFmpegInstallPrompt = true
            let message = "仍未找到 FFmpeg，请先运行 brew install ffmpeg。"
            statusMessage = message
            return message
        }
        transcode.updateFFmpeg(found)
        showsFFmpegInstallPrompt = false
        let message = "已找到 FFmpeg：\(found.path)"
        statusMessage = message
        prepareLibraryFormats()
        retryPendingTranscode()
        objectWillChange.send()
        return message
    }

    /// Returns nil when the picker was cancelled.
    @discardableResult
    func chooseFFmpegPath() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择 ffmpeg 可执行文件"
        let response = panel.runModal()
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard response == .OK, let url = panel.url else { return nil }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            let message = "所选文件不可执行，请选择 ffmpeg 可执行文件。"
            statusMessage = message
            return message
        }
        library.settings.ffmpegPath = url.path
        library.saveSettings()
        transcode.updateFFmpeg(url)
        showsFFmpegInstallPrompt = false
        let message = "已使用 FFmpeg：\(url.path)"
        statusMessage = message
        prepareLibraryFormats()
        retryPendingTranscode()
        objectWillChange.send()
        return message
    }

    func copyFFmpegInstallCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("brew install ffmpeg", forType: .string)
        statusMessage = "已复制安装命令：brew install ffmpeg"
    }

    private func retryPendingTranscode() {
        guard let track = pendingTranscodeTrack else { return }
        pendingTranscodeTrack = nil
        _ = startTrack(track, startAt: restoredPosition)
    }

    /// After a scan: fill durations for fallback formats and transcode them in
    /// the background. Without ffmpeg the tracks stay indexed with a duration
    /// of 0 and playback of native formats is unaffected.
    private func prepareLibraryFormats() {
        guard let ffmpeg = FFmpegLocator.find(customPath: library.settings.ffmpegPath) else {
            return
        }
        transcode.updateFFmpeg(ffmpeg)
        for track in tracks
        where !track.isMissing && !AudioFormatSupport.isNative(track.url) {
            transcode.enqueue(track, priority: false)
        }
        fillDurations(using: ffmpeg)
        refreshTranscodeCacheSize()
    }

    private func fillDurations(using ffmpeg: URL) {
        let pending = tracks.filter {
            !$0.isMissing && $0.duration <= 0 && !AudioFormatSupport.isNative($0.url)
        }
        guard !pending.isEmpty else { return }

        Task { [weak self] in
            let durations = await Task.detached(priority: .utility) { () -> [UUID: TimeInterval] in
                var result: [UUID: TimeInterval] = [:]
                for track in pending {
                    if let duration = FFprobeReader.duration(of: track.url, ffmpeg: ffmpeg) {
                        result[track.id] = duration
                    }
                }
                return result
            }.value
            guard let self, !durations.isEmpty else { return }
            self.library.updateDurations(durations)
            self.refreshFromLibrary()
        }
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
        surfacePersistenceError()
        lyricsOverlay?.setLocked(locked)
    }

    /// The overlay and settings sliders emit continuously while dragging, so
    /// the JSON write trails 0.3s behind the last change like the custom accent.
    func setLyricsOpacity(_ opacity: Double) {
        let clamped = min(max(opacity, 0.05), 0.9)
        guard library.settings.lyricsOpacity != clamped else { return }
        library.settings.lyricsOpacity = clamped
        objectWillChange.send()
        lyricsOpacitySaveTask?.cancel()
        lyricsOpacitySaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            self.library.saveSettings()
            self.surfacePersistenceError()
        }
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
        apply(ResolvedLyrics(lyrics: parsed, origin: .override, sourceURL: url), for: track.id)
        statusMessage = "已导入歌词"
    }

    /// 「恢复自动匹配」: drop the override and resolve the normal priority
    /// chain again (sidecar, cache, then online). Success is reported only
    /// after the override file was actually removed; the resolve outcome then
    /// updates the message.
    func restoreAutomaticLyrics() {
        guard let track = currentTrack else { return }
        do {
            try lyricsCache.removeOverride(for: track.id)
        } catch {
            statusMessage = "无法清除歌词覆盖：\(error.localizedDescription)"
            return
        }
        pendingRestoreTrackID = track.id
        loadLyrics(for: track)
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
        if let pending = pendingRestoreTrackID, pending != track?.id {
            pendingRestoreTrackID = nil
        }
        guard let track, !track.isMissing else {
            lyricsState.beginLoading(trackID: nil)
            currentLyricLineIndex = nil
            return
        }

        let trackChanged = lyricsState.trackID != track.id
        lyricsState.beginLoading(trackID: track.id)
        if trackChanged {
            currentLyricLineIndex = nil
        }

        lyricsService.isOnlineEnabled = library.settings.onlineLyricsEnabled
        lyricsTask = Task { [weak self] in
            guard let self else { return }
            let resolved = await self.lyricsService.resolve(for: track)
            guard !Task.isCancelled else { return }
            guard self.currentTrack?.id == track.id else { return }
            self.apply(resolved, for: track.id)
            if self.pendingRestoreTrackID == track.id {
                self.pendingRestoreTrackID = nil
                self.statusMessage = resolved == nil
                    ? "已恢复自动匹配，但未找到歌词"
                    : "已恢复自动匹配"
            }
        }
    }

    private func apply(_ resolved: ResolvedLyrics?, for trackID: UUID) {
        lyricsState.apply(resolved, for: trackID)
        currentLyricLineIndex = nil
        updateCurrentLyricLine(at: engine.position)
    }

    /// `.lrc` keeps its timestamps; plain text is shown line-by-line even if
    /// the file happens to contain bracket-looking text.
    private static func parseImportedLyrics(_ text: String, forcePlain: Bool) -> Lyrics {
        forcePlain ? LRCParser.parsePlainText(text) : LRCParser.parse(text)
    }

    private func updateCurrentLyricLine(at time: TimeInterval) {
        let index = lyrics?.index(at: time)
        guard currentLyricLineIndex != index else { return }
        currentLyricLineIndex = index
    }

    // MARK: - Appearance & preferences

    /// Explicit light/dark modes also recolour native menus and traffic-light
    /// chrome; system mode follows macOS.
    func applyAppearance() {
        let appearance: NSAppearance?
        switch library.settings.mode {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        NSApplication.shared.appearance = appearance
    }

    func setThemePreset(_ preset: ThemePreset) {
        guard library.settings.themePreset != preset.rawValue else { return }
        library.settings.themePreset = preset.rawValue
        saveSettingsAndNotify()
    }

    func setThemeMode(_ mode: ThemeMode) {
        guard library.settings.themeMode != mode.rawValue else { return }
        library.settings.themeMode = mode.rawValue
        applyAppearance()
        saveSettingsAndNotify()
    }

    /// Applied live for immediate preview, but the JSON write is debounced:
    /// `ColorPicker` emits continuously while the user drags the colour wheel.
    func setCustomAccent(hex: String?) {
        guard library.settings.customAccentHex != hex else { return }
        library.settings.customAccentHex = hex
        objectWillChange.send()
        customAccentSaveTask?.cancel()
        customAccentSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            self.library.saveSettings()
        }
    }

    func setRowStyle(cover: Bool) {
        let style = cover ? "cover" : "index"
        guard library.settings.rowStyle != style else { return }
        library.settings.rowStyle = style
        saveSettingsAndNotify()
    }

    func setShowMainSpectrum(_ enabled: Bool) {
        guard library.settings.showMainSpectrum != enabled else { return }
        library.settings.showMainSpectrum = enabled
        library.saveSettings()
        surfacePersistenceError()
        refreshSpectrumConsumers()
        objectWillChange.send()
    }

    func setHideFromScreenCapture(_ hidden: Bool) {
        guard library.settings.hideFromScreenCapture != hidden else { return }
        library.settings.hideFromScreenCapture = hidden
        miniPlayer?.applySettings()
        lyricsOverlay?.applySettings()
        saveSettingsAndNotify()
    }

    func setMiniAlwaysOnTop(_ onTop: Bool) {
        guard library.settings.miniAlwaysOnTop != onTop else { return }
        library.settings.miniAlwaysOnTop = onTop
        miniPlayer?.applySettings()
        saveSettingsAndNotify()
    }

    func setKeepRunningOnClose(_ keepRunning: Bool) {
        guard library.settings.keepRunningOnClose != keepRunning else { return }
        library.settings.keepRunningOnClose = keepRunning
        saveSettingsAndNotify()
    }

    func setOnlineLyricsEnabled(_ enabled: Bool) {
        guard library.settings.onlineLyricsEnabled != enabled else { return }
        library.settings.onlineLyricsEnabled = enabled
        lyricsService.isOnlineEnabled = enabled
        saveSettingsAndNotify()
        if enabled {
            loadLyrics(for: currentTrack)
        }
    }

    /// The spectrum tap runs only while someone draws it: the mini window is
    /// visible, or the main player bar spectrum is enabled.
    func refreshSpectrumConsumers() {
        engine.isSpectrumEnabled = (miniPlayer?.isVisible ?? false)
            || library.settings.showMainSpectrum
    }

    @discardableResult
    func removeMissingTracks() -> String {
        library.removeMissingTracks()
        refreshFromLibrary()
        objectWillChange.send()
        surfacePersistenceError()
        let message = "已移除缺失文件条目。"
        statusMessage = message
        return message
    }

    /// 「移除」 in Settings → 音乐文件夹. Only the index and playlist entries
    /// change; the files on disk are deliberately untouched.
    @discardableResult
    func removeFolder(_ url: URL) -> String {
        library.removeFolder(url)
        if case .folder(let selected) = selection,
           selected.standardizedFileURL == url.standardizedFileURL {
            select(.allMusic)
        }
        refreshFromLibrary()
        objectWillChange.send()
        surfacePersistenceError()
        let message = "已移除文件夹：\(url.lastPathComponent)。"
        statusMessage = message
        return message
    }

    /// Points a missing row at a new file. `updateTrackURLs` keeps the track
    /// ID, so playlist membership and undo history survive the relocation.
    @discardableResult
    func relocateTrack(_ track: Track, to url: URL) -> String {
        library.updateTrackURLs([track.url: url])
        // A relocated file often lives outside the imported folders. Cover it
        // now, or the rescan at the next launch would mark it missing again.
        library.ensureFoldersCovering([url.deletingLastPathComponent()])
        refreshFromLibrary()
        objectWillChange.send()
        surfacePersistenceError()
        let message = "已重新定位《\(track.title)》：\(url.lastPathComponent)"
        statusMessage = message
        return message
    }

    @discardableResult
    func removeMissingTrack(_ track: Track) -> String {
        library.removeTrack(id: track.id)
        refreshFromLibrary()
        objectWillChange.send()
        surfacePersistenceError()
        let message = "已移除《\(track.title)》。"
        statusMessage = message
        return message
    }

    private func saveSettingsAndNotify() {
        library.saveSettings()
        surfacePersistenceError()
        objectWillChange.send()
    }

    /// A persistence failure must not live only in `LibraryStore.lastError`.
    /// Called after user-triggered writes; automatic playback-state saves stay
    /// silent so a full disk cannot spam the banner every five seconds.
    private func surfacePersistenceError() {
        guard let error = library.lastError else { return }
        statusMessage = "保存失败：\(error.localizedDescription)"
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
        showsFFmpegInstallPrompt = false
        pendingTranscodeTrack = nil
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
        // Space/arrows belong to the main window only. Any presented sheet
        // (settings, tag editor, organizer) owns the keyboard, and panels such
        // as the lyrics overlay must not receive playback shortcuts.
        guard NSApp.modalWindow == nil,
              !isSettingsPresented,
              tagEditorRequest == nil,
              organizerRequest == nil,
              isMainWindowKey,
              !isSearchFocused,
              !isEditingText else { return false }
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

    private var isMainWindowKey: Bool {
        guard let window = NSApp.keyWindow else { return false }
        return !(window is NSPanel) && !window.isSheet && window.canBecomeMain
    }
}
