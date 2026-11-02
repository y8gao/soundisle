import XCTest
@testable import SoundIsleCore

final class TagServiceTests: XCTestCase {
    private var tempDir: URL!

    private let onePixelPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    private let onePixelGIFBase64 = "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="

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

    /// Builds a minimal MPEG-1 Layer III file (sixteen 128 kbps frames) with an
    /// optional ID3v1 tag, so ID3v1-only behaviour can be tested without an
    /// external audio fixture.
    private func makeMP3Fixture(
        withID3v1: Bool,
        artist: String = "Old Artist",
        album: String = "Old Album",
        year: String = "2004",
        genre: UInt8 = 17
    ) throws -> URL {
        var data = Data()
        let frameHeader: [UInt8] = [0xFF, 0xFB, 0x90, 0x64]
        for _ in 0..<16 {
            data.append(contentsOf: frameHeader)
            data.append(Data(repeating: 0, count: 417 - frameHeader.count))
        }

        if withID3v1 {
            var tag = Data("TAG".utf8)
            tag.append(fixedField("Old Title", length: 30))
            tag.append(fixedField(artist, length: 30))
            tag.append(fixedField(album, length: 30))
            tag.append(fixedField(year, length: 4))
            tag.append(fixedField("", length: 30))
            tag.append(genre)
            data.append(tag)
        }

        let url = tempDir.appendingPathComponent("fixture-\(UUID().uuidString).mp3")
        try data.write(to: url)
        return url
    }

    private func fixedField(_ string: String, length: Int) -> Data {
        var bytes = Array(string.utf8.prefix(length))
        bytes.append(contentsOf: [UInt8](repeating: 0, count: length - bytes.count))
        return Data(bytes)
    }

