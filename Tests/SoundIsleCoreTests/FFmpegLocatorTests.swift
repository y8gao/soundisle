import XCTest
@testable import SoundIsleCore

final class FFmpegLocatorTests: XCTestCase {
    private var tempDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("SoundIsleFFmpegTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? fm.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testCustomPathWins() throws {
        let ffmpeg = try makeExecutable(named: "ffmpeg-custom")
        let found = try XCTUnwrap(FFmpegLocator.find(customPath: ffmpeg.path))
        XCTAssertEqual(found.standardizedFileURL, ffmpeg.standardizedFileURL)
    }

    func testNonExecutableCustomPathIsIgnored() throws {
        let notExecutable = tempDir.appendingPathComponent("ffmpeg-not-exec")
        try Data().write(to: notExecutable)
        let found = FFmpegLocator.find(customPath: notExecutable.path)
        XCTAssertNotEqual(found?.standardizedFileURL, notExecutable.standardizedFileURL)
    }

    func testAnyDetectedFFmpegIsExecutable() {
        if let found = FFmpegLocator.find() {
            XCTAssertTrue(fm.isExecutableFile(atPath: found.path), "detected path is not executable: \(found.path)")
        }
    }

    func testFFprobeReaderParsesDurationFromSiblingFFprobe() throws {
        let ffmpeg = try makeExecutable(named: "ffmpeg")
        let ffprobe = tempDir.appendingPathComponent("ffprobe")
        try "#!/bin/sh\necho 12.5\n".write(to: ffprobe, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffprobe.path)

        let sample = tempDir.appendingPathComponent("sample.ape")
        try Data().write(to: sample)
        XCTAssertEqual(FFprobeReader.duration(of: sample, ffmpeg: ffmpeg), 12.5)
    }

    func testFFprobeReaderReturnsNilWithoutSibling() throws {
        let ffmpeg = try makeExecutable(named: "ffmpeg-alone")
        let sample = tempDir.appendingPathComponent("sample.ape")
        try Data().write(to: sample)
        XCTAssertNil(FFprobeReader.duration(of: sample, ffmpeg: ffmpeg))
    }

    private func makeExecutable(named name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
