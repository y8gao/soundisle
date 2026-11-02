import Foundation

public enum TrackSort: String, CaseIterable {
    case title
    case artist
    case album
    case duration
    case dateAdded
}

/// Search and column sorting for the track list. Pure and synchronous so the
/// view layer can call it on every keystroke for libraries of a few thousand
/// tracks without any caching machinery.
public enum TrackQuery {
    public static func apply(
        _ tracks: [Track],
        query: String,
        sort: TrackSort,
        ascending: Bool
    ) -> [Track] {
        filter(tracks, query: query).sorted { lhs, rhs in
            let order = compare(lhs, rhs, by: sort)
            if order == .orderedSame {
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    /// Query-only filtering, used where the stored order must be preserved
    /// (a manually ordered playlist).
    public static func filter(_ tracks: [Track], query: String) -> [Track] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty ? tracks : tracks.filter { matches($0, needle) }
    }

    private static func matches(_ track: Track, _ needle: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        for field in [track.title, track.artist, track.album, track.url.lastPathComponent] {
            if field.range(of: needle, options: options) != nil { return true }
        }
        return false
    }

    private static func compare(_ lhs: Track, _ rhs: Track, by sort: TrackSort) -> ComparisonResult {
        switch sort {
        case .title:
            return lhs.title.localizedStandardCompare(rhs.title)
        case .artist:
            let order = lhs.artist.localizedStandardCompare(rhs.artist)
            return order == .orderedSame ? lhs.title.localizedStandardCompare(rhs.title) : order
        case .album:
            let order = lhs.album.localizedStandardCompare(rhs.album)
            if order != .orderedSame { return order }
            let trackNumber = (lhs.trackNumber ?? 0) - (rhs.trackNumber ?? 0)
            if trackNumber != 0 { return trackNumber < 0 ? .orderedAscending : .orderedDescending }
            return lhs.title.localizedStandardCompare(rhs.title)
        case .duration:
            if lhs.duration == rhs.duration { return .orderedSame }
            return lhs.duration < rhs.duration ? .orderedAscending : .orderedDescending
        case .dateAdded:
            if lhs.modifiedAt == rhs.modifiedAt { return .orderedSame }
            return lhs.modifiedAt < rhs.modifiedAt ? .orderedAscending : .orderedDescending
        }
    }
}
