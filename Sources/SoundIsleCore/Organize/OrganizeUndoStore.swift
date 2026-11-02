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

    private let directory: URL
    private let limit: Int
    private let manager: FileManager

    public init(directory: URL, limit: Int = 50, manager: FileManager = .default) {
        self.directory = directory
        self.limit = max(limit, 1)
        self.manager = manager
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        entries = Self.load(from: fileURL, limit: self.limit)
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
        if manager.fileExists(atPath: fileURL.path) {
            try manager.removeItem(at: fileURL)
        }
        entries = []
    }

    private static func load(from url: URL, limit: Int) -> [OrganizeUndoEntry] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([OrganizeUndoEntry].self, from: data) else {
            return []
        }
        return Array(decoded.suffix(max(limit, 1)))
    }

    private static func save(_ entries: [OrganizeUndoEntry], to url: URL, manager: FileManager) throws {
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
