import Foundation

/// JSON persistence for the library, playlists and settings.
///
/// Every file is separate: a corrupt `library.json` can only cost the index,
/// never the playlists, settings or `undo/` records. Each write keeps the
/// previous version in a sibling `.bak` file and replaces atomically.
public final class IndexStore {
    public let directory: URL
    private let manager: FileManager
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(directory: URL, manager: FileManager = .default) {
        self.directory = directory
        self.manager = manager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    private func fileURL(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    // MARK: - Index

    /// Where a decoded value came from. `library.json` can be recovered from
    /// its `.bak`, but callers must be able to tell the user that happened.
    enum LoadSource: Equatable {
        case primary
        case backup
        /// A file existed but neither it nor its `.bak` could be decoded.
        case unreadable
        /// Nothing was written yet (first launch), which is not a failure.
        case absent
    }

    public func loadIndex() -> LibraryIndex {
        loadIndexOutcome().value
    }

    func loadIndexOutcome() -> (value: LibraryIndex, source: LoadSource) {
        let result = decode(LibraryIndex.self, from: fileURL("library.json"))
        return (result.value ?? LibraryIndex(), result.source)
    }

    public func saveIndex(_ index: LibraryIndex) throws {
        try write(index, to: fileURL("library.json"))
    }

    // MARK: - Playlists

    public func loadPlaylists() -> [Playlist] {
        loadPlaylistsOutcome().value
    }

    func loadPlaylistsOutcome() -> (value: [Playlist], source: LoadSource) {
        let result = decode([Playlist].self, from: fileURL("playlists.json"))
        return (result.value ?? [], result.source)
    }

    public func savePlaylists(_ playlists: [Playlist]) throws {
        try write(playlists, to: fileURL("playlists.json"))
    }

    // MARK: - Settings

    public func loadSettings() -> AppSettings {
        loadSettingsOutcome().value
    }

    func loadSettingsOutcome() -> (value: AppSettings, source: LoadSource) {
        let result = decode(AppSettings.self, from: fileURL("settings.json"))
        return (result.value ?? AppSettings(), result.source)
    }

    public func saveSettings(_ settings: AppSettings) throws {
        try write(settings, to: fileURL("settings.json"))
    }

    // MARK: - Atomic write and backup

    private func decode<T: Decodable>(
        _ type: T.Type,
        from url: URL
    ) -> (value: T?, source: LoadSource) {
        // Current file first, previous version second. Anything unreadable is
        // treated as absent instead of thrown so callers always get a value,
        // but the source lets them report recovery in the UI.
        if let data = try? Data(contentsOf: url),
           let value = try? decoder.decode(T.self, from: data) {
            return (value, .primary)
        }
        let backup = url.appendingPathExtension("bak")
        if let data = try? Data(contentsOf: backup),
           let value = try? decoder.decode(T.self, from: data) {
            return (value, .backup)
        }
        let anyFileExists = manager.fileExists(atPath: url.path)
            || manager.fileExists(atPath: backup.path)
        return (nil, anyFileExists ? .unreadable : .absent)
    }

    private func write<T: Codable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = url.appendingPathExtension("tmp")
        try data.write(to: temporary, options: .atomic)
        defer { try? manager.removeItem(at: temporary) }

        guard manager.fileExists(atPath: url.path) else {
            try manager.moveItem(at: temporary, to: url)
            return
        }

        // Rotate only a decodable file into `.bak`; a corrupt current file must
        // never overwrite the last good backup.
        if let current = try? Data(contentsOf: url),
           (try? decoder.decode(T.self, from: current)) != nil {
            let backup = url.appendingPathExtension("bak")
            try? manager.removeItem(at: backup)
            try manager.copyItem(at: url, to: backup)
        }
        _ = try manager.replaceItemAt(url, withItemAt: temporary)
    }
}
