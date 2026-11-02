import XCTest
@testable import SoundIsleCore

final class PlaylistStoreTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    private func playlist(_ name: String = "工作时听的", _ ids: [UUID] = []) -> Playlist {
        Playlist(name: name, trackIDs: ids)
    }

    func testCreateAppendsAndPersists() throws {
        var saved: [[Playlist]] = []
        let store = PlaylistStore(persist: { saved.append($0) })

        let created = store.create(name: "工作时听的")

        XCTAssertEqual(store.playlists.map(\.name), ["工作时听的"])
        XCTAssertEqual(store.playlists.first?.id, created.id)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.last?.map(\.name), ["工作时听的"])
    }

    func testCreateUsesFallbackNameWhenBlank() {
        let store = PlaylistStore()
        XCTAssertEqual(store.create(name: "   ").name, "新建播放列表")
    }

    func testRename() throws {
        let p = playlist()
        var saved: [[Playlist]] = []
        let store = PlaylistStore(playlists: [p], persist: { saved.append($0) })

        store.rename(id: p.id, to: "通勤")

        XCTAssertEqual(store.playlists.first?.name, "通勤")
        XCTAssertEqual(saved.last?.first?.name, "通勤")
    }

    func testDelete() throws {
        let p = playlist()
        let other = playlist("另一个", [a])
        var saved: [[Playlist]] = []
        let store = PlaylistStore(playlists: [p, other], persist: { saved.append($0) })

        store.delete(id: p.id)

        XCTAssertEqual(store.playlists.map(\.name), ["另一个"])
        XCTAssertEqual(saved.last?.map(\.name), ["另一个"])
    }

    func testAddTracksAppendsWithoutDuplicates() throws {
        let p = playlist()
        var saved: [[Playlist]] = []
        let store = PlaylistStore(playlists: [p], persist: { saved.append($0) })

        store.add(trackIDs: [a, b], to: p.id)
        store.add(trackIDs: [b, c], to: p.id)

        XCTAssertEqual(store.playlists[0].trackIDs, [a, b, c])
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved.last?.first?.trackIDs, [a, b, c])
    }

    func testRemoveTrack() throws {
        let p = playlist("列表", [a, b, c])
        var saved: [[Playlist]] = []
        let store = PlaylistStore(playlists: [p], persist: { saved.append($0) })

        store.remove(trackID: b, from: p.id)

        XCTAssertEqual(store.playlists[0].trackIDs, [a, c])
        XCTAssertEqual(saved.last?.first?.trackIDs, [a, c])
    }

    func testPlaylistReorder() throws {
        let p = playlist("列表", [a, b])
        let store = PlaylistStore(playlists: [p])

        store.move(from: 0, to: 1, in: p.id)

        XCTAssertEqual(store.playlists[0].trackIDs, [b, a])
    }

    func testMoveToEndAndPastEnd() throws {
        let p = playlist("列表", [a, b, c])
        let store = PlaylistStore(playlists: [p])

        store.move(from: 0, to: 99, in: p.id)
        XCTAssertEqual(store.playlists[0].trackIDs, [b, c, a])

        store.move(from: 99, to: 0, in: p.id)
        XCTAssertEqual(store.playlists[0].trackIDs, [b, c, a])
    }

    func testMovePersists() throws {
        let p = playlist("列表", [a, b])
        var saved: [[Playlist]] = []
        let store = PlaylistStore(playlists: [p], persist: { saved.append($0) })

        store.move(from: 1, to: 0, in: p.id)

        XCTAssertEqual(saved.last?.first?.trackIDs, [b, a])
    }
}
