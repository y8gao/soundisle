import XCTest
@testable import SoundIsleCore

final class FilenameParserTests: XCTestCase {
    func testTitleArtistWithoutSpaces() {
        let p = FilenameParser.parse(filename: "母亲-阎维文.mp3")
        XCTAssertEqual(p.title, "母亲")
        XCTAssertEqual(p.artist, "阎维文")
    }

    func testArtistTitleWithSpacedHyphen() {
        let p = FilenameParser.parse(filename: "牛奶咖啡 - 咖喱咖喱.mp3")
        XCTAssertEqual(p.artist, "牛奶咖啡")
        XCTAssertEqual(p.title, "咖喱咖喱")
    }

    func testTrackNumberPrefix() {
        let p = FilenameParser.parse(filename: "01 母亲.mp3")
        XCTAssertEqual(p.trackNumber, 1)
        XCTAssertEqual(p.title, "母亲")
    }

    func testMultipleDotsAndHyphen() {
        let p = FilenameParser.parse(filename: "强军战歌.Live.-阎维文.mp3")
        XCTAssertEqual(p.title, "强军战歌.Live.")
        XCTAssertEqual(p.artist, "阎维文")
    }

    func testNoSeparatorKeepsWholeName() {
        let p = FilenameParser.parse(filename: "新闻联播开场曲.mp3")
        XCTAssertEqual(p.title, "新闻联播开场曲")
        XCTAssertNil(p.artist)
    }
}
