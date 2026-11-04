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
    /// Chinese notice when the history had to be recovered or was unreadable.
    public private(set) var loadNotice: String?

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
        let loaded = Self.load(from: directory.appendingPathComponent("tag-edits.json"),
                               limit: self.limit,
                               manager: manager)
        entries = loaded.entries
        loadNotice = loaded.notice
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
        try BackupJSON.remove(from: fileURL, manager: manager)
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

    private static func load(
        from url: URL,
        limit: Int,
        manager: FileManager
    ) -> (entries: [TagUndoEntry], notice: String?) {
        let loaded = BackupJSON.load([TagUndoEntry].self, from: url, manager: manager)
        let notice: String?
        switch loaded.source {
        case .backup:
            notice = L("标签编辑撤销记录已从备份恢复。")
        case .corrupt:
            notice = L("标签编辑撤销记录已损坏，无法读取。")
        case .primary, .missing:
            notice = nil
        }
        guard let decoded = loaded.value else { return ([], notice) }
        // A store written with a larger limit must not exceed this one.
        return (Array(decoded.suffix(max(limit, 1))), notice)
    }

    private static func save(_ entries: [TagUndoEntry], to url: URL, manager: FileManager) throws {
        try BackupJSON.save(entries, to: url, manager: manager)
    }
}
