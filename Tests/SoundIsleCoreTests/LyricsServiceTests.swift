import Foundation
import XCTest
@testable import SoundIsleCore

private final class FakeLyricsClient: LyricsFetching {
    var calls = 0
    var lastQuery: (title: String, artist: String, duration: TimeInterval)?
    var result: Lyrics?
    var error: Error?

    func fetch(title: String, artist: String, duration: TimeInterval) async throws -> Lyrics? {
        calls += 1
        lastQuery = (title, artist, duration)
        if let error { throw error }
        return result
    }
}

final class LyricsServiceTests: XCTestCase {
    private var tempDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("SoundIsleLyricsServiceTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    private func makeCache() -> LyricsCache {
        LyricsCache(directory: tempDir.appendingPathComponent("lyrics", isDirectory: true))
    }

    @discardableResult
    private func makeTrack(
        _ name: String = "track",
        title: String = "母亲",
        artist: String = "阎维文",
        duration: TimeInterval = 215.4
    ) throws -> Track {
        let url = tempDir.appendingPathComponent("\(name).mp3")
        try Data("x".utf8).write(to: url)
        return Track(url: url, title: title, artist: artist, duration: duration)
    }

    private var onlineLyrics: Lyrics {
        Lyrics(lines: [LyricLine(time: 1, text: "在线第一句")], isSynced: true)
    }

    private var overrideLyrics: Lyrics {
        Lyrics(lines: [LyricLine(time: 2, text: "覆盖歌词")], isSynced: true)
    }

    func testOverrideWinsOverSidecarAndNetwork() async throws {
        let track = try makeTrack()
        try Data("[00:03.00]侧载歌词\n".utf8)
            .write(to: tempDir.appendingPathComponent("track.lrc"))

        let cache = makeCache()
        try cache.saveOverride(overrideLyrics, for: track.id)
        let client = FakeLyricsClient()
        client.result = onlineLyrics
        let service = LyricsService(cache: cache, client: client)

        let resolved = await service.resolve(for: track)

        XCTAssertEqual(resolved?.origin, .override)
        XCTAssertEqual(resolved?.lyrics, overrideLyrics)
        XCTAssertEqual(client.calls, 0)
    }

    func testSidecarWinsOverNetworkAndSkipsIt() async throws {
        let track = try makeTrack()
        let sidecar = tempDir.appendingPathComponent("track.lrc")
        try Data("[00:03.00]侧载第一句\n[00:04.00]侧载第二句\n".utf8).write(to: sidecar)

        let client = FakeLyricsClient()
        client.result = onlineLyrics
        let service = LyricsService(cache: makeCache(), client: client)

        let resolved = await service.resolve(for: track)

        XCTAssertEqual(resolved?.origin, .sidecar)
        XCTAssertEqual(resolved?.sourceURL?.standardizedFileURL, sidecar.standardizedFileURL)
        XCTAssertEqual(resolved?.lyrics.isSynced, true)
        XCTAssertEqual(resolved?.lyrics.lines.map(\.text), ["侧载第一句", "侧载第二句"])
        XCTAssertEqual(client.calls, 0)
    }

    func testOnlineHitIsCachedAndReusedWithoutNetwork() async throws {
        let track = try makeTrack()
        let cache = makeCache()

        let firstClient = FakeLyricsClient()
        firstClient.result = onlineLyrics
        let first = LyricsService(cache: cache, client: firstClient)
        let firstResolved = await first.resolve(for: track)

        XCTAssertEqual(firstResolved?.origin, .online)
        XCTAssertEqual(firstResolved?.lyrics, onlineLyrics)
        XCTAssertEqual(firstClient.calls, 1)

        // A fresh service with an offline client proves the cache persists to
        // disk: the second play must not touch the network.
        let offlineClient = FakeLyricsClient()
        offlineClient.error = URLError(.notConnectedToInternet)
        let second = LyricsService(cache: cache, client: offlineClient)
        let secondResolved = await second.resolve(for: track)

        XCTAssertEqual(secondResolved?.origin, .online)
        XCTAssertEqual(secondResolved?.lyrics, onlineLyrics)
        XCTAssertEqual(offlineClient.calls, 0)
    }

