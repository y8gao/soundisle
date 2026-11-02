import AVFoundation
import Foundation

public struct AudioMetadata {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var year: Int?
    public var trackNumber: Int?
    public var genre: String?
    public var duration: TimeInterval
    public var artworkData: Data?

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        year: Int? = nil,
        trackNumber: Int? = nil,
        genre: String? = nil,
        duration: TimeInterval = 0,
        artworkData: Data? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.year = year
        self.trackNumber = trackNumber
        self.genre = genre
        self.duration = duration
        self.artworkData = artworkData
    }
}

public protocol MetadataReading {
    func read(url: URL) async -> AudioMetadata?
}

public struct AVFoundationMetadataReader: MetadataReading {
    public init() {}

    public func read(url: URL) async -> AudioMetadata? {
        let asset = AVURLAsset(url: url)

        let seconds: TimeInterval
        do {
            seconds = CMTimeGetSeconds(try await asset.load(.duration))
        } catch {
            return nil
        }
        guard seconds.isFinite, seconds >= 0 else { return nil }

        var metadata = AudioMetadata(duration: seconds)
        let common = (try? await asset.load(.commonMetadata)) ?? []
        let all = (try? await asset.load(.metadata)) ?? []

        for item in common + all {
            if metadata.artworkData == nil, item.commonKey == .commonKeyArtwork {
                metadata.artworkData = try? await item.load(.dataValue)
                continue
            }

            let identifier = item.identifier?.rawValue.lowercased() ?? ""
            switch item.commonKey?.rawValue {
            case AVMetadataKey.commonKeyTitle.rawValue:
                if metadata.title == nil { metadata.title = await text(of: item) }
            case AVMetadataKey.commonKeyArtist.rawValue:
                if metadata.artist == nil { metadata.artist = await text(of: item) }
            case AVMetadataKey.commonKeyAlbumName.rawValue:
                if metadata.album == nil { metadata.album = await text(of: item) }
            case AVMetadataKey.commonKeyType.rawValue:
                if metadata.genre == nil { metadata.genre = await text(of: item) }
            case AVMetadataKey.commonKeyCreationDate.rawValue:
                if metadata.year == nil {
                    metadata.year = await text(of: item).flatMap(Self.year(from:))
                }
            default:
                if metadata.albumArtist == nil, identifier.contains("albumartist") || identifier.contains("tpe2") {
                    metadata.albumArtist = await text(of: item)
                } else if metadata.trackNumber == nil, identifier.contains("tracknumber") || identifier.contains("trck") {
                    metadata.trackNumber = await text(of: item).flatMap(Self.leadingInt(from:))
                } else if metadata.year == nil, identifier.contains("year") || identifier.contains("releasedate") || identifier.contains("tyer") || identifier.contains("tdrc") {
                    metadata.year = await text(of: item).flatMap(Self.year(from:))
                } else if metadata.genre == nil, identifier.contains("genre") {
                    metadata.genre = await text(of: item)
                }
            }
        }

        return metadata
    }

    private func text(of item: AVMetadataItem) async -> String? {
        if let string = try? await item.load(.stringValue) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let number = try? await item.load(.numberValue) {
            return number.stringValue
        }
        return nil
    }

    private static func leadingInt(from string: String) -> Int? {
        let digits = string.prefix { $0.isNumber }
        return Int(digits)
    }

    private static func year(from string: String) -> Int? {
        let digits = string.prefix { $0.isNumber }
        guard digits.count >= 4, let year = Int(digits.prefix(4)), year > 0 else { return nil }
        return year
    }
}
