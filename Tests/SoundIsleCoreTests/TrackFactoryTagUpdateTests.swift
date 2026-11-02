import XCTest
@testable import SoundIsleCore

final class TrackFactoryTagUpdateTests: XCTestCase {
    /// A row exactly as the scanner builds it for an untagged file: title,
    /// artist and track number come from the filename.
    private func scanned(_ filename: String) -> Track {
        TrackFactory.make(url: URL(fileURLWithPath: "/tmp/\(filename)"), metadata: nil)
    }

    func testAlbumEditKeepsFilenameArtistAndTitle() {
        let original = scanned("某歌手 - 某歌曲.mp3")
        XCTAssertEqual(original.artist, "某歌手")
        XCTAssertEqual(original.title, "某歌曲")

        let updated = TrackFactory.applying(TagFields(album: "新专辑"), to: original)

        XCTAssertEqual(updated.artist, "某歌手")
        XCTAssertEqual(updated.title, "某歌曲")
        XCTAssertEqual(updated.album, "新专辑")
        XCTAssertEqual(updated.id, original.id)
    }

    func testUndoOfAddedTitleFallsBackToFilename() {
        var edited = scanned("Artist - Title.mp3")
        edited.title = "临时标题" // the row after a tag edit added a title

        let restored = TrackFactory.applying(TagFields(), to: edited)

        XCTAssertEqual(restored.title, "Title")
        XCTAssertEqual(restored.artist, "Artist")
    }

    func testAlbumEditKeepsFilenameTrackNumber() {
        let original = scanned("03 Artist - Title.mp3")
        XCTAssertEqual(original.trackNumber, 3)

        let updated = TrackFactory.applying(TagFields(album: "X"), to: original)

        XCTAssertEqual(updated.trackNumber, 3)
    }

    func testUndoOfClearedArtistRestoresFilenameArtist() {
        var edited = scanned("Artist - Title.mp3")
        edited.artist = "" // the row after a tag write cleared the artist

        let restored = TrackFactory.applying(TagFields(), to: edited)

        XCTAssertEqual(restored.artist, "Artist")
    }

    func testTagValuesWinOverFilenameFallbacks() {
        let original = scanned("Artist - Title.mp3")
        let updated = TrackFactory.applying(
            TagFields(
                title: "标签标题",
                artist: "标签歌手",
                year: 2004,
                trackNumber: 7,
                genre: "Rock"
            ),
            to: original
        )

        XCTAssertEqual(updated.title, "标签标题")
        XCTAssertEqual(updated.artist, "标签歌手")
        XCTAssertEqual(updated.trackNumber, 7)
        XCTAssertEqual(updated.year, 2004)
        XCTAssertEqual(updated.genre, "Rock")
    }
}
