import Foundation

/// Owns the user's playlists and pushes every mutation to the injected
/// `persist` callback. `LibraryStore` supplies that callback, so playlists are
/// written through the one store that owns `playlists.json`.
public final class PlaylistStore {
    public private(set) var playlists: [Playlist]

    private let persist: (([Playlist]) throws -> Void)?

    public init(
        playlists: [Playlist] = [],
        persist: (([Playlist]) throws -> Void)? = nil
    ) {
        self.playlists = playlists
        self.persist = persist
    }

    @discardableResult
    public func create(name: String) -> Playlist {
        let playlist = Playlist(name: normalized(name) ?? "新建播放列表")
        playlists.append(playlist)
        save()
        return playlist
    }

    public func rename(id: UUID, to name: String) {
        guard let position = index(of: id), let name = normalized(name) else { return }
        playlists[position].name = name
        save()
    }

    public func delete(id: UUID) {
        guard let position = index(of: id) else { return }
        playlists.remove(at: position)
        save()
    }

    public func add(trackIDs: [UUID], to playlistID: UUID) {
        guard let position = index(of: playlistID) else { return }
        var known = Set(playlists[position].trackIDs)
        let additions = trackIDs.filter { known.insert($0).inserted }
        guard !additions.isEmpty else { return }
        playlists[position].trackIDs.append(contentsOf: additions)
        save()
    }

    public func remove(trackID: UUID, from playlistID: UUID) {
        guard let position = index(of: playlistID),
              let track = playlists[position].trackIDs.firstIndex(of: trackID) else { return }
        playlists[position].trackIDs.remove(at: track)
        save()
    }

    /// Moves a track so it ends up at `to` in the playlist's own order.
    public func move(from: Int, to: Int, in playlistID: UUID) {
        guard let position = index(of: playlistID),
              playlists[position].trackIDs.indices.contains(from) else { return }
        let trackID = playlists[position].trackIDs.remove(at: from)
        let target = min(max(to, 0), playlists[position].trackIDs.count)
        playlists[position].trackIDs.insert(trackID, at: target)
        save()
    }

    /// Mirrors a change made inside `LibraryStore` (folder removal prunes
    /// playlist entries). The library already owns that write, so no persist.
    public func reload(_ playlists: [Playlist]) {
        guard self.playlists != playlists else { return }
        self.playlists = playlists
    }

    private func index(of id: UUID) -> Int? {
        playlists.firstIndex { $0.id == id }
    }

    private func normalized(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func save() {
        try? persist?(playlists)
    }
}
