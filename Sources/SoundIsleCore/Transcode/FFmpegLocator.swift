import Foundation

/// Finds the ffmpeg CLI: the path chosen in Settings first, then the two
/// Homebrew locations, then whatever `PATH` resolves.
public enum FFmpegLocator {
    private static let fixedCandidates = [
        "/usr/local/bin/ffmpeg",
        "/opt/homebrew/bin/ffmpeg",
    ]

    public static func find(
        customPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let manager = FileManager.default

        if let customPath {
            let trimmed = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, manager.isExecutableFile(atPath: trimmed) {
                return URL(fileURLWithPath: trimmed)
            }
        }

        for candidate in fixedCandidates where manager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }

        let searchPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in searchPath.split(separator: ":") {
            let candidate = String(directory) + "/ffmpeg"
            if manager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// ffprobe ships next to ffmpeg in Homebrew installs; a custom ffmpeg path
    /// is expected to follow the same layout.
    public static func ffprobe(for ffmpeg: URL) -> URL? {
        let sibling = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }
}

/// Reads the duration of formats AVFoundation cannot open. `ffprobe` is a
/// sibling of the configured `ffmpeg`; without it the duration stays unknown
/// and the track shows 0.
public struct FFprobeReader {
    public static func duration(of url: URL, ffmpeg: URL) -> TimeInterval? {
        guard let ffprobe = FFmpegLocator.ffprobe(for: ffmpeg) else { return nil }

        let process = Process()
        process.executableURL = ffprobe
        process.arguments = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=nw=1:nk=1",
            url.path,
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Double(text),
              value > 0 else { return nil }
        return value
    }
}
