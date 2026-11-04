import Foundation

/// Why a folder rename was refused. Messages are user-facing (Chinese) so the
/// caller can surface `localizedDescription` directly.
public enum FolderRenameError: LocalizedError {
    case invalidName
    case destinationExists(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            return L("文件夹名称不能为空，也不能包含“/”或“:”。")
        case .destinationExists(let name):
            return Lf("已存在同名文件夹：%@。", name)
        }
    }
}

/// Owns the in-memory library and persists it through `IndexStore`.
/// Rescans are incremental: unchanged files keep their `Track` untouched,
/// changed files keep their `id`, and vanished files stay in the index marked
/// `isMissing` so playlists never silently lose entries.
///
/// Main-actor isolated: views read `index` directly, while the expensive
/// scanning and metadata work is awaited inside nonisolated helpers.
@MainActor
public final class LibraryStore {
    public var index: LibraryIndex
    public var playlists: [Playlist]
    public var settings: AppSettings

    /// Files under the imported folders that could not be read on the last scan.
    public private(set) var unreadableURLs: [URL] = []
    /// Last persistence failure, for diagnostics in the settings screen.
    public private(set) var lastError: Error?
    /// User-facing notice when a load had to recover from `.bak` or fall
    /// back to defaults, so corruption is never silent.
    public private(set) var recoveryNotice: String?

    public var missingTracks: [Track] {
        index.tracks.filter(\.isMissing)
    }

    private let directory: URL
    private let store: IndexStore
    private let manager: FileManager

    private var coversDirectory: URL {
        directory.appendingPathComponent("covers", isDirectory: true)
    }

    public init(directory: URL, manager: FileManager = .default) {
        self.directory = directory
        self.manager = manager
        self.store = IndexStore(directory: directory, manager: manager)
        self.index = LibraryIndex()
        self.playlists = []
        self.settings = AppSettings()
    }

    public func load() {
        let indexResult = store.loadIndexOutcome()
        index = indexResult.value
        let playlistsResult = store.loadPlaylistsOutcome()
        playlists = playlistsResult.value
        let settingsResult = store.loadSettingsOutcome()
        settings = settingsResult.value
        recoveryNotice = Self.recoveryNotice([
            (L("曲库"), indexResult.source),
            (L("播放列表"), playlistsResult.source),
            (L("设置"), settingsResult.source),
        ])
        normalizeIndexMojibake()
    }

    /// A rescan keeps unchanged rows verbatim, so an index written before
    /// `TrackFactory` repaired mojibake would stay garbled forever. Repair the
    /// display strings once at load and persist the healed index.
    private func normalizeIndexMojibake() {
        var changed = false
        for position in index.tracks.indices {
            var track = index.tracks[position]
            let title = Self.repaired(track.title)
            let artist = Self.repaired(track.artist)
            let album = Self.repaired(track.album)
            let albumArtist = track.albumArtist.map(Self.repaired)
            guard title != track.title
                    || artist != track.artist
                    || album != track.album
                    || albumArtist != track.albumArtist else { continue }
            track.title = title
            track.artist = artist
            track.album = album
            track.albumArtist = albumArtist
            index.tracks[position] = track
            changed = true
        }
        if changed {
            saveIndex()
        }
    }

    private static func repaired(_ text: String) -> String {
        MojibakeRepair.repaired(text) ?? text
    }

    private static func recoveryNotice(
        _ sources: [(name: String, source: IndexStore.LoadSource)]
    ) -> String? {
        let backedUp = sources.filter { $0.source == .backup }.map(\.name)
        let unreadable = sources.filter { $0.source == .unreadable }.map(\.name)
        var parts: [String] = []
        if !backedUp.isEmpty {
            parts.append(Lf("%@已从备份恢复", backedUp.joined(separator: "/")))
        }
        if !unreadable.isEmpty {
            parts.append(Lf("%@无法读取，已使用默认数据", unreadable.joined(separator: "/")))
        }
        return parts.isEmpty ? nil : parts.joined(separator: L("；")) + L("。")
    }

    /// Settings are written through the store that owns them, so `AppModel`
    /// never needs a second `IndexStore` competing for the same file.
    public func saveSettings() {
        do {
            try store.saveSettings(settings)
            lastError = nil
        } catch {
            lastError = error
        }
    }

