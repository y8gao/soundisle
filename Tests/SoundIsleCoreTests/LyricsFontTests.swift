import XCTest
@testable import SoundIsleCore

final class LyricsFontTests: XCTestCase {
    func testMapsEndpoints() {
        XCTAssertEqual(LyricsFont.size(forWidth: 320), 18)
        XCTAssertEqual(LyricsFont.size(forWidth: 900), 36)
    }

    func testClampsOutsideTheRange() {
        XCTAssertEqual(LyricsFont.size(forWidth: 200), 18)
        XCTAssertEqual(LyricsFont.size(forWidth: 1200), 36)
    }

    func testInterpolatesLinearly() {
        XCTAssertEqual(LyricsFont.size(forWidth: 610), 27, accuracy: 0.0001)
    }

    func testNonFiniteWidthFallsBackToMinimum() {
        XCTAssertEqual(LyricsFont.size(forWidth: .nan), 18)
        XCTAssertEqual(LyricsFont.size(forWidth: .infinity), 36)
    }
}
