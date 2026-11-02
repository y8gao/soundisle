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

            switch item.commonKey?.rawValue {
            case AVMetadataKey.commonKeyTitle.rawValue:
                if metadata.title == nil { metadata.title = await text(of: item) }
            case AVMetadataKey.commonKeyArtist.rawValue:
                if metadata.artist == nil { metadata.artist = await text(of: item) }
            case AVMetadataKey.commonKeyAlbumName.rawValue:
                if metadata.album == nil { metadata.album = await text(of: item) }
            case AVMetadataKey.commonKeyCreationDate.rawValue:
                if metadata.year == nil { metadata.year = await year(of: item) }
            default:
                switch item.identifier?.rawValue {
                case AVMetadataIdentifier.iTunesMetadataAlbumArtist.rawValue,
                     AVMetadataIdentifier.id3MetadataBand.rawValue:
                    if metadata.albumArtist == nil { metadata.albumArtist = await text(of: item) }
                case AVMetadataIdentifier.iTunesMetadataTrackNumber.rawValue,
                     AVMetadataIdentifier.id3MetadataTrackNumber.rawValue:
                    if metadata.trackNumber == nil {
                        metadata.trackNumber = await text(of: item).flatMap(Self.leadingInt(from:))
                    }
                case AVMetadataIdentifier.iTunesMetadataReleaseDate.rawValue,
                     AVMetadataIdentifier.id3MetadataYear.rawValue,
                     AVMetadataIdentifier.id3MetadataRecordingTime.rawValue,
                     AVMetadataIdentifier.quickTimeMetadataYear.rawValue:
                    if metadata.year == nil { metadata.year = await year(of: item) }
                case AVMetadataIdentifier.iTunesMetadataUserGenre.rawValue,
                     AVMetadataIdentifier.iTunesMetadataPredefinedGenre.rawValue,
                     AVMetadataIdentifier.id3MetadataContentType.rawValue,
                     AVMetadataIdentifier.quickTimeMetadataGenre.rawValue:
                    if metadata.genre == nil { metadata.genre = await text(of: item) }
                default:
                    break
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

    private func year(of item: AVMetadataItem) async -> Int? {
        if let date = try? await item.load(.dateValue),
           let year = Calendar(identifier: .gregorian).dateComponents([.year], from: date).year {
            return year
        }
        return await text(of: item).flatMap(Self.year(from:))
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
