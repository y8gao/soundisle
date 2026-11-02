import AVFoundation
import XCTest
@testable import SoundIsleCore

final class LibraryScannerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoundIsleScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    private func makeSilentWAV(named name: String, seconds: Double = 1) throws -> URL {
        try makeSilentWAV(at: tempDir.appendingPathComponent(name), seconds: seconds)
    }

    private func makeSilentWAV(at url: URL, seconds: Double = 1) throws -> URL {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try file.write(from: buffer)
        return url
    }

    private func metadataItem(_ identifier: AVMetadataIdentifier, value: Any) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as? NSCopying & NSObjectProtocol
        return item
    }

    private func exportTaggedM4A(from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let session = try XCTUnwrap(
            AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)
        )
        session.outputURL = destination
        session.outputFileType = .m4a
        session.metadata = [
            metadataItem(.iTunesMetadataAlbumArtist, value: "专辑歌手" as NSString),
            metadataItem(.iTunesMetadataTrackNumber, value: NSNumber(value: 7)),
            metadataItem(.iTunesMetadataReleaseDate, value: "2020-05-01T00:00:00Z" as NSString),
            metadataItem(.iTunesMetadataUserGenre, value: "流行" as NSString),
        ]

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                if let error = session.error {
                    continuation.resume(throwing: error)
                } else if session.status != .completed {
                    let error = NSError(
                        domain: "LibraryScannerTests",
                        code: Int(session.status.rawValue),
                        userInfo: [NSLocalizedDescriptionKey: "export status \(session.status.rawValue)"]
                    )
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func testReadsStandardTagsFromM4A() async throws {
        let source = try makeSilentWAV(named: "标签源.wav")
        let m4a = tempDir.appendingPathComponent("标签测试.m4a")
        try await exportTaggedM4A(from: source, to: m4a)

        let read = await AVFoundationMetadataReader().read(url: m4a)
        let metadata = try XCTUnwrap(read)

        XCTAssertEqual(metadata.albumArtist, "专辑歌手")
        XCTAssertEqual(metadata.trackNumber, 7)
        XCTAssertEqual(metadata.year, 2020)
        XCTAssertEqual(metadata.genre, "流行")
    }

    func testWhitespaceOnlyStemYieldsNoWhitespaceTitle() {
        let url = tempDir.appendingPathComponent("   .mp3")

        let track = TrackFactory.make(url: url, metadata: nil)

        XCTAssertEqual(track.title, "")
    }

    func testScanFindsPlayableFileAndReportsCorruptOne() async throws {
        _ = try makeSilentWAV(named: "测试曲目.wav")

        let corrupt = tempDir.appendingPathComponent("坏文件.mp3")
        try Data("this is not audio".utf8).write(to: corrupt)

        let result = await LibraryScanner.scan(folders: [tempDir])

        XCTAssertEqual(result.tracks.count, 1)
        XCTAssertEqual(result.tracks.first?.title, "测试曲目")
        let duration = try XCTUnwrap(result.tracks.first?.duration)
        XCTAssertTrue((0.9...1.1).contains(duration), "duration was \(duration)")
        XCTAssertEqual(
            result.unreadable.map { $0.resolvingSymlinksInPath() },
            [corrupt.resolvingSymlinksInPath()]
        )
    }

    func testNonNativeFormatIsIndexedWithoutMetadata() async throws {
        let ape = tempDir.appendingPathComponent("无损采样.ape")
        try Data("not really an ape file".utf8).write(to: ape)

        let result = await LibraryScanner.scan(folders: [tempDir])

        XCTAssertEqual(result.tracks.count, 1)
        XCTAssertEqual(result.tracks.first?.title, "无损采样")
        XCTAssertEqual(result.tracks.first?.duration, 0)
        XCTAssertTrue(result.unreadable.isEmpty)
    }

    func testOverlappingScanRootsReturnEachFileOnce() async throws {
        _ = try makeSilentWAV(named: "外层.wav")
        let sub = tempDir.appendingPathComponent("子目录", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        _ = try makeSilentWAV(at: sub.appendingPathComponent("内层.wav"))

        let result = await LibraryScanner.scan(folders: [tempDir, sub])

        XCTAssertEqual(result.tracks.count, 2)
        XCTAssertEqual(Set(result.tracks.map(\.title)), ["外层", "内层"])
    }

    func testMergePrefersMetadata() {
        let url = tempDir.appendingPathComponent("文件名 - 原歌手.mp3")
        let metadata = AudioMetadata(
            title: "真实标题",
            artist: "真实歌手",
            album: "真实专辑",
            albumArtist: "专辑歌手",
            year: 2020,
            trackNumber: 3,
            genre: "流行",
            duration: 12.5
        )

        let track = TrackFactory.make(url: url, metadata: metadata)

        XCTAssertEqual(track.title, "真实标题")
        XCTAssertEqual(track.artist, "真实歌手")
        XCTAssertEqual(track.album, "真实专辑")
        XCTAssertEqual(track.albumArtist, "专辑歌手")
        XCTAssertEqual(track.year, 2020)
        XCTAssertEqual(track.trackNumber, 3)
        XCTAssertEqual(track.genre, "流行")
        XCTAssertEqual(track.duration, 12.5)
        XCTAssertFalse(track.isMissing)
    }

    func testFilenameInferenceUsedWhenMetadataMissing() {
        let url = tempDir.appendingPathComponent("07 阎维文 - 母亲.mp3")

        let track = TrackFactory.make(url: url, metadata: nil)

        XCTAssertEqual(track.title, "母亲")
        XCTAssertEqual(track.artist, "阎维文")
        XCTAssertEqual(track.trackNumber, 7)
    }
}