    func testOnlineDisabledSkipsLiveLookup() async throws {
        let track = try makeTrack()
        let client = FakeLyricsClient()
        client.result = onlineLyrics
        let service = LyricsService(cache: makeCache(), client: client)
        service.isOnlineEnabled = false

        let resolved = await service.resolve(for: track)

        XCTAssertNil(resolved)
        XCTAssertEqual(client.calls, 0)
    }

    func testOnlineDisabledStillUsesOverride() async throws {
        let track = try makeTrack()
        let cache = makeCache()
        try cache.saveOverride(overrideLyrics, for: track.id)
        let service = LyricsService(cache: cache, client: FakeLyricsClient())
        service.isOnlineEnabled = false

        let resolved = await service.resolve(for: track)

        XCTAssertEqual(resolved?.origin, .override)
        XCTAssertEqual(resolved?.lyrics, overrideLyrics)
    }

    func testOnlineDisabledStillUsesCachedOnlineResult() async throws {
        let track = try makeTrack()
        let cache = makeCache()
        try cache.save(
            onlineLyrics,
            title: track.title,
            artist: track.artist,
            duration: track.duration
        )
        let client = FakeLyricsClient()
        client.result = Lyrics(lines: [LyricLine(time: 1, text: "不应查询")], isSynced: false)
        let service = LyricsService(cache: cache, client: client)
        service.isOnlineEnabled = false

        let resolved = await service.resolve(for: track)

        XCTAssertEqual(resolved?.origin, .online)
        XCTAssertEqual(resolved?.lyrics, onlineLyrics)
        XCTAssertEqual(client.calls, 0)
    }

    func testOnlineErrorIsSilent() async throws {
        let track = try makeTrack()
        let client = FakeLyricsClient()
        client.error = URLError(.notConnectedToInternet)
        let service = LyricsService(cache: makeCache(), client: client)

        let resolved = await service.resolve(for: track)

        XCTAssertNil(resolved)
        XCTAssertEqual(client.calls, 1)
    }
}

final class LyricsCacheTests: XCTestCase {
    private var tempDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("SoundIsleLyricsCacheTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? fm.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    func testOnlineCacheRoundtripsAndRoundsDuration() throws {
        let cache = LyricsCache(directory: tempDir.appendingPathComponent("lyrics", isDirectory: true))
        let lyrics = Lyrics(
            lines: [LyricLine(time: 1.5, text: "第一句"), LyricLine(time: 2.5, text: "第二句")],
            isSynced: true
        )

        try cache.save(lyrics, title: "母亲", artist: "阎维文", duration: 215.4)

        XCTAssertEqual(
            cache.load(title: "母亲", artist: "阎维文", duration: 215.2),
            lyrics
        )
        XCTAssertEqual(
            cache.load(title: "母亲", artist: "阎维文", duration: 214.6),
            lyrics
        )
        XCTAssertNil(cache.load(title: "母亲", artist: "阎维文", duration: 216))
        XCTAssertNil(cache.load(title: "父亲", artist: "阎维文", duration: 215))
    }

    func testOverrideRoundtripAndRemoval() throws {
        let cache = LyricsCache(directory: tempDir.appendingPathComponent("lyrics", isDirectory: true))
        let trackID = UUID()
        let lyrics = Lyrics(lines: [LyricLine(time: 0, text: "纯文本")], isSynced: false)

        XCTAssertNil(cache.loadOverride(for: trackID))
        try cache.saveOverride(lyrics, for: trackID)
        XCTAssertEqual(cache.loadOverride(for: trackID), lyrics)

        try cache.removeOverride(for: trackID)
        XCTAssertNil(cache.loadOverride(for: trackID))
    }

    func testCorruptCacheFileIsIgnored() throws {
        let directory = tempDir.appendingPathComponent("lyrics", isDirectory: true)
        let cache = LyricsCache(directory: directory)
        try cache.save(
            Lyrics(lines: [LyricLine(time: 0, text: "x")], isSynced: false),
            title: "t",
            artist: "a",
            duration: 1
        )
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let file = try XCTUnwrap(files.first)
        try Data("not json".utf8).write(to: file)

        XCTAssertNil(cache.load(title: "t", artist: "a", duration: 1))
    }
}
