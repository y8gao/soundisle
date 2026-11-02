import Foundation

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
        index = store.loadIndex()
        playlists = store.loadPlaylists()
        settings = store.loadSettings()
    }

    /// Settings are written through the store that owns them, so `AppModel`
    /// never needs a second `IndexStore` competing for the same file.
    public func saveSettings() {
        do {
            try store.saveSettings(settings)
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

    public func rescan(reader: MetadataReading = AVFoundationMetadataReader()) async {
        guard !index.folders.isEmpty else {
            unreadableURLs = []
            return
        }

        let result = await LibraryScanner.scan(folders: index.folders, reader: reader)
        unreadableURLs = result.unreadable
        let unreadablePaths = Set(result.unreadable.map { $0.standardizedFileURL.path })

        var existingByPath: [String: Track] = [:]
        for track in index.tracks {
            existingByPath[track.url.standardizedFileURL.path] = track
        }

        var scannedPaths = Set<String>()
        var kept: [Track] = []
        var rebuild: [Track] = []
        for scanned in result.tracks {
            let path = scanned.url.standardizedFileURL.path
            scannedPaths.insert(path)
            guard let existing = existingByPath.removeValue(forKey: path) else {
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
            // An unreadable file still exists; only vanished files are missing.
            if !unreadablePaths.contains(track.url.standardizedFileURL.path) {
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
        } catch {
            lastError = error
        }
    }

    /// Single writer for `playlists.json`: `AppModel` syncs its `PlaylistStore`
    /// back into `playlists` and calls this, so no second `IndexStore` exists.
    public func savePlaylists() {
        do {
            try store.savePlaylists(playlists)
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