    public func addFolder(
        _ url: URL,
        reader: MetadataReading = AVFoundationMetadataReader()
    ) async {
        let folder = url.standardizedFileURL
        if !index.folders.contains(where: { $0.standardizedFileURL == folder }) {
            index.folders.append(folder)
        }
        await rescan(reader: reader)
    }

    /// Removes a folder and the tracks that live inside it. Playlist entries for
    /// those tracks are pruned because the user explicitly removed the folder.
    public func removeFolder(_ url: URL) {
        let folder = url.standardizedFileURL
        index.folders.removeAll { $0.standardizedFileURL == folder }
        let prefix = folder.path + "/"
        unreadableURLs.removeAll { $0.standardizedFileURL.path.hasPrefix(prefix) }
        removeTracks { $0.url.standardizedFileURL.path.hasPrefix(prefix) }
    }

    /// Renames an imported folder on disk and rewrites every URL that lived
    /// under it. Track IDs, metadata and playlist membership are preserved,
    /// so the rename is invisible to playback history.
    ///
    /// The directory move happens first; if persisting the updated index
    /// fails, the move is rolled back so disk and index stay in sync.
    @discardableResult
    public func renameFolder(at url: URL, toName name: String) throws -> URL {
        let source = url.standardizedFileURL
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains(":") else {
            throw FolderRenameError.invalidName
        }
        let destination = source.deletingLastPathComponent()
            .appendingPathComponent(trimmed, isDirectory: true)
        guard !manager.fileExists(atPath: destination.path) else {
            throw FolderRenameError.destinationExists(trimmed)
        }

        try manager.moveItem(at: source, to: destination)

        let sourcePrefix = source.path + "/"
        let destinationPrefix = destination.path + "/"
        func relocated(_ url: URL) -> URL? {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(sourcePrefix) else { return nil }
            return URL(fileURLWithPath: destinationPrefix + path.dropFirst(sourcePrefix.count))
        }

        let originalIndex = index
        let originalUnreadable = unreadableURLs

        if let position = index.folders.firstIndex(where: { $0.standardizedFileURL == source }) {
            index.folders[position] = destination
        }
        for position in index.tracks.indices {
            if let newURL = relocated(index.tracks[position].url) {
                index.tracks[position].url = newURL
            }
        }
        unreadableURLs = unreadableURLs.map { relocated($0) ?? $0 }

        do {
            // Atomic write; throws before touching the current file if the
            // temporary copy cannot be written.
            try store.saveIndex(index)
            lastError = nil
        } catch {
            index = originalIndex
            unreadableURLs = originalUnreadable
            try? manager.moveItem(at: destination, to: source)
            lastError = error
            throw error
        }
        savePlaylists()
        return destination
    }

    public func rescan(reader: MetadataReading = AVFoundationMetadataReader()) async {
        await rescan(folders: index.folders, scoped: false, reader: reader)
    }

    /// Rescans one imported folder. Tracks outside it are left exactly as they
    /// were, so refreshing one folder never marks unrelated files missing.
    public func rescan(
        folder: URL,
        reader: MetadataReading = AVFoundationMetadataReader()
    ) async {
        let folder = folder.standardizedFileURL
        guard index.folders.contains(where: { $0.standardizedFileURL == folder }) else { return }
        await rescan(folders: [folder], scoped: true, reader: reader)
    }

