import XCTest
@testable import SoundIsleCore

final class PlaybackQueueTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    func testDefaultModeIsRepeatAll() {
        XCTAssertEqual(PlaybackQueue(trackIDs: [a, b]).mode, .repeatAll)
    }

    func testSequentialStopsAtEnd() {
        var q = PlaybackQueue(trackIDs: [a, b], mode: .sequential)
        XCTAssertEqual(q.next(), b)
        XCTAssertNil(q.next())
    }

    func testRepeatAllWraps() {
        var q = PlaybackQueue(trackIDs: [a, b], mode: .repeatAll)
        XCTAssertEqual(q.next(), b)
        XCTAssertEqual(q.next(), a)
    }

    func testRepeatOneStays() {
        var q = PlaybackQueue(trackIDs: [a, b], mode: .repeatOne)
        XCTAssertEqual(q.next(), a)
    }

    func testShuffleCyclesThroughAllTracksOnce() {
        var q = PlaybackQueue(trackIDs: [a, b, c], mode: .shuffle)
        var seen = Set<UUID>()
        for _ in 0..<3 { if let id = q.next() { seen.insert(id) } }
        XCTAssertEqual(seen.count, 3)
    }

    func testPreviousFromFirstWrapsOnlyWhenRepeating() {
        var q = PlaybackQueue(trackIDs: [a, b], mode: .repeatAll)
        XCTAssertEqual(q.previous(), b)
    }
}
