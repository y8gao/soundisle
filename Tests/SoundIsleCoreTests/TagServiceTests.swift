import XCTest
@testable import SoundIsleCore

final class TagServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoundIsleTagTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    private func temporaryFile(named name: String, contents: String = "not audio") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testReadMissingFileReturnsNil() {
        let missing = URL(fileURLWithPath: "/tmp/soundisle-does-not-exist-\(UUID().uuidString).mp3")
        XCTAssertNil(TagService().read(from: missing))
    }

    func testJSONRoundTrip() throws {
        let fields = TagFields(
            title: "母亲",
            artist: "阎维文",
            album: "战士情歌",
            year: 2004,
            trackNumber: 1,
            genre: nil,
            artworkBase64: nil
        )
        let data = TagService.jsonData(from: fields)
        let decoded = try JSONDecoder().decode(TagFields.self, from: data)
        XCTAssertEqual(decoded, fields)
    }

    func testWriteToNonAudioFileThrows() throws {
        let url = try temporaryFile(named: "not-audio.mp3")
        XCTAssertThrowsError(try TagService().write(TagFields(title: "x"), to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not audio")
    }

    func testRoundTripOnRealCopy() throws {
        guard let source = ProcessInfo.processInfo.environment["SOUNDISLE_TEST_AUDIO"] else {
            throw XCTSkip("set SOUNDISLE_TEST_AUDIO to an mp3 to run")
        }
        let copy = tempDir.appendingPathComponent("copy-\(UUID().uuidString).mp3")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: copy)

        let service = TagService()
        var fields = service.read(from: copy) ?? TagFields()
        fields.title = "测试标题"
        try service.write(fields, to: copy)

        XCTAssertEqual(service.read(from: copy)?.title, "测试标题")
    }
}
