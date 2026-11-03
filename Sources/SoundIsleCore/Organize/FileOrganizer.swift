import Foundation

/// One row of a preview: where a file lives now, and where the template puts
/// it. `conflictResolved` means the destination was auto-numbered because a
/// file (or another planned row) already occupies the plain name.
public struct OrganizePlanItem: Codable, Equatable {
    public var source: URL
    public var destination: URL
    public var conflictResolved: Bool

    public init(source: URL, destination: URL, conflictResolved: Bool) {
        self.source = source
        self.destination = destination
        self.conflictResolved = conflictResolved
    }
}

/// URL mappings the library applies after an organize run. Kept in the core so
/// partial apply/undo paths share (and can test) the same direction logic.
public enum OrganizeURLMapping {
    public static func apply(_ items: [OrganizePlanItem]) -> [URL: URL] {
        var mapping: [URL: URL] = [:]
        for item in items {
            mapping[item.source.standardizedFileURL] = item.destination.standardizedFileURL
        }
        return mapping
    }

    public static func undo(_ items: [OrganizePlanItem]) -> [URL: URL] {
        var mapping: [URL: URL] = [:]
        for item in items {
            mapping[item.destination.standardizedFileURL] = item.source.standardizedFileURL
        }
        return mapping
    }
}

public enum OrganizeError: LocalizedError {
    case sourceMissing(URL)
    case destinationExists(URL)
    case restoreConflict(URL)
    case applyFailed(applied: [OrganizePlanItem], underlying: Error)
    case undoFailed(restored: [OrganizePlanItem], underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing(let url):
            return "源文件不存在：\(url.lastPathComponent)"
        case .destinationExists(let url):
            return "目标文件已存在，未覆盖：\(url.lastPathComponent)"
        case .restoreConflict(let url):
            return "原位置已有同名文件，未覆盖：\(url.path)"
        case .applyFailed(_, let error):
            return "整理失败：\(error.localizedDescription)"
        case .undoFailed(_, let error):
            return "撤销整理失败：\(error.localizedDescription)"
        }
    }
}

/// Plans and executes tag-based file organization. Planning never touches the
/// disk; `apply` refuses to overwrite, records the plan for undo first, and a
/// cross-volume move falls back to copy-then-delete.
public final class FileOrganizer {
    public let undo: OrganizeUndoStore
    private let manager: FileManager

    public init(undo: OrganizeUndoStore, manager: FileManager = .default) {
        self.undo = undo
        self.manager = manager
    }

    /// Computes the preview. Files already at their template destination are
    /// skipped so re-running 整理文件 never renames a file to ` (2)`.
    public func plan(
        _ tracks: [Track],
        template: String,
        root: URL
    ) -> [OrganizePlanItem] {
        var planned = Set<String>()
        var items: [OrganizePlanItem] = []

        for track in tracks {
            let source = track.url.standardizedFileURL
            let target = OrganizeTemplate.render(template: template, track: track, root: root)
                .standardizedFileURL
            guard target.path != source.path else { continue }

            var destination = target
            var number = 2
            while planned.contains(destination.path) || manager.fileExists(atPath: destination.path) {
                destination = Self.numbered(target, number)
                number += 1
            }
            planned.insert(destination.path)
            items.append(
                OrganizePlanItem(
                    source: track.url,
                    destination: destination,
                    conflictResolved: destination.path != target.path
                )
            )
        }
        return items
    }

    /// Moves or copies every planned file. The whole plan is recorded before
    /// the first write so a mid-run failure can still be undone. `progress`
    /// runs after each completed file and may be called from a background
    /// queue, so the UI can report "正在整理 n/total…".
    public func apply(
        _ items: [OrganizePlanItem],
        copy: Bool,
        progress: ((_ completed: Int, _ total: Int) -> Void)? = nil
    ) throws {
        guard !items.isEmpty else { return }
        try preflight(items)
        try undo.record(items, copy: copy)

        var applied: [OrganizePlanItem] = []
        do {
            for item in items {
                try manager.createDirectory(
                    at: item.destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if copy {
                    try manager.copyItem(at: item.source, to: item.destination)
                } else {
                    try OrganizeFileOps.move(from: item.source, to: item.destination, manager: manager)
                }
                applied.append(item)
                progress?(applied.count, items.count)
            }
        } catch {
            throw OrganizeError.applyFailed(applied: applied, underlying: error)
        }
    }

    /// Restores the newest plan and returns it so the caller can point the
    /// library index back at the source URLs.
    @discardableResult
    public func undoLast() throws -> [OrganizePlanItem]? {
        try undo.undoLast()
    }

    /// Whether a move would cross volumes. The UI asks for confirmation before
    /// the source is deleted, because that move is copy-then-delete. If the
    /// volumes cannot be determined, this returns true: failing closed asks
    /// the user rather than deleting without consent.
    public static func crossesVolumes(
        source: URL,
        destination: URL,
        manager: FileManager = .default
    ) -> Bool {
        guard let from = volumeIdentifier(for: source, manager: manager),
              let to = volumeIdentifier(for: destination, manager: manager) else {
            return true
        }
        return from != to
    }

    // MARK: - Private

    private func preflight(_ items: [OrganizePlanItem]) throws {
        for item in items {
            guard manager.fileExists(atPath: item.source.path) else {
                throw OrganizeError.sourceMissing(item.source)
            }
            guard !manager.fileExists(atPath: item.destination.path) else {
                throw OrganizeError.destinationExists(item.destination)
            }
            guard item.source.standardizedFileURL.path != item.destination.standardizedFileURL.path else {
                throw OrganizeError.destinationExists(item.destination)
            }
        }
    }

    private static func numbered(_ url: URL, _ number: Int) -> URL {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let name = ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)"
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    private static func volumeIdentifier(for url: URL, manager: FileManager) -> NSObject? {
        // Walk string paths: URL.deletingLastPathComponent() turns "/" into
        // "/..", which would loop forever when nothing exists on disk.
        var path = url.standardizedFileURL.path
        while !manager.fileExists(atPath: path) {
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path || parent.isEmpty { return nil }
            path = parent
        }
        guard let values = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.volumeIdentifierKey]) else {
            return nil
        }
        return values.volumeIdentifier as? NSObject
    }
}

enum OrganizeFileOps {
    /// `moveItem` is atomic within one volume. Across volumes it fails, so the
    /// core falls back to copy-then-delete; the UI has already asked the user
    /// before this point. A failed copy leaves the source untouched.
    static func move(from: URL, to: URL, manager: FileManager) throws {
        do {
            try manager.moveItem(at: from, to: to)
        } catch {
            try manager.copyItem(at: from, to: to)
            try manager.removeItem(at: from)
        }
    }
}
