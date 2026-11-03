import Foundation

/// Where the displayed lyrics came from. `none` is the "暂无歌词" state.
public enum LyricsOrigin: String, Codable, Equatable {
    case override
    case sidecar
    case online
    case none
}

public struct ResolvedLyrics {
    public var lyrics: Lyrics
    public var origin: LyricsOrigin
    public var sourceURL: URL?

    public init(lyrics: Lyrics, origin: LyricsOrigin, sourceURL: URL? = nil) {
        self.lyrics = lyrics
        self.origin = origin
        self.sourceURL = sourceURL
    }
}

/// Display-side lyrics state, kept in core so the track-change transition is
/// testable without the app target.
///
/// `beginLoading(trackID:)` clears the previous track's lyrics synchronously.
/// A slow network lookup therefore cannot leave the old song's lines and
/// highlighted line on screen while the new track resolves. Same-track
/// retries/restores keep the current lyrics until the new result arrives.
public struct LyricsDisplayState: Equatable {
    public private(set) var trackID: UUID?
    public private(set) var lyrics: Lyrics?
    public private(set) var origin: LyricsOrigin
    public private(set) var isResolving: Bool

    public init() {
        trackID = nil
        lyrics = nil
        origin = .none
        isResolving = false
    }

    /// Starts resolution for `trackID`. Returns `true` when lyrics from a
    /// different track were cleared.
    @discardableResult
    public mutating func beginLoading(trackID: UUID?) -> Bool {
        guard let trackID else {
            let cleared = lyrics != nil
            self.trackID = nil
            lyrics = nil
            origin = .none
            isResolving = false
            return cleared
        }

        let trackChanged = self.trackID != trackID
        let cleared = trackChanged && lyrics != nil
        if trackChanged {
            self.trackID = trackID
            lyrics = nil
            origin = .none
        }
        isResolving = true
        return cleared
    }

    /// Applies an async result only when it belongs to the selected track, so
    /// a cancelled lookup that finishes late cannot overwrite newer lyrics.
    public mutating func finish(_ resolved: ResolvedLyrics?, for trackID: UUID) {
        guard self.trackID == trackID else { return }
        apply(resolved, for: trackID)
    }

    /// Applies a result immediately (manual override import or a direct
    /// resolution).
    public mutating func apply(_ resolved: ResolvedLyrics?, for trackID: UUID) {
        self.trackID = trackID
        lyrics = resolved?.lyrics
        origin = resolved?.origin ?? .none
        isResolving = false
    }
}

/// Resolves lyrics in priority order: manual override, same-name `.lrc`
/// sidecar, cached online hit, then a live LRCLIB query.
///
/// `isOnlineEnabled` gates only the live query. An override, sidecar or cache
/// hit still resolves when the user has turned online lyrics off. Network
/// failures are swallowed here; callers stay silent and offer a retry.
public final class LyricsService {
    private let cache: LyricsCache
    private let client: LyricsFetching

    public var isOnlineEnabled = true

    public init(cache: LyricsCache, client: LyricsFetching) {
        self.cache = cache
        self.client = client
    }

    public func resolve(for track: Track) async -> ResolvedLyrics? {
        if let override = cache.loadOverride(for: track.id), !override.lines.isEmpty {
            return ResolvedLyrics(lyrics: override, origin: .override)
        }

        if let url = LyricsSidecar.find(for: track),
           let text = Self.readText(at: url) {
            let parsed = LRCParser.parse(text)
            if !parsed.lines.isEmpty {
                return ResolvedLyrics(lyrics: parsed, origin: .sidecar, sourceURL: url)
            }
        }

        if let cached = cache.load(
            title: track.title,
            artist: track.artist,
            duration: track.duration
        ), !cached.lines.isEmpty {
            return ResolvedLyrics(lyrics: cached, origin: .online)
        }

        guard isOnlineEnabled,
              !track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        do {
            guard let fetched = try await client.fetch(
                title: track.title,
                artist: track.artist,
                duration: track.duration
            ), !fetched.lines.isEmpty else {
                return nil
            }
            try? cache.save(
                fetched,
                title: track.title,
                artist: track.artist,
                duration: track.duration
            )
            return ResolvedLyrics(lyrics: fetched, origin: .online)
        } catch {
            return nil
        }
    }

    /// LRC files are small but not always UTF-8; fall back to the BOM/detected
    /// encoding before giving up.
    public static func readText(at url: URL) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        var encoding: String.Encoding = .utf8
        return try? String(contentsOf: url, usedEncoding: &encoding)
    }
}
