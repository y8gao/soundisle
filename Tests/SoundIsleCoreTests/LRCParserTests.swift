import XCTest
@testable import SoundIsleCore

final class LRCParserTests: XCTestCase {
    func testMultipleTimestamps() {
        let l = LRCParser.parse("[00:12.50][01:20.00]一条大河波浪宽\n[00:15.00]风吹稻花香两岸")
        XCTAssertEqual(l.lines.map(\.time), [12.5, 15, 80])
        XCTAssertEqual(l.lines[0].text, "一条大河波浪宽")
        XCTAssertEqual(l.lines[1].text, "风吹稻花香两岸")
        XCTAssertTrue(l.isSynced)
    }

    func testOffsetApplied() {
        let l = LRCParser.parse("[offset:500]\n[00:10.00]歌词")
        XCTAssertEqual(l.lines[0].time, 10.5)
    }

    func testNegativeOffsetApplied() {
        let l = LRCParser.parse("[offset:-250]\n[00:10.00]歌词")
        XCTAssertEqual(l.lines[0].time, 9.75)
    }

    func testPlainTextMarkedUnsynced() {
        let l = LRCParser.parse("第一行\n第二行")
        XCTAssertFalse(l.isSynced)
        XCTAssertEqual(l.lines.count, 2)
        XCTAssertEqual(l.lines.map(\.time), [0, 0])
        XCTAssertEqual(l.lines.map(\.text), ["第一行", "第二行"])
    }

    func testMetadataAndBlankLinesAreIgnored() {
        let l = LRCParser.parse("[ti:母亲]\n[ar:阎维文]\n[offset:0]\n\n[00:01.00]第一句")
        XCTAssertTrue(l.isSynced)
        XCTAssertEqual(l.lines.count, 1)
        XCTAssertEqual(l.lines[0].text, "第一句")
    }

    func testMetadataOnlyFileHasNoLines() {
        let l = LRCParser.parse("[ti:母亲]\n[ar:阎维文]")
        XCTAssertFalse(l.isSynced)
        XCTAssertTrue(l.lines.isEmpty)
    }

    func testFractionDigitsAreDecimal() {
        let l = LRCParser.parse("[01:02.5]甲\n[00:03.05]乙\n[00:04.500]丙")
        XCTAssertEqual(l.lines.map(\.time), [3.05, 4.5, 62.5])
    }

    func testIndexAtUsesLastLineAtOrBeforeTime() {
        let l = LRCParser.parse("[00:10.00]甲\n[00:20.00]乙\n[00:30.00]丙")
        XCTAssertNil(l.index(at: 9.99))
        XCTAssertEqual(l.index(at: 10), 0)
        XCTAssertEqual(l.index(at: 19.9), 0)
        XCTAssertEqual(l.index(at: 25), 1)
        XCTAssertEqual(l.index(at: 100), 2)
    }

    func testUnsyncedLyricsHaveNoTimedIndex() {
        let l = LRCParser.parse("第一行\n第二行")
        XCTAssertNil(l.index(at: 10))
    }

    func testWindowsLineEndings() {
        let l = LRCParser.parse("[00:01.00]甲\r\n[00:02.00]乙\r\n")
        XCTAssertEqual(l.lines.map(\.time), [1, 2])
    }

    func testPlainTextImportStripsTimestampsAndIsAlwaysUnsynced() {
        let l = LRCParser.parsePlainText("[00:01.00]第一句\n第二句\n[ti:歌名]")

        XCTAssertFalse(l.isSynced)
        XCTAssertEqual(l.lines.map(\.text), ["第一句", "第二句"])
        XCTAssertEqual(l.lines.map(\.time), [0, 0])
    }
}
