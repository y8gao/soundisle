import Foundation

public struct Track: Identifiable, Codable, Hashable {
    public var id: UUID
    public var url: URL
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtist: String?
    public var year: Int?
    public var trackNumber: Int?
    public var genre: String?
    public var duration: TimeInterval
    public var fileSize: Int64
    public var modifiedAt: Date
    public var artworkFileName: String?
    public var isMissing: Bool

    public init(
        id: UUID = UUID(),
        url: URL,
        title: String,
        artist: String = "",
        album: String = "",
        albumArtist: String? = nil,
        year: Int? = nil,
        trackNumber: Int? = nil,
        genre: String? = nil,
        duration: TimeInterval = 0,
        fileSize: Int64 = 0,
        modifiedAt: Date = Date(),
        artworkFileName: String? = nil,
        isMissing: Bool = false
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.year = year
        self.trackNumber = trackNumber
        self.genre = genre
        self.duration = duration
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.artworkFileName = artworkFileName
        self.isMissing = isMissing
    }
}

public enum TrackFactory {
    /// Builds a `Track` from a file URL, preferring non-empty metadata fields
    /// over values inferred from the filename.
    public static func make(url: URL, metadata: AudioMetadata?, id: UUID = UUID()) -> Track {
        let parsed = FilenameParser.parse(filename: url.lastPathComponent)
        let stem = (url.lastPathComponent as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)

        func clean(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return nil }
            return trimmed
        }

        let title = clean(metadata?.title) ?? clean(parsed.title) ?? stem

        return Track(
            id: id,
            url: url,
            title: title,
            artist: clean(metadata?.artist) ?? parsed.artist ?? "",
            album: clean(metadata?.album) ?? "",
            albumArtist: clean(metadata?.albumArtist),
            year: metadata?.year,
            trackNumber: metadata?.trackNumber ?? parsed.trackNumber,
            genre: clean(metadata?.genre),
            duration: metadata?.duration ?? 0,
            fileSize: (attributes?[.size] as? NSNumber)?.int64Value ?? 0,
            modifiedAt: attributes?[.modificationDate] as? Date ?? Date(),
            artworkFileName: nil
        )
    }
}
