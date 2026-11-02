import XCTest
@testable import SoundIsleCore

final class LyricsSidecarTests: XCTestCase {
    private var tempDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("SoundIsleLyricsSidecarTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    @discardableResult
    private func makeFile(_ name: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? tempDir).appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    func testFindsCaseInsensitiveSidecar() throws {
        let audio = try makeFile("母亲-阎维文.mp3")
        let lrc = try makeFile("母亲-阎维文.LRC")

        let track = Track(url: audio, title: "母亲", artist: "阎维文")

        XCTAssertEqual(
            LyricsSidecar.find(for: track)?.standardizedFileURL,
            lrc.standardizedFileURL
        )
    }

    func testMatchesFullWidthParentheses() throws {
        let audio = try makeFile("母亲（现场版）.mp3")
        let lrc = try makeFile("母亲(现场版).lrc")

        let track = Track(url: audio, title: "母亲")

        XCTAssertEqual(
            LyricsSidecar.find(for: track)?.standardizedFileURL,
            lrc.standardizedFileURL
        )
    }

    func testMatchesWhenOnlyOneSideCarriesABracketSuffix() throws {
        let audio = try makeFile("母亲 (Live).mp3")
        let lrc = try makeFile("母亲.lrc")

        let track = Track(url: audio, title: "母亲")

        XCTAssertEqual(
            LyricsSidecar.find(for: track)?.standardizedFileURL,
            lrc.standardizedFileURL
        )
    }

    func testPrefersExactStemOverBracketVariant() throws {
        let audio = try makeFile("母亲 (Live).mp3")
        let exact = try makeFile("母亲 (Live).lrc")
        try makeFile("母亲.lrc")

        let track = Track(url: audio, title: "母亲")

        XCTAssertEqual(
            LyricsSidecar.find(for: track)?.standardizedFileURL,
            exact.standardizedFileURL
        )
    }

    func testMissingSidecarReturnsNil() throws {
        let audio = try makeFile("没有歌词.mp3")
        let track = Track(url: audio, title: "没有歌词")

        XCTAssertNil(LyricsSidecar.find(for: track))
    }

    func testUnrelatedSidecarIsIgnored() throws {
        let audio = try makeFile("甲.mp3")
        try makeFile("乙.lrc")

        let track = Track(url: audio, title: "甲")

        XCTAssertNil(LyricsSidecar.find(for: track))
    }
}
