import AVFoundation
import XCTest
@testable import SoundIsleCore

final class TranscodeCacheTests: XCTestCase {
    private var tempDir: URL!
    private var cacheRoot: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("SoundIsleTranscodeTests-\(UUID().uuidString)", isDirectory: true)
        cacheRoot = tempDir.appendingPathComponent("transcode", isDirectory: true)
        try fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? fm.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Cache key

    func testKeyStableAndSensitiveToMtime() {
        let url = URL(fileURLWithPath: "/tmp/a.ape")
        let k1 = TranscodeCache.key(url: url, fileSize: 10, modifiedAt: Date(timeIntervalSince1970: 1))
        let k2 = TranscodeCache.key(url: url, fileSize: 10, modifiedAt: Date(timeIntervalSince1970: 1))
        let k3 = TranscodeCache.key(url: url, fileSize: 10, modifiedAt: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(k1, k2)
        XCTAssertNotEqual(k1, k3)
        XCTAssertEqual(k1.count, 32)
    }

    func testKeySensitiveToPathSizeAndVersion() {
        let url = URL(fileURLWithPath: "/tmp/a.ape")
        let other = URL(fileURLWithPath: "/tmp/b.ape")
        let date = Date(timeIntervalSince1970: 10)
        let base = TranscodeCache.key(url: url, fileSize: 10, modifiedAt: date)
        XCTAssertNotEqual(base, TranscodeCache.key(url: other, fileSize: 10, modifiedAt: date))
        XCTAssertNotEqual(base, TranscodeCache.key(url: url, fileSize: 11, modifiedAt: date))
        XCTAssertNotEqual(base, TranscodeCache.key(url: url, fileSize: 10, modifiedAt: date, version: 2))
    }

    func testCacheURLUsesKeyAndM4A() {
        let track = makeTrack(name: "歌曲.ape")
        let url = TranscodeCache.cacheURL(for: track, root: cacheRoot)
        let key = TranscodeCache.key(
            url: track.url,
            fileSize: track.fileSize,
            modifiedAt: track.modifiedAt
        )
        XCTAssertEqual(url, cacheRoot.appendingPathComponent("\(key).m4a"))
    }

    // MARK: - Format support

    func testNativeFormatDetection() {
        XCTAssertTrue(AudioFormatSupport.isNative(URL(fileURLWithPath: "/a/b.mp3")))
        XCTAssertTrue(AudioFormatSupport.isNative(URL(fileURLWithPath: "/a/b.FLAC")))
        XCTAssertFalse(AudioFormatSupport.isNative(URL(fileURLWithPath: "/a/b.ape")))
        XCTAssertFalse(AudioFormatSupport.isNative(URL(fileURLWithPath: "/a/b.dsf")))
    }

    // MARK: - Queue

    func testMissingFFmpegIsReported() async {
        let track = makeTrack(name: "缺依赖.ape")
        let queue = TranscodeQueue(cacheRoot: cacheRoot, ffmpeg: nil)
        do {
            _ = try await queue.ensureCached(track)
            XCTFail("should throw")
        } catch TranscodeError.ffmpegMissing {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertNil(queue.cachedURL(for: track))
        XCTAssertFalse(queue.isProcessing)
    }

    func testCachedURLOnlyWhenFileExists() throws {
        let track = makeTrack(name: "缓存.ape")
        let queue = TranscodeQueue(cacheRoot: cacheRoot, ffmpeg: nil)
        XCTAssertNil(queue.cachedURL(for: track))
        let url = TranscodeCache.cacheURL(for: track, root: cacheRoot)
        try Data([0x00]).write(to: url)
        XCTAssertEqual(queue.cachedURL(for: track), url)
    }

    func testFakeFFmpegProducesCacheFileOnce() async throws {
        let log = tempDir.appendingPathComponent("runs.log")
        let ffmpeg = try makeFakeFFmpeg(named: "ffmpeg-success", log: log)
        let track = makeTrack(name: "转码.ape")
        let queue = TranscodeQueue(cacheRoot: cacheRoot, ffmpeg: ffmpeg)

        async let first = queue.ensureCached(track)
        async let second = queue.ensureCached(track)
        let urls = try await [first, second]

        XCTAssertEqual(urls[0], urls[1])
        XCTAssertEqual(urls[0], TranscodeCache.cacheURL(for: track, root: cacheRoot))
        XCTAssertTrue(fm.fileExists(atPath: urls[0].path))
        let runs = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n").count
        XCTAssertEqual(runs, 1, "the same track must not be transcoded twice")
        XCTAssertNil(try? fm.contentsOfDirectory(atPath: cacheRoot.path)
            .first { $0.hasSuffix(".tmp.m4a") })
    }

    func testFailedTranscodeDeletesTempAndReportsError() async throws {
        let ffmpeg = try makeFakeFFmpeg(named: "ffmpeg-failure", log: nil, exitCode: 1)
        let track = makeTrack(name: "失败.ape")
        let queue = TranscodeQueue(cacheRoot: cacheRoot, ffmpeg: ffmpeg)

        do {
            _ = try await queue.ensureCached(track)
            XCTFail("should throw")
        } catch TranscodeError.failed {
            // expected
        }
        let leftovers = try fm.contentsOfDirectory(atPath: cacheRoot.path)
        XCTAssertTrue(leftovers.isEmpty, "temp files must be removed: \(leftovers)")
        XCTAssertNil(queue.cachedURL(for: track))
    }

    func testPlayRequestJumpsBackgroundQueue() async throws {
        let log = tempDir.appendingPathComponent("order.log")
        let ffmpeg = try makeOrderingFFmpeg(log: log)
        let first = makeTrack(name: "01-slow.ape")
        let background = makeTrack(name: "02-background.ape")
        let playback = makeTrack(name: "03-playback.ape")
        let queue = TranscodeQueue(cacheRoot: cacheRoot, ffmpeg: ffmpeg)

        queue.enqueue(first, priority: false)
        try await waitUntil { self.logLines(log).contains("01-slow.ape") }

        queue.enqueue(background, priority: false)
        queue.enqueue(playback, priority: true)

        try await waitUntil {
            queue.cachedURL(for: first) != nil
                && queue.cachedURL(for: background) != nil
                && queue.cachedURL(for: playback) != nil
        }
        XCTAssertEqual(logLines(log), ["01-slow.ape", "03-playback.ape", "02-background.ape"])
    }


    /// The queue hands the player a real container on the promised cache path;
    /// AVFoundation opens it exactly like PlayerEngine.load does.
    func testQueueDeliversReadableAudioFile() async throws {
        let fixture = tempDir.appendingPathComponent("fixture.m4a")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
        ]
        do {
            let file = try AVAudioFile(forWriting: fixture, settings: settings)
            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410)
            )
            buffer.frameLength = 4_410
            try file.write(from: buffer)
        }

