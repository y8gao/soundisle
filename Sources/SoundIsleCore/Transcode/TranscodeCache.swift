import CryptoKit
import Foundation

/// Cache identity for transcoded files. The key covers the source path, size,
/// modification time and the transcode parameter version, so editing or
/// re-encoding a source file naturally produces a new cache entry.
public enum TranscodeCache {
    public static let version = 1

    public static func key(
        url: URL,
        fileSize: Int64,
        modifiedAt: Date,
        version: Int = version
    ) -> String {
        let milliseconds = Int64((modifiedAt.timeIntervalSince1970 * 1000).rounded())
        let raw = "\(url.standardizedFileURL.path)|\(fileSize)|\(milliseconds)|\(version)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(32))
    }

    public static func cacheURL(for track: Track, root: URL) -> URL {
        let key = key(url: track.url, fileSize: track.fileSize, modifiedAt: track.modifiedAt)
        return root.appendingPathComponent("\(key).m4a")
    }

    /// Total size of the cached files, for the settings screen.
    public static func directorySize(_ root: URL) -> Int64 {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
