import Foundation

/// Finds the ffmpeg/ffprobe CLI pair: the path chosen in Settings first, then
/// the two Homebrew locations, then whatever `PATH` resolves.
public enum FFmpegLocator {
    /// Homebrew (Intel and Apple Silicon) and MacPorts. The last one matters:
    /// a MacPorts install lives in `/opt/local/bin`, which a GUI app's `PATH`
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`) never contains, so ffmpeg was right
    /// there on disk while the app insisted it was missing.
    public static let defaultFixedDirectories = [
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "/opt/local/bin",
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

        return findExecutable(
            named: "ffmpeg",
            in: defaultFixedDirectories + searchDirectories(environment: environment)
        )
    }

    /// ffprobe normally ships next to ffmpeg. A lone custom ffmpeg still gets
    /// durations when a system ffprobe exists, via the same fixed/PATH search.
    public static func ffprobe(
        for ffmpeg: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fixedDirectories: [String] = FFmpegLocator.defaultFixedDirectories
    ) -> URL? {
        let sibling = ffmpeg.deletingLastPathComponent().appendingPathComponent("ffprobe")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        return findExecutable(
            named: "ffprobe",
            in: fixedDirectories + searchDirectories(environment: environment)
        )
    }

    private static func searchDirectories(environment: [String: String]) -> [String] {
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return path.split(separator: ":").map(String.init)
    }

    private static func findExecutable(named name: String, in directories: [String]) -> URL? {
        let manager = FileManager.default
        for directory in directories {
            let candidate = directory + "/" + name
            if manager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}

/// Reads the duration of formats AVFoundation cannot open. Without an ffprobe
/// the duration stays unknown and the track shows 0.
public struct FFprobeReader {
    public static func duration(
        of url: URL,
        ffmpeg: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TimeInterval? {
        guard let ffprobe = FFmpegLocator.ffprobe(for: ffmpeg, environment: environment) else {
            return nil
        }

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
