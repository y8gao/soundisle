import Foundation

/// One completed organize run. `copy` decides how undo reverses it: copies
/// remove the destination, moves put the file back at its source.
public struct OrganizeUndoEntry: Codable, Equatable {
    public var items: [OrganizePlanItem]
    public var copy: Bool
    public var date: Date

    public init(items: [OrganizePlanItem], copy: Bool, date: Date = Date()) {
        self.items = items
        self.copy = copy
        self.date = date
    }
}

/// Persists organize plans under the app's `undo/` directory (alongside tag
/// edits) and reverses the files on `undoLast`.
///
/// The newest entry is last. Files are reversed in reverse order, and the
/// entry is only removed once every existing destination was restored, so a
/// failed undo keeps the history for a retry. Names that already exist at the
/// restore location are never overwritten.
public final class OrganizeUndoStore {
    public private(set) var entries: [OrganizeUndoEntry] = []
    /// Chinese notice when the history had to be recovered or was unreadable.
    public private(set) var loadNotice: String?

    private let directory: URL
    private let limit: Int
    private let manager: FileManager

    public init(directory: URL, limit: Int = 50, manager: FileManager = .default) {
        self.directory = directory
        self.limit = max(limit, 1)
        self.manager = manager
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let loaded = Self.load(from: directory.appendingPathComponent("organize.json"),
                               limit: self.limit,
                               manager: manager)
        entries = loaded.entries
        loadNotice = loaded.notice
    }

    private var fileURL: URL {
        directory.appendingPathComponent("organize.json")
    }

    public func record(_ items: [OrganizePlanItem], copy: Bool) throws {
        guard !items.isEmpty else { return }
        var updated = entries
        updated.append(OrganizeUndoEntry(items: items, copy: copy))
        if updated.count > limit {
            updated.removeFirst(updated.count - limit)
        }
        try Self.save(updated, to: fileURL, manager: manager)
        entries = updated
    }

    /// Reverses the newest plan and returns the rows it actually restored.
    /// Missing destinations are skipped: a partially applied plan stays
    /// undoable, and the caller's restored count is truthful.
    public func undoLast() throws -> [OrganizePlanItem]? {
        guard let entry = entries.last else { return nil }

        var restored: [OrganizePlanItem] = []
        do {
            for item in entry.items.reversed() {
                let destination = item.destination.standardizedFileURL
                let source = item.source.standardizedFileURL
                guard manager.fileExists(atPath: destination.path) else { continue }

                if entry.copy {
                    try manager.removeItem(at: destination)
                } else {
                    guard !manager.fileExists(atPath: source.path) else {
                        throw OrganizeError.restoreConflict(source)
                    }
                    try manager.createDirectory(
                        at: source.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try OrganizeFileOps.move(from: destination, to: source, manager: manager)
                }
                restored.append(item)
            }
        } catch {
            throw OrganizeError.undoFailed(restored: restored, underlying: error)
        }

        var updated = entries
        updated.removeLast()
        try Self.save(updated, to: fileURL, manager: manager)
        entries = updated
        return restored
    }

    public func clear() throws {
        try BackupJSON.remove(from: fileURL, manager: manager)
        entries = []
    }

    private static func load(
        from url: URL,
        limit: Int,
        manager: FileManager
    ) -> (entries: [OrganizeUndoEntry], notice: String?) {
        let loaded = BackupJSON.load([OrganizeUndoEntry].self, from: url, manager: manager)
        let notice: String?
        switch loaded.source {
        case .backup:
            notice = L("整理撤销记录已从备份恢复。")
        case .corrupt:
            notice = L("整理撤销记录已损坏，无法读取。")
        case .primary, .missing:
            notice = nil
        }
        guard let decoded = loaded.value else { return ([], notice) }
        return (Array(decoded.suffix(max(limit, 1))), notice)
    }

    private static func save(_ entries: [OrganizeUndoEntry], to url: URL, manager: FileManager) throws {
        try BackupJSON.save(entries, to: url, manager: manager)
    }
}
