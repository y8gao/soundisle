import XCTest
@testable import SoundIsleCore

final class TrackQueryTests: XCTestCase {
    private let mother = Track(
        url: URL(fileURLWithPath: "/tmp/母亲.mp3"),
        title: "母亲",
        artist: "阎维文",
        album: "红歌专辑",
        duration: 245
    )
    private let motherland = Track(
        url: URL(fileURLWithPath: "/tmp/红歌-祖国.mp3"),
        title: "祖国",
        artist: "群星",
        album: "红歌专辑",
        duration: 180
    )
    private let english = Track(
        url: URL(fileURLWithPath: "/tmp/Mother.mp3"),
        title: "Mother",
        artist: "John",
        album: "English",
        duration: 300
    )

    func testSearchMatchesArtistAndFilename() {
        let result = TrackQuery.apply([mother, motherland], query: "阎维文", sort: .title, ascending: true)
        XCTAssertEqual(result.map(\.title), ["母亲"])
    }

    func testSearchMatchesFilenameAndAlbum() {
        XCTAssertEqual(
            TrackQuery.apply([mother, motherland, english], query: "红歌", sort: .title, ascending: true).map(\.title),
            ["母亲", "祖国"].sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
        )
        XCTAssertEqual(
            TrackQuery.apply([mother, motherland, english], query: "红歌-祖国", sort: .title, ascending: true).map(\.title),
            ["祖国"]
        )
    }

    func testSearchIsCaseInsensitive() {
        XCTAssertEqual(
            TrackQuery.apply([mother, english], query: "MOTHER", sort: .title, ascending: true).map(\.title),
            ["Mother"]
        )
    }

    func testSearchIgnoresSurroundingWhitespace() {
        XCTAssertEqual(
            TrackQuery.apply([mother, english], query: "  阎维文  ", sort: .title, ascending: true).map(\.title),
            ["母亲"]
        )
    }

    func testEmptyQueryKeepsEverything() {
        XCTAssertEqual(
            TrackQuery.apply([mother, english], query: "", sort: .title, ascending: true).count,
            2
        )
    }

    func testSortByDurationAscending() {
        let long = mother
        let short = motherland
        let result = TrackQuery.apply([long, short], query: "", sort: .duration, ascending: true)
        XCTAssertEqual(result.map(\.title), [short.title, long.title])
    }

    func testSortByTitleDescending() {
        let alpha = Track(url: URL(fileURLWithPath: "/tmp/a.mp3"), title: "Alpha")
        let bravo = Track(url: URL(fileURLWithPath: "/tmp/b.mp3"), title: "Bravo")
        let charlie = Track(url: URL(fileURLWithPath: "/tmp/c.mp3"), title: "Charlie")
        let result = TrackQuery.apply([bravo, alpha, charlie], query: "", sort: .title, ascending: false)
        XCTAssertEqual(result.map(\.title), ["Charlie", "Bravo", "Alpha"])
    }

    func testSortByDateAddedDescending() {
        var old = mother
        old.modifiedAt = Date(timeIntervalSince1970: 1_000)
        var recent = motherland
        recent.modifiedAt = Date(timeIntervalSince1970: 2_000)
        let result = TrackQuery.apply([old, recent], query: "", sort: .dateAdded, ascending: false)
        XCTAssertEqual(result.map(\.title), ["祖国", "母亲"])
    }
}
