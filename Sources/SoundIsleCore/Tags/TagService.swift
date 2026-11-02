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

/// Which tag fields a container format can actually store. The editor uses
/// this to disable controls instead of letting a write fail after the fact.
public struct TagFormatCapabilities: Equatable {
    public var canWrite: Bool
    public var canWriteAlbumArtist: Bool
    public var canWriteArtwork: Bool
    /// Chinese explanation shown next to disabled controls.
    public var limitation: String?

    public init(
        canWrite: Bool = true,
        canWriteAlbumArtist: Bool = true,
        canWriteArtwork: Bool = true,
        limitation: String? = nil
    ) {
        self.canWrite = canWrite
        self.canWriteAlbumArtist = canWriteAlbumArtist
        self.canWriteArtwork = canWriteArtwork
        self.limitation = limitation
    }

    public static func capabilities(for url: URL) -> TagFormatCapabilities {
        switch url.pathExtension.lowercased() {
        case "mp3", "mp2", "m4a", "m4b", "mp4", "aac", "flac", "ape",
             "ogg", "oga", "opus", "aif", "aiff", "aifc":
            return TagFormatCapabilities()
        case "wav", "wave":
            // TagLib 1.13 cannot create an ID3v2 chunk in a WAV that lacks
            // one, so an INFO-only WAV is read-only for us.
            guard wavHasID3Chunk(url) else {
                return TagFormatCapabilities(
                    canWrite: false,
                    canWriteAlbumArtist: false,
                    canWriteArtwork: false,
                    limitation: "这个 WAV 文件没有 ID3v2 标签块，无法写入标签。"
                )
            }
            return TagFormatCapabilities()
        case "wma", "asf":
            // The TagLib bridge rejects these fields for ASF rather than
            // silently dropping them.
            return TagFormatCapabilities(
                canWriteAlbumArtist: false,
                canWriteArtwork: false,
                limitation: "WMA/ASF 格式不支持写入专辑歌手或封面。"
            )
        default:
            return TagFormatCapabilities(
                canWrite: false,
                canWriteAlbumArtist: false,
                canWriteArtwork: false,
                limitation: "不支持的音频格式，无法写入标签。"
            )
        }
    }

    /// Combines the capabilities of a multi-selection. A field is writable
    /// only when every file supports it. The explanation prefers a reason that
    /// blocks writing entirely over a field-level limitation.
    public static func combined(for urls: [URL]) -> TagFormatCapabilities {
        urls.reduce(TagFormatCapabilities()) { partial, url in
            let next = capabilities(for: url)
            let limitation: String?
            if !next.canWrite {
                limitation = next.limitation ?? partial.limitation
            } else if !partial.canWrite {
                limitation = partial.limitation ?? next.limitation
            } else {
                limitation = partial.limitation ?? next.limitation
            }
            return TagFormatCapabilities(
                canWrite: partial.canWrite && next.canWrite,
                canWriteAlbumArtist: partial.canWriteAlbumArtist && next.canWriteAlbumArtist,
                canWriteArtwork: partial.canWriteArtwork && next.canWriteArtwork,
                limitation: limitation
            )
        }
    }

    /// Walks the RIFF chunk list looking for an `id3 ` chunk. Reads only the
    /// chunk headers, never the audio payload.
    private static func wavHasID3Chunk(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), header.count == 12 else { return false }
        let magic = String(decoding: header.prefix(4), as: UTF8.self)
        guard magic == "RIFF" || magic == "RF64" else { return false }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let total = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        var offset: UInt64 = 12
        var visited = 0
        while offset + 8 <= total, visited < 4096 {
            visited += 1
            try? handle.seek(toOffset: offset)
            guard let chunk = try? handle.read(upToCount: 8), chunk.count == 8 else { return false }
            let bytes = [UInt8](chunk)
            if String(decoding: bytes.prefix(4), as: UTF8.self).lowercased() == "id3 " {
                return true
            }
            let size = UInt64(bytes[4])
                | UInt64(bytes[5]) << 8
                | UInt64(bytes[6]) << 16
                | UInt64(bytes[7]) << 24
            let next = offset + 8 + size + (size % 2)
            guard next > offset else { return false }
            offset = next
        }
        return false
    }
}
