import Foundation

public struct ParsedFilename: Equatable {
    public var title: String
    public var artist: String?
    public var trackNumber: Int?

    public init(title: String, artist: String? = nil, trackNumber: Int? = nil) {
        self.title = title
        self.artist = artist
        self.trackNumber = trackNumber
    }
}

public enum FilenameParser {
    private static let trackPrefix = try! NSRegularExpression(pattern: "^(\\d{1,3})[.\\s-]+")

    /// Rules, in order: strip extension -> leading `NN.` / `NN ` / `NN-` track
    /// number -> `" - "` split (artist left, title right) -> `"-"` split
    /// (title left, artist right) -> whole string is the title.
    public static func parse(filename: String) -> ParsedFilename {
        let ns = (filename as NSString).deletingPathExtension as NSString
        var name = ns.trimmingCharacters(in: .whitespaces)
        var trackNumber: Int?

        let fullRange = NSRange(location: 0, length: (name as NSString).length)
        if let match = trackPrefix.firstMatch(in: name, range: fullRange),
           let number = Int((name as NSString).substring(with: match.range(at: 1))) {
            trackNumber = number
            let end = match.range.location + match.range.length
            name = (name as NSString).substring(from: end).trimmingCharacters(in: .whitespaces)
        }

        if let separator = name.range(of: " - ", options: .backwards) {
            let artist = String(name[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
            let title = String(name[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !artist.isEmpty && !title.isEmpty {
                return ParsedFilename(title: title, artist: artist, trackNumber: trackNumber)
            }
        }

        if let separator = name.range(of: "-", options: .backwards) {
            let title = String(name[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
            let artist = String(name[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty && !artist.isEmpty {
                return ParsedFilename(title: title, artist: artist, trackNumber: trackNumber)
            }
        }

        return ParsedFilename(title: name, artist: nil, trackNumber: trackNumber)
    }
}
