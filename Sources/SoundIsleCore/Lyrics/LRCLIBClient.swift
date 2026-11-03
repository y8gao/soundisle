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

    /// `https://lrclib.net/api/get`; a custom endpoint keeps the same
    /// `track_name` / `artist_name` / `duration` query contract.
    public static let defaultEndpoint = URL(string: "https://lrclib.net/api/get")!
    private static let userAgent = "SoundIsle/0.1"

    private let endpoint: URL
    private let session: URLSession

    public init(endpoint: URL? = nil, session: URLSession = .shared) {
        self.endpoint = endpoint ?? Self.defaultEndpoint
        self.session = session
    }

    /// Validates a user-entered endpoint. Empty, relative or non-http(s)
    /// values are rejected so a typo never replaces the LRCLIB fallback.
    public static func endpointURL(from raw: String?) -> URL? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else { return nil }
        return url
    }

    /// The endpoint a client should use: the configured one when valid,
    /// otherwise LRCLIB's default.
    public static func resolvedEndpoint(_ raw: String?) -> URL {
        endpointURL(from: raw) ?? defaultEndpoint
    }

    public func fetch(title: String, artist: String, duration: TimeInterval) async throws -> Lyrics? {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        queryItems.append(contentsOf: [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "duration", value: String(Int(duration.rounded()))),
        ])
        components?.queryItems = queryItems
        guard let url = components?.url else { throw ClientError.invalidURL }

        var request = URLRequest(url: url)
        // Keep a hung/offline lookup from holding the default 60s timeout.
        request.timeoutInterval = 10
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.badStatus(-1) }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.badStatus(http.statusCode)
        }

        if let payload = try? JSONDecoder().decode(Payload.self, from: data) {
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

        // Compatible providers may return the LRC/plain text file directly.
        // Timestamps make it synced; otherwise the parser yields plain lines.
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let parsed = LRCParser.parse(text)
        return parsed.lines.isEmpty ? nil : parsed
    }

    private struct Payload: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
    }
}
