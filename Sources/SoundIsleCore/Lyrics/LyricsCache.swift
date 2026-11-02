import CryptoKit
import Foundation

/// On-disk lyrics cache under the app data directory's `lyrics/` folder.
///
/// Online hits are keyed by title + artist + whole-second duration and survive
/// relaunches, so a second play works offline. Manual overrides use the track
/// UUID directly so they keep winning even after a rescan changes the path.
public final class LyricsCache {
    private let directory: URL
    private let manager: FileManager

    public init(directory: URL, manager: FileManager = .default) {
        self.directory = directory
        self.manager = manager
    }

    // MARK: - Online cache

    public func load(title: String, artist: String, duration: TimeInterval) -> Lyrics? {
        read(from: fileURL(for: Self.key(title: title, artist: artist, duration: duration)))
    }

    public func save(
        _ lyrics: Lyrics,
        title: String,
        artist: String,
        duration: TimeInterval
    ) throws {
        try write(lyrics, to: fileURL(for: Self.key(title: title, artist: artist, duration: duration)))
    }

    // MARK: - Manual override

    public func saveOverride(_ lyrics: Lyrics, for trackID: UUID) throws {
        try write(lyrics, to: overrideURL(for: trackID))
    }

    public func loadOverride(for trackID: UUID) -> Lyrics? {
        read(from: overrideURL(for: trackID))
    }

    public func removeOverride(for trackID: UUID) throws {
        let url = overrideURL(for: trackID)
        guard manager.fileExists(atPath: url.path) else { return }
        try manager.removeItem(at: url)
    }

    // MARK: - Private

    private static func key(title: String, artist: String, duration: TimeInterval) -> String {
        let normalized = [title, artist].map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return normalized.joined(separator: "\u{1F}")
            + "\u{1F}" + String(Int(duration.rounded()))
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent(Self.hash(key) + ".json")
    }

    private func overrideURL(for trackID: UUID) -> URL {
        directory.appendingPathComponent("override-\(trackID.uuidString).json")
    }

    private func write(_ lyrics: Lyrics, to url: URL) throws {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stored = StoredLyrics(
            isSynced: lyrics.isSynced,
            lines: lyrics.lines.map { StoredLyrics.Line(time: $0.time, text: $0.text) }
        )
        let data = try JSONEncoder().encode(stored)
        try data.write(to: url, options: .atomic)
    }

    /// A missing or corrupt cache entry is a miss, never an error: lyrics are
    /// always re-fetchable.
    private func read(from url: URL) -> Lyrics? {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(StoredLyrics.self, from: data) else {
            return nil
        }
        return Lyrics(
            lines: stored.lines.map { LyricLine(time: $0.time, text: $0.text) },
            isSynced: stored.isSynced
        )
    }

    private struct StoredLyrics: Codable {
        let isSynced: Bool
        let lines: [Line]

        struct Line: Codable {
            let time: TimeInterval
            let text: String
        }
    }
}
