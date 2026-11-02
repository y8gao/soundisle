import Foundation

/// One completed tag edit, kept so the user can roll it back. `before` and
/// `after` are the full tag snapshots read around the write, not just the
/// fields that changed.
public struct TagUndoEntry: Codable, Equatable {
    public var url: URL
    public var before: TagFields
    public var after: TagFields
    public var date: Date

    public init(url: URL, before: TagFields, after: TagFields, date: Date = Date()) {
        self.url = url
        self.before = before
        self.after = after
        self.date = date
    }
}

/// Persists `TagUndoEntry` records under the app's `undo/` directory and
/// restores the previous tag snapshot through `TagService`.
///
/// The newest entry is last. A failed restore keeps the entry so a transient
/// write error never loses the user's undo history.
public final class TagEditUndoStore {
    public private(set) var entries: [TagUndoEntry] = []

    private let directory: URL
    private let limit: Int
    private let service: TagService
    private let manager: FileManager

    public init(directory: URL, limit: Int = 50, manager: FileManager = .default) {
        self.directory = directory
        self.limit = max(limit, 1)
        self.manager = manager
        self.service = TagService()
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        entries = Self.load(from: fileURL, manager: manager)
    }

    private var fileURL: URL {
        directory.appendingPathComponent("tag-edits.json")
    }

    public func record(_ entry: TagUndoEntry) throws {
        var updated = entries
        updated.append(entry)
        if updated.count > limit {
            updated.removeFirst(updated.count - limit)
        }
        try Self.save(updated, to: fileURL, manager: manager)
        entries = updated
    }

    /// Restores the most recent entry's `before` tags and removes it.
    public func undoLast() throws -> TagUndoEntry? {
        guard let entry = entries.last else { return nil }
        // Nil means "leave unchanged" for TagService, so fields that did not
        // exist before the edit are cleared explicitly ("" text, 0 numbers).
        try service.write(Self.restorePayload(entry), to: entry.url)

        var updated = entries
        updated.removeLast()
        try Self.save(updated, to: fileURL, manager: manager)
        entries = updated
        return entry
    }

    public func clear() throws {
        if manager.fileExists(atPath: fileURL.path) {
            try manager.removeItem(at: fileURL)
        }
        entries = []
    }

    /// Restores every field, including clearing ones the edit introduced.
    private static func restorePayload(_ entry: TagUndoEntry) -> TagFields {
        var payload = entry.before
        if entry.before.title == nil, entry.after.title != nil { payload.title = "" }
        if entry.before.artist == nil, entry.after.artist != nil { payload.artist = "" }
        if entry.before.album == nil, entry.after.album != nil { payload.album = "" }
        if entry.before.albumArtist == nil, entry.after.albumArtist != nil { payload.albumArtist = "" }
        if entry.before.genre == nil, entry.after.genre != nil { payload.genre = "" }
        if entry.before.year == nil, entry.after.year != nil { payload.year = 0 }
        if entry.before.trackNumber == nil, entry.after.trackNumber != nil { payload.trackNumber = 0 }
        if entry.before.artworkBase64 == nil, entry.after.artworkBase64 != nil {
            payload.artworkBase64 = ""
        }
        return payload
    }

    private static func load(from url: URL, manager: FileManager) -> [TagUndoEntry] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([TagUndoEntry].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func save(_ entries: [TagUndoEntry], to url: URL, manager: FileManager) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