    /// Minimal RIFF/WAVE shell with only chunk headers, enough to exercise the
    /// ID3-chunk capability probe.
    private func makeWAV(withID3: Bool) throws -> URL {
        var data = Data("RIFF".utf8)
        data.append(contentsOf: [0, 0, 0, 0])
        data.append(Data("WAVE".utf8))

        func appendChunk(_ id: String, _ payload: Data) {
            data.append(Data(id.utf8))
            let size = UInt32(payload.count)
            data.append(contentsOf: [
                UInt8(size & 0xFF),
                UInt8((size >> 8) & 0xFF),
                UInt8((size >> 16) & 0xFF),
                UInt8((size >> 24) & 0xFF),
            ])
            data.append(payload)
            if payload.count % 2 == 1 { data.append(0) }
        }

        if withID3 { appendChunk("id3 ", Data("ID3".utf8)) }
        appendChunk("fmt ", Data(repeating: 0, count: 16))
        appendChunk("data", Data())

        let url = tempDir.appendingPathComponent("fixture-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    /// Counts native FLAC PICTURE metadata blocks (type 6).
    private func flacPictureBlockCount(_ url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        guard data.count > 4, data.prefix(4) == Data("fLaC".utf8) else { return -1 }
        var offset = 4
        var count = 0
        while offset + 4 <= data.count {
            let header = data[data.startIndex + offset]
            let type = header & 0x7F
            let length = (Int(data[data.startIndex + offset + 1]) << 16)
                | (Int(data[data.startIndex + offset + 2]) << 8)
                | Int(data[data.startIndex + offset + 3])
            if type == 6 {
                count += 1
            }
            offset += 4 + length
            if header & 0x80 != 0 {
                break
            }
        }
        return count
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

    func testWAVWithoutID3ChunkIsReportedReadOnly() throws {
        let url = try makeWAV(withID3: false)
        let capabilities = TagFormatCapabilities.capabilities(for: url)
        XCTAssertFalse(capabilities.canWrite)
        XCTAssertFalse(capabilities.canWriteArtwork)
        XCTAssertNotNil(capabilities.limitation)
    }

    func testWAVWithID3ChunkIsWritable() throws {
        let url = try makeWAV(withID3: true)
        let capabilities = TagFormatCapabilities.capabilities(for: url)
        XCTAssertTrue(capabilities.canWrite)
        XCTAssertTrue(capabilities.canWriteArtwork)
    }

    func testASFAndUnknownFormatsReportLimitations() {
        let asf = TagFormatCapabilities.capabilities(for: URL(fileURLWithPath: "/tmp/a.wma"))
        XCTAssertTrue(asf.canWrite)
        XCTAssertFalse(asf.canWriteAlbumArtist)
        XCTAssertFalse(asf.canWriteArtwork)
        XCTAssertNotNil(asf.limitation)

        let unknown = TagFormatCapabilities.capabilities(for: URL(fileURLWithPath: "/tmp/a.xyz"))
        XCTAssertFalse(unknown.canWrite)
        XCTAssertNotNil(unknown.limitation)
    }

    func testWriteToNonAudioFileThrows() throws {
        let url = try temporaryFile(named: "not-audio.mp3")
        XCTAssertThrowsError(try TagService().write(TagFields(title: "x"), to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not audio")
    }

    func testPartialWriteToID3v1OnlyFilePreservesFields() throws {
        let url = try makeMP3Fixture(withID3v1: true)
        let service = TagService()

        let before = try XCTUnwrap(service.read(from: url))
        XCTAssertEqual(before.artist, "Old Artist")
        XCTAssertEqual(before.album, "Old Album")
        XCTAssertEqual(before.year, 2004)
        XCTAssertEqual(before.genre, "Rock")

        try service.write(TagFields(title: "新标题"), to: url)

        let after = try XCTUnwrap(service.read(from: url))
        XCTAssertEqual(after.title, "新标题")
        XCTAssertEqual(after.artist, "Old Artist")
        XCTAssertEqual(after.album, "Old Album")
        XCTAssertEqual(after.year, 2004)
        XCTAssertEqual(after.genre, "Rock")
    }

    func testArtworkRoundTripAndClear() throws {
        let url = try makeMP3Fixture(withID3v1: true)
        let service = TagService()

        try service.write(
            TagFields(title: "封面测试", artworkBase64: onePixelPNGBase64),
            to: url
        )
        var fields = try XCTUnwrap(service.read(from: url))
        XCTAssertEqual(fields.title, "封面测试")
        XCTAssertEqual(fields.artworkBase64, onePixelPNGBase64)

        fields.artworkBase64 = onePixelGIFBase64
        try service.write(fields, to: url)
        XCTAssertEqual(service.read(from: url)?.artworkBase64, onePixelGIFBase64)

        fields.artworkBase64 = ""
        try service.write(fields, to: url)
        let cleared = try XCTUnwrap(service.read(from: url))
        XCTAssertNil(cleared.artworkBase64)
        XCTAssertEqual(cleared.title, "封面测试")
    }

    func testInvalidArtworkBase64ThrowsAndLeavesFileUntouched() throws {
        let url = try makeMP3Fixture(withID3v1: true)
        let service = TagService()
        try service.write(TagFields(title: "原值"), to: url)
        let before = try Data(contentsOf: url)

        XCTAssertThrowsError(
            try service.write(TagFields(title: "新值", artworkBase64: "not base64!"), to: url)
        )
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(service.read(from: url)?.title, "原值")
    }

    func testFLACArtworkUsesNativePictureBlocks() throws {
        guard let source = ProcessInfo.processInfo.environment["SOUNDISLE_TEST_FLAC"] else {
            throw XCTSkip("set SOUNDISLE_TEST_FLAC to a flac to run")
        }
        let copy = tempDir.appendingPathComponent("copy-\(UUID().uuidString).flac")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: copy)
        let service = TagService()

        var fields = service.read(from: copy) ?? TagFields()
        fields.artworkBase64 = onePixelPNGBase64
        try service.write(fields, to: copy)

        XCTAssertEqual(service.read(from: copy)?.artworkBase64, onePixelPNGBase64)
        XCTAssertEqual(try flacPictureBlockCount(copy), 1)
        XCTAssertNil(try Data(contentsOf: copy).range(of: Data("METADATA_BLOCK_PICTURE".utf8)))

        fields = try XCTUnwrap(service.read(from: copy))
        fields.artworkBase64 = onePixelGIFBase64
        try service.write(fields, to: copy)
        XCTAssertEqual(service.read(from: copy)?.artworkBase64, onePixelGIFBase64)
        XCTAssertEqual(try flacPictureBlockCount(copy), 1)

        fields.artworkBase64 = ""
        try service.write(fields, to: copy)
        XCTAssertNil(service.read(from: copy)?.artworkBase64)
        XCTAssertEqual(try flacPictureBlockCount(copy), 0)
    }

    func testRoundTripOnRealCopy() throws {
        guard let source = ProcessInfo.processInfo.environment["SOUNDISLE_TEST_AUDIO"] else {
            throw XCTSkip("set SOUNDISLE_TEST_AUDIO to an mp3 to run")
        }
        let sourceURL = URL(fileURLWithPath: source)
        let sourceData = try Data(contentsOf: sourceURL)
        let sourceMTime = try FileManager.default
            .attributesOfItem(atPath: sourceURL.path)[.modificationDate] as? Date

        let copy = tempDir.appendingPathComponent("copy-\(UUID().uuidString).mp3")
        try FileManager.default.copyItem(at: sourceURL, to: copy)

        let service = TagService()
        var fields = service.read(from: copy) ?? TagFields()
        fields.title = "测试标题"
        try service.write(fields, to: copy)

        let back = try XCTUnwrap(service.read(from: copy))
        XCTAssertEqual(back.title, "测试标题")
        XCTAssertEqual(back.artist, fields.artist)
        XCTAssertEqual(back.album, fields.album)
        XCTAssertEqual(back.albumArtist, fields.albumArtist)
        XCTAssertEqual(back.year, fields.year)
        XCTAssertEqual(back.trackNumber, fields.trackNumber)
        XCTAssertEqual(back.genre, fields.genre)
        XCTAssertEqual(back.artworkBase64, fields.artworkBase64)

        // The original file must never be modified.
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
        let sourceMTimeAfter = try FileManager.default
            .attributesOfItem(atPath: sourceURL.path)[.modificationDate] as? Date
        XCTAssertEqual(sourceMTimeAfter, sourceMTime)
    }
}