    private func rescan(
        folders: [URL],
        scoped: Bool,
        reader: MetadataReading
    ) async {
        guard !folders.isEmpty else {
            if !scoped { unreadableURLs = [] }
            return
        }

        let prefixes = folders.map { $0.standardizedFileURL.path + "/" }
        func inScope(_ url: URL) -> Bool {
            !scoped || prefixes.contains { url.standardizedFileURL.path.hasPrefix($0) }
        }

        let result = await LibraryScanner.scan(folders: folders, reader: reader)
        unreadableURLs = scoped
            ? unreadableURLs.filter { !inScope($0) } + result.unreadable
            : result.unreadable
        let unreadablePaths = Set(result.unreadable.map { $0.standardizedFileURL.path })

        var existingByPath: [String: Track] = [:]
        for track in index.tracks {
            existingByPath[track.url.standardizedFileURL.path] = track
        }

        var scannedPaths = Set<String>()
        var newPaths = Set<String>()
        var kept: [Track] = []
        var rebuild: [Track] = []
        for scanned in result.tracks {
            let path = scanned.url.standardizedFileURL.path
            scannedPaths.insert(path)
            guard let existing = existingByPath.removeValue(forKey: path) else {
                newPaths.insert(path)
                rebuild.append(scanned)
                continue
            }
            if existing.fileSize == scanned.fileSize && existing.modifiedAt == scanned.modifiedAt {
                var keep = existing
                keep.isMissing = false
                kept.append(keep)
            } else {
                var updated = scanned
                updated.id = existing.id
                updated.artworkFileName = existing.artworkFileName
                rebuild.append(updated)
            }
        }

        // Rename/move detection: a vanished row whose file size *and*
        // modification date match exactly one newly discovered path is the
        // same file under a new name. Reusing the row keeps its id, metadata
        // and playlist entries, and suppresses the new path as a duplicate.
        // Zero or several candidates leave the old row missing (ambiguous).
        struct FileFingerprint: Hashable {
            let size: Int64
            let modified: Date
        }
        func fingerprint(_ track: Track) -> FileFingerprint {
            FileFingerprint(size: track.fileSize, modified: track.modifiedAt)
        }

        var newByFingerprint: [FileFingerprint: [String]] = [:]
        var newTrackByPath: [String: Track] = [:]
        for track in rebuild where newPaths.contains(track.url.standardizedFileURL.path) {
            let path = track.url.standardizedFileURL.path
            newByFingerprint[fingerprint(track), default: []].append(path)
            newTrackByPath[path] = track
        }
        var missingByFingerprint: [FileFingerprint: [UUID]] = [:]
        for track in index.tracks {
            let path = track.url.standardizedFileURL.path
            guard !scannedPaths.contains(path),
                  inScope(track.url),
                  !unreadablePaths.contains(path) else { continue }
            missingByFingerprint[fingerprint(track), default: []].append(track.id)
        }
        var renamedURLs: [UUID: URL] = [:]
        var consumedPaths = Set<String>()
        for (key, paths) in newByFingerprint {
            guard paths.count == 1,
                  let missing = missingByFingerprint[key],
                  missing.count == 1,
                  let id = missing.first,
                  let track = newTrackByPath[paths[0]] else { continue }
            renamedURLs[id] = track.url
            consumedPaths.insert(paths[0])
        }
        if !consumedPaths.isEmpty {
            rebuild.removeAll { consumedPaths.contains($0.url.standardizedFileURL.path) }
        }

        // `ScanResult` only carries `Track`, which drops embedded artwork, so
        // new/changed files are read once more for covers. Unchanged files skip.
        let artwork = await artworkData(for: rebuild, reader: reader)
        let rebuilt = rebuild.map { track -> Track in
            var track = track
            if let data = artwork[track.url.standardizedFileURL.path],
               let name = saveArtwork(data, for: track.id) {
                track.artworkFileName = name
            }
            return track
        }

        var tracks = kept + rebuilt
        for track in index.tracks where !scannedPaths.contains(track.url.standardizedFileURL.path) {
            var track = track
            if let newURL = renamedURLs[track.id] {
                track.url = newURL
                track.isMissing = false
            } else if inScope(track.url),
                      !unreadablePaths.contains(track.url.standardizedFileURL.path) {
                // A folder-scoped rescan only judges files it actually
                // scanned; everything outside the folder is carried over.
                track.isMissing = true
            }
            tracks.append(track)
        }
        index.tracks = tracks
        saveIndex()
    }

    public func updateTrack(_ track: Track) {
        guard let position = index.tracks.firstIndex(where: { $0.id == track.id }) else { return }
        index.tracks[position] = track
        saveIndex()
    }

    /// Fills in durations read by ffprobe after a scan. Tracks that already
    /// know their duration are left alone, and one save covers the batch.
    public func updateDurations(_ durations: [UUID: TimeInterval]) {
        guard !durations.isEmpty else { return }
        var changed = false
        for position in index.tracks.indices {
            guard let duration = durations[index.tracks[position].id],
                  duration > 0,
                  index.tracks[position].duration <= 0 else { continue }
            index.tracks[position].duration = duration
            changed = true
        }
        if changed {
            saveIndex()
        }
    }

