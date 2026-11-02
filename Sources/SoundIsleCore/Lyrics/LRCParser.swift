import Foundation

/// One lyric line and the playback time it becomes current.
public struct LyricLine: Equatable {
    public let time: TimeInterval
    public let text: String

    public init(time: TimeInterval, text: String) {
        self.time = time
        self.text = text
    }
}

/// Parsed lyrics. Synced lyrics carry real timestamps; plain text has
/// `isSynced == false` and every line at time 0.
public struct Lyrics: Equatable {
    public var lines: [LyricLine]
    public var isSynced: Bool

    public init(lines: [LyricLine] = [], isSynced: Bool = false) {
        self.lines = lines
        self.isSynced = isSynced
    }

    /// Index of the line active at `time`: the last line whose timestamp is at
    /// or before it. `nil` before the first line or for unsynced lyrics.
    public func index(at time: TimeInterval) -> Int? {
        guard isSynced, !lines.isEmpty else { return nil }
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].time <= time {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low == 0 ? nil : low - 1
    }
}

/// Parses LRC text. Supports several timestamps on one line and a global
/// `[offset:±ms]`. Files without any timestamp fall back to plain text.
public enum LRCParser {
    private static let timestampPattern = try! NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#
    )
    private static let offsetPattern = try! NSRegularExpression(
        pattern: #"\[offset:\s*([+-]?\d+)\s*\]"#,
        options: [.caseInsensitive]
    )
    /// LRC metadata tags such as `[ti:…]`, `[ar:…]`. They never become lyrics.
    private static let metadataPattern = try! NSRegularExpression(
        pattern: #"^\[[A-Za-z]+:.*\]$"#
    )

    public static func parse(_ text: String) -> Lyrics {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var offset: TimeInterval = 0
        var timed: [LyricLine] = []
        var plain: [LyricLine] = []

        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)

            if let match = offsetPattern.firstMatch(in: line, range: fullRange),
               let valueRange = Range(match.range(at: 1), in: line),
               let milliseconds = Double(line[valueRange]) {
                offset = milliseconds / 1000
                continue
            }

            let matches = timestampPattern.matches(in: line, range: fullRange)
            if matches.isEmpty {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                let trimmedRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
                if metadataPattern.firstMatch(in: trimmed, range: trimmedRange) != nil {
                    continue
                }
                plain.append(LyricLine(time: 0, text: trimmed))
                continue
            }

            // The lyric text follows the last timestamp on the line.
            let text: String
            if let last = matches.last, let range = Range(last.range, in: line) {
                text = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                text = ""
            }

            for match in matches {
                func group(_ index: Int) -> String? {
                    guard let range = Range(match.range(at: index), in: line) else { return nil }
                    return String(line[range])
                }
                guard let minutes = group(1).flatMap(Double.init),
                      let seconds = group(2).flatMap(Double.init) else { continue }
                var fraction: TimeInterval = 0
                if let digitsText = group(3), let digits = Double(digitsText) {
                    fraction = digits / pow(10, Double(digitsText.count))
                }
                timed.append(LyricLine(time: minutes * 60 + seconds + fraction, text: text))
            }
        }

        guard !timed.isEmpty else {
            return Lyrics(lines: plain, isSynced: false)
        }
        let adjusted = timed.map { LyricLine(time: $0.time + offset, text: $0.text) }
        return Lyrics(lines: adjusted.sorted { $0.time < $1.time }, isSynced: true)
    }

    /// Plain-text imports are shown line by line, even when the file happens to
    /// contain bracket-looking timestamps. Timestamps are stripped, while
    /// untimed lines are kept; blank lines and metadata tags are dropped and
    /// every line is unsynced at time 0.
    public static func parsePlainText(_ text: String) -> Lyrics {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var lines: [LyricLine] = []
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let trimmedRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if metadataPattern.firstMatch(in: trimmed, range: trimmedRange) != nil {
                continue
            }

            let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
            line = timestampPattern.stringByReplacingMatches(
                in: line,
                range: fullRange,
                withTemplate: ""
            )
            let cleanedRange = NSRange(line.startIndex..<line.endIndex, in: line)
            line = offsetPattern.stringByReplacingMatches(
                in: line,
                range: cleanedRange,
                withTemplate: ""
            )
            let text = line.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                lines.append(LyricLine(time: 0, text: text))
            }
        }
        return Lyrics(lines: lines, isSynced: false)
    }
}