        let log = tempDir.appendingPathComponent("copy.log")
        let ffmpeg = try makeCopyingFFmpeg(fixture: fixture, log: log)
        let track = makeTrack(name: "可播放.ape")
        let queue = TranscodeQueue(cacheRoot: cacheRoot, ffmpeg: ffmpeg)

        let cached = try await queue.ensureCached(track)
        XCTAssertEqual(cached, TranscodeCache.cacheURL(for: track, root: cacheRoot))
        let audio = try AVAudioFile(forReading: cached)
        XCTAssertGreaterThan(audio.length, 0)
    }

    func testPromotingTheRunningJobDoesNotWedgeQueue() async throws {
        let log = tempDir.appendingPathComponent("promote.log")
        let ffmpeg = try makeOrderingFFmpeg(log: log)
        let running = makeTrack(name: "01-slow.ape")
        let next = makeTrack(name: "02-next.ape")
        let queue = TranscodeQueue(cacheRoot: cacheRoot, ffmpeg: ffmpeg)

        queue.enqueue(running, priority: false)
        try await waitUntil { self.logLines(log).contains("01-slow.ape") }

        // Clicking the track that is already being transcoded promotes the
        // running job; that must not leave a stale priority entry behind.
        async let promoted = queue.ensureCached(running)
        queue.enqueue(next, priority: false)
        _ = try await promoted

        try await waitUntil(timeout: 3) { queue.cachedURL(for: next) != nil }
        XCTAssertNotNil(queue.cachedURL(for: next), "queue stopped after promoting the active job")
        XCTAssertFalse(queue.isProcessing)
    }

    func testFFmpegReceivesExpectedArguments() async throws {
        let log = tempDir.appendingPathComponent("args.log")
        let ffmpeg = try makeArgumentLoggingFFmpeg(log: log)
        let track = makeTrack(name: "参数.ape")
        let queue = TranscodeQueue(cacheRoot: cacheRoot, ffmpeg: ffmpeg)

        let cached = try await queue.ensureCached(track)
        let temporary = cached.appendingPathExtension("tmp.m4a").path
        XCTAssertEqual(
            logLines(log),
            ["-y", "-i", track.url.path, "-vn", "-c:a", "alac", temporary]
        )
    }

    func testClearCacheRemovesCachedFilesAndRecreatesDirectory() throws {
        let queue = TranscodeQueue(cacheRoot: cacheRoot, ffmpeg: nil)
        try Data([1]).write(to: cacheRoot.appendingPathComponent("old.m4a"))

        try queue.clearCache()

        XCTAssertTrue(fm.fileExists(atPath: cacheRoot.path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: cacheRoot.path), [])
    }

    func testClearCacheRefusesWhileJobIsActive() async throws {
        let log = tempDir.appendingPathComponent("clear.log")
        let ffmpeg = try makeOrderingFFmpeg(log: log)
        let slow = makeTrack(name: "01-slow.ape")
        let queue = TranscodeQueue(cacheRoot: cacheRoot, ffmpeg: ffmpeg)

        queue.enqueue(slow, priority: false)
        try await waitUntil { self.logLines(log).contains("01-slow.ape") }

        XCTAssertThrowsError(try queue.clearCache())
        // The active job must still complete and its waiter must be resumed.
        let cached = try await queue.ensureCached(slow)
        XCTAssertTrue(fm.fileExists(atPath: cached.path))
        XCTAssertFalse(queue.isProcessing)
    }

    func testUpdateFFmpegEnablesAnIdleQueue() async throws {
        let ffmpeg = try makeFakeFFmpeg(named: "ffmpeg-late", log: nil)
        let queue = TranscodeQueue(cacheRoot: cacheRoot, ffmpeg: nil)
        queue.updateFFmpeg(ffmpeg)

        let cached = try await queue.ensureCached(makeTrack(name: "迟到.ape"))
        XCTAssertTrue(fm.fileExists(atPath: cached.path))
    }

    // MARK: - Helpers

    private func makeTrack(
        name: String,
        size: Int64 = 123,
        modified: Date = Date(timeIntervalSince1970: 1_000)
    ) -> Track {
        Track(
            url: tempDir.appendingPathComponent(name),
            title: name,
            fileSize: size,
            modifiedAt: modified
        )
    }

    /// Logs the source basename and slows down `slow` sources, so queue order
    /// is observable without relying on wall-clock timing of a real transcode.
    private func makeOrderingFFmpeg(log: URL) throws -> URL {
        let url = tempDir.appendingPathComponent("ffmpeg-order")
        let script = """
        #!/bin/sh
        src="$3"
        for out in "$@"; do :; done
        echo "$(basename "$src")" >> "\(log.path)"
        case "$src" in *slow*) sleep 0.4;; esac
        printf 'fake-m4a' > "$out"
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }


    private func makeCopyingFFmpeg(fixture: URL, log: URL) throws -> URL {
        let url = tempDir.appendingPathComponent("ffmpeg-copy")
        let script = """
        #!/bin/sh
        for out in "$@"; do :; done
        echo run >> "\(log.path)"
        cp "\(fixture.path)" "$out"
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeArgumentLoggingFFmpeg(log: URL) throws -> URL {
        let url = tempDir.appendingPathComponent("ffmpeg-args")
        let script = """
        #!/bin/sh
        for arg in "$@"; do echo "$arg" >> "\(log.path)"; done
        for out in "$@"; do :; done
        printf 'fake-m4a' > "$out"
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func logLines(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("condition not met within \(timeout)s")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// A standalone fake ffmpeg: writes a marker to the output path (the last
    /// argument) and records each invocation, so queue mechanics can be tested
    /// without a real ffmpeg install.
    private func makeFakeFFmpeg(
        named name: String,
        log: URL?,
        exitCode: Int = 0
    ) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        var script = "#!/bin/sh\n"
        if let log {
            script += "echo run >> \"\(log.path)\"\n"
        }
        script += "for arg in \"$@\"; do out=\"$arg\"; done\n"
        if exitCode == 0 {
            script += "printf 'fake-m4a' > \"$out\"\n"
        } else {
            script += "echo 'boom' >&2\n"
        }
        script += "exit \(exitCode)\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
