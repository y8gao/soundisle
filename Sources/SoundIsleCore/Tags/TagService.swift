import CTagLib
import Foundation

/// Editable tag fields. Every field is optional with a `nil` default so callers
/// can update a subset while leaving the rest untouched.
public struct TagFields: Codable, Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var year: Int?
    public var trackNumber: Int?
    public var genre: String?
    public var artworkBase64: String?

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        year: Int? = nil,
        trackNumber: Int? = nil,
        genre: String? = nil,
        artworkBase64: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.year = year
        self.trackNumber = trackNumber
        self.genre = genre
        self.artworkBase64 = artworkBase64
    }
}

public enum TagServiceError: LocalizedError {
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .writeFailed(let message): return message
        }
    }
}

/// Reads and writes audio tags through the TagLib C++ bridge.
public final class TagService {
    public init() {}

    public func read(from url: URL) -> TagFields? {
        let json: String? = url.withUnsafeFileSystemRepresentation { path in
            guard let path, let cString = soundisle_read_tags(path) else { return nil }
            defer { soundisle_free(cString) }
            return String(cString: cString)
        }
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TagFields.self, from: data)
    }

    public func write(_ fields: TagFields, to url: URL) throws {
        let data = Self.jsonData(from: fields)
        guard let json = String(data: data, encoding: .utf8) else {
            throw TagServiceError.writeFailed("标签数据编码失败")
        }

        var errorPointer: UnsafeMutablePointer<CChar>?
        let status: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return json.withCString { soundisle_write_tags(path, $0, &errorPointer) }
        }

        guard status == 0 else {
            let message = errorPointer.map { String(cString: $0) } ?? "写入标签失败"
            if let errorPointer { soundisle_free(errorPointer) }
            throw TagServiceError.writeFailed(message)
        }
    }

    public static func jsonData(from fields: TagFields) -> Data {
        (try? JSONEncoder().encode(fields)) ?? Data("{}".utf8)
    }
}
