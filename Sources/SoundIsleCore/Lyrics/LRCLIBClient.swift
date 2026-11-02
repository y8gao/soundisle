import Foundation

/// Fetches lyrics for a track. Injected into `LyricsService` so tests can
/// supply a fake and so a future provider could be added without touching the
/// priority logic.
public protocol LyricsFetching {
    func fetch(title: String, artist: String, duration: TimeInterval) async throws -> Lyrics?
}

/// LRCLIB's `/api/get` endpoint. Synced lyrics win over plain lyrics; a 404 or
/// a hit without any lyrics is a normal miss (`nil`). Other statuses and
/// transport failures throw so the caller can decide to stay silent.
public struct LRCLIBClient: LyricsFetching {
    public enum ClientError: Error, Equatable {
        case invalidURL
        case badStatus(Int)
    }

    private static let endpoint = URL(string: "https://lrclib.net/api/get")!
    private static let userAgent = "SoundIsle/0.1"

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(title: String, artist: String, duration: TimeInterval) async throws -> Lyrics? {
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded()))),
        ]
        guard let url = components?.url else { throw ClientError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.badStatus(-1) }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.badStatus(http.statusCode)
        }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
        if let synced = payload.syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines),
           !synced.isEmpty {
            let parsed = LRCParser.parse(synced)
            return parsed.lines.isEmpty ? nil : parsed
        }
        if let plain = payload.plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines),
           !plain.isEmpty {
            // LRCLIB's plain text is shown line-by-line without timing.
            let parsed = LRCParser.parse(plain)
            return parsed.lines.isEmpty
                ? nil
                : Lyrics(lines: parsed.lines.map { LyricLine(time: 0, text: $0.text) }, isSynced: false)
        }
        return nil
    }

    private struct Payload: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
    }
}
