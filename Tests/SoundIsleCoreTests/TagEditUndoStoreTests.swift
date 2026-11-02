import XCTest
@testable import SoundIsleCore

final class TagEditUndoStoreTests: XCTestCase {
    private var tempDir: URL!
    private let service = TagService()

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoundIsleUndoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    /// Minimal MPEG-1 Layer III fixture (same shape as TagServiceTests) so
    /// TagService can actually write tags to it.
    private func makeMP3Fixture() throws -> URL {
        var data = Data()
        let frameHeader: [UInt8] = [0xFF, 0xFB, 0x90, 0x64]
        for _ in 0..<16 {
            data.append(contentsOf: frameHeader)
            data.append(Data(repeating: 0, count: 417 - frameHeader.count))
        }
        let url = tempDir.appendingPathComponent("fixture-\(UUID().uuidString).mp3")
        try data.write(to: url)
        return url
    }

    private func entry(
        _ url: URL,
        before: TagFields,
        after: TagFields,
        date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> TagUndoEntry {
        TagUndoEntry(url: url, before: before, after: after, date: date)
    }

    func testRecordAndUndoRestoresPreviousTags() throws {
        let url = try makeMP3Fixture()
        try service.write(TagFields(title: "旧标题", artist: "旧歌手"), to: url)
        let before = try XCTUnwrap(service.read(from: url))

        try service.write(TagFields(title: "新标题", artist: "旧歌手"), to: url)
        let after = try XCTUnwrap(service.read(from: url))

        let store = TagEditUndoStore(directory: tempDir.appendingPathComponent("undo"))
        try store.record(entry(url, before: before, after: after))
        XCTAssertEqual(store.entries.count, 1)

        let undone = try XCTUnwrap(try store.undoLast())
        XCTAssertEqual(undone.url.standardizedFileURL, url.standardizedFileURL)
        XCTAssertEqual(service.read(from: url)?.title, "旧标题")
        XCTAssertEqual(service.read(from: url)?.artist, "旧歌手")
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(try store.undoLast())
    }

    func testUndoClearsFieldsThatWereAdded() throws {
        let url = try makeMP3Fixture()
        let before = try XCTUnwrap(service.read(from: url))
        XCTAssertNil(before.title)
        XCTAssertNil(before.year)

        try service.write(TagFields(title: "新标题", year: 2004), to: url)
        let after = try XCTUnwrap(service.read(from: url))
        XCTAssertEqual(after.title, "新标题")
        XCTAssertEqual(after.year, 2004)

        let store = TagEditUndoStore(directory: tempDir.appendingPathComponent("undo"))
        try store.record(entry(url, before: before, after: after))
        _ = try store.undoLast()

        XCTAssertNil(service.read(from: url)?.title)
        XCTAssertNil(service.read(from: url)?.year)
    }

    func testUndoClearsArtworkThatWasAdded() throws {
        let url = try makeMP3Fixture()
        let onePixelPNG =
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let before = try XCTUnwrap(service.read(from: url))
        XCTAssertNil(before.artworkBase64)

        try service.write(TagFields(artworkBase64: onePixelPNG), to: url)
        let after = try XCTUnwrap(service.read(from: url))
        XCTAssertEqual(after.artworkBase64, onePixelPNG)

        let store = TagEditUndoStore(directory: tempDir.appendingPathComponent("undo"))
        try store.record(entry(url, before: before, after: after))
        _ = try store.undoLast()

        XCTAssertNil(service.read(from: url)?.artworkBase64)
    }

    func testLimitKeepsNewestEntries() throws {
        let store = TagEditUndoStore(directory: tempDir.appendingPathComponent("undo"), limit: 50)
        for index in 0..<60 {
            let url = tempDir.appendingPathComponent("track-\(index).mp3")
            try store.record(entry(url, before: TagFields(title: "before-\(index)"), after: TagFields(title: "after-\(index)")))
        }

        XCTAssertEqual(store.entries.count, 50)
        XCTAssertEqual(store.entries.first?.url.lastPathComponent, "track-10.mp3")
        XCTAssertEqual(store.entries.last?.url.lastPathComponent, "track-59.mp3")
    }

    func testEntriesSurviveReinitialization() throws {
        let directory = tempDir.appendingPathComponent("undo")
        let url = tempDir.appendingPathComponent("a.mp3")

        let store = TagEditUndoStore(directory: directory)
        try store.record(entry(url, before: TagFields(title: "一"), after: TagFields(title: "二")))
        try store.record(entry(url, before: TagFields(title: "二"), after: TagFields(title: "三")))

        let reloaded = TagEditUndoStore(directory: directory)
        XCTAssertEqual(reloaded.entries.count, 2)
        XCTAssertEqual(reloaded.entries.map(\.before.title), ["一", "二"])
        XCTAssertEqual(reloaded.entries.map(\.after.title), ["二", "三"])
    }

    func testClearEmptiesPersistedEntries() throws {
        let directory = tempDir.appendingPathComponent("undo")
        let url = tempDir.appendingPathComponent("a.mp3")

        let store = TagEditUndoStore(directory: directory)
        try store.record(entry(url, before: TagFields(title: "一"), after: TagFields(title: "二")))
        try store.clear()

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(TagEditUndoStore(directory: directory).entries.isEmpty)
    }
}