    /// Points tracks at new file locations after an organize (or its undo).
    /// IDs and playlist membership are untouched, so playlists keep working.
    /// Keys are matched standardized, and one save covers the whole batch.
    public func updateTrackURLs(_ mapping: [URL: URL]) {
        guard !mapping.isEmpty else { return }
        var normalized: [URL: URL] = [:]
        for (source, destination) in mapping {
            normalized[source.standardizedFileURL] = destination.standardizedFileURL
        }

        var changed = false
        for position in index.tracks.indices {
            let current = index.tracks[position].url.standardizedFileURL
            guard let destination = normalized[current] else { continue }
            index.tracks[position].url = destination
            index.tracks[position].isMissing = false
            changed = true
        }
        if changed {
            saveIndex()
        }
    }

    /// Adds imported folders so files organized into a new root survive the
    /// next rescan. Returns true when `index.folders` changed.
    @discardableResult
    public func ensureFoldersCovering(_ urls: [URL]) -> Bool {
        var folders = index.folders
        var changed = false
        for url in urls {
            let updated = FolderCoverage.ensureCovered(destination: url, folders: folders)
            if updated != folders {
                folders = updated
                changed = true
            }
        }
        guard changed else { return false }
        index.folders = folders
        saveIndex()
        return true
    }

    public func removeMissingTracks() {
        removeTracks { $0.isMissing }
    }

    /// Removes a single row (used by the missing-file list) and prunes any
    /// playlist entries that pointed at it.
    public func removeTrack(id: UUID) {
        removeTracks { $0.id == id }
    }

    /// Removes several rows in one save. Files on disk are never touched.
    public func removeTracks(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        removeTracks { ids.contains($0.id) }
    }

    // MARK: - Private

    private func removeTracks(where predicate: (Track) -> Bool) {
        let removed = index.tracks.filter(predicate)
        if !removed.isEmpty {
            let ids = Set(removed.map(\.id))
            index.tracks.removeAll { ids.contains($0.id) }
            playlists = playlists.map { playlist in
                var playlist = playlist
                playlist.trackIDs.removeAll { ids.contains($0) }
                return playlist
            }
            for track in removed {
                deleteArtwork(track)
            }
        }
        saveIndex()
        if !removed.isEmpty {
            savePlaylists()
        }
    }

    private func saveIndex() {
        do {
            try store.saveIndex(index)
            lastError = nil
        } catch {
            lastError = error
        }
    }

    /// Single writer for `playlists.json`: `AppModel` syncs its `PlaylistStore`
    /// back into `playlists` and calls this, so no second `IndexStore` exists.
    public func savePlaylists() {
        do {
            try store.savePlaylists(playlists)
            lastError = nil
        } catch {
            lastError = error
        }
    }

    /// Cached cover for a track, when the artwork file still exists.
    public func artworkURL(for track: Track) -> URL? {
        guard let name = track.artworkFileName else { return nil }
        let url = coversDirectory.appendingPathComponent(name)
        return manager.fileExists(atPath: url.path) ? url : nil
    }

    /// Replaces or removes the cached cover after a tag edit, so the list shows
    /// the new artwork without a full rescan. `nil` deletes the cached file.
    public func setArtwork(_ data: Data?, for trackID: UUID) {
        guard let position = index.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        var track = index.tracks[position]
        if let data {
            guard let name = saveArtwork(data, for: trackID) else { return }
            track.artworkFileName = name
        } else {
            deleteArtwork(track)
            track.artworkFileName = nil
        }
        index.tracks[position] = track
        saveIndex()
    }

    private func artworkData(for tracks: [Track], reader: MetadataReading) async -> [String: Data] {
        guard !tracks.isEmpty else { return [:] }
        var result: [String: Data] = [:]
        await withTaskGroup(of: (String, Data?).self) { group in
            for track in tracks {
                let url = track.url
                group.addTask {
                    (url.standardizedFileURL.path, await reader.read(url: url)?.artworkData)
                }
            }
            for await (path, data) in group {
                if let data { result[path] = data }
            }
        }
        return result
    }

    @discardableResult
    private func saveArtwork(_ data: Data, for id: UUID) -> String? {
        let name = "\(id.uuidString).jpg"
        do {
            try manager.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
            try data.write(to: coversDirectory.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            lastError = error
            return nil
        }
    }

    private func deleteArtwork(_ track: Track) {
        guard let name = track.artworkFileName else { return }
        try? manager.removeItem(at: coversDirectory.appendingPathComponent(name))
    }
}
