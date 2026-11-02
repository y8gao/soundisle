import XCTest
@testable import SoundIsleCore

final class PlayerEngineTests: XCTestCase {
    func testPlayWithoutLoadedFileReportsFailure() {
        let engine = PlayerEngine()

        engine.play()

        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.lastError, "没有加载音频文件")
    }

    func testLoadFailureReportsFailureAndDoesNotClaimPlayback() {
        let engine = PlayerEngine()
        let missing = URL(fileURLWithPath: "/tmp/SoundIsle-missing-\(UUID().uuidString).mp3")

        XCTAssertThrowsError(try engine.load(url: missing))
        XCTAssertFalse(engine.isPlaying)
        XCTAssertNotNil(engine.lastError)
    }

    func testSpectrumIsOffByDefault() {
        XCTAssertFalse(PlayerEngine().isSpectrumEnabled)
    }
}
