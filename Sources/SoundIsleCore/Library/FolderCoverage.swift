import Foundation

/// Keeps the library's scanned folders in sync with organizer destinations.
///
/// The library is folder-based: a file moved outside every imported folder is
/// invisible to the next rescan, so the chosen destination root must be added
/// when no existing folder already contains it.
public enum FolderCoverage {
    /// Returns `folders` standardized and deduplicated, appending
    /// `destination` when no existing folder is that path or one of its
    /// ancestors. The result is safe to persist as `index.folders`.
    public static func ensureCovered(destination: URL, folders: [URL]) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()
        for folder in folders {
            let standardized = folder.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { continue }
            result.append(standardized)
        }

        let root = destination.standardizedFileURL
        let covered = result.contains { isAncestor($0, of: root) }
        if !covered, seen.insert(root.path).inserted {
            result.append(root)
        }
        return result
    }

    private static func isAncestor(_ folder: URL, of url: URL) -> Bool {
        if url.path == folder.path { return true }
        let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        return url.path.hasPrefix(prefix)
    }
}
