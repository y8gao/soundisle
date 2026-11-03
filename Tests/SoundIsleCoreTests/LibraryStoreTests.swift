import XCTest
@testable import SoundIsleCore

final class LibraryStoreTests: XCTestCase {
    private var tempDir: URL!
    private var dataDir: URL!
    private var libraryRoot: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = fm.temporaryDirectory
            .appendingPathComponent("SoundIsleStoreTests-\(UUID().uuidString)", isDirectory: true)
        dataDir = tempDir.appendingPathComponent("data", isDirectory: true)
        libraryRoot = tempDir.appendingPathComponent("library", isDirectory: true)
        try fm.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? fm.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    @discardableResult
    private func makeFile(_ name: String, in folder: URL? = nil, bytes: Int = 32) throws -> URL {
        let url = (folder ?? libraryRoot).appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private func appendBytes(_ count: Int, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0x42, count: count))
    }

    private func makeSubfolder(_ name: String) throws -> URL {
        let url = libraryRoot.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sampleTrack(id: UUID = UUID()) -> Track {
        Track(
            id: id,
            url: URL(fileURLWithPath: "/tmp/母亲.mp3"),
            title: "母亲",
            artist: "阎维文",
            album: "专辑",
            albumArtist: "阎维文",
            year: 2020,
            trackNumber: 3,
            genre: "流行",
            duration: 245.5,
            fileSize: 8_888_888,
            modifiedAt: Date(timeIntervalSince1970: 1_600_000_000),
            artworkFileName: "cover.jpg",
            isMissing: false
        )
    }

    private var gb18030: String.Encoding {
        String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
    }

    private func misread(_ text: String, encoding: String.Encoding = .utf8) -> String {
        String(data: text.data(using: encoding)!, encoding: .isoLatin1)!
    }

    /// Reader stub so rescan tests never touch AVFoundation or real audio data.
    private final class StubReader: MetadataReading {
        private var metadata: [String: AudioMetadata] = [:]
        private var unreadableFiles: Set<String> = []

        // Mutated only between scans; the scanner reads concurrently.
        func setMetadata(_ metadata: [String: AudioMetadata]) {
            self.metadata = metadata
        }

        func markUnreadable(_ names: Set<String>) {
            unreadableFiles = names
        }

        func read(url: URL) async -> AudioMetadata? {
            if unreadableFiles.contains(url.lastPathComponent) { return nil }
            return metadata[url.lastPathComponent]
        }
    }

    @MainActor
    private func track(named title: String, in store: LibraryStore) throws -> Track {
        try XCTUnwrap(store.index.tracks.first { $0.title == title })
    }

    private func persistedIndex() -> LibraryIndex {
        IndexStore(directory: dataDir).loadIndex()
    }

    // MARK: - Persistence

    func testRoundTripPreservesTrackAndPlaylist() throws {
        let store = IndexStore(directory: dataDir)
        let track = sampleTrack()
        let playlist = Playlist(name: "收藏", trackIDs: [track.id])

        try store.saveIndex(LibraryIndex(tracks: [track], folders: [libraryRoot]))
        try store.savePlaylists([playlist])

        let reloaded = IndexStore(directory: dataDir)
        let index = reloaded.loadIndex()

        XCTAssertEqual(index.tracks, [track])
        XCTAssertEqual(index.folders.map(\.standardizedFileURL), [libraryRoot.standardizedFileURL])
        XCTAssertEqual(reloaded.loadPlaylists(), [playlist])
    }

    func testSettingsRoundTrip() throws {
        let store = IndexStore(directory: dataDir)
        var settings = AppSettings()
        settings.themePreset = "forest"
        settings.customAccentHex = "#FF8800"
        settings.lyricsOpacity = 0.5
        settings.hideFromScreenCapture = false
        settings.lastQueue = [UUID(), UUID()]
        settings.lastTrackID = settings.lastQueue.first
        settings.lastPosition = 42.5
        settings.ffmpegPath = "/usr/local/bin/ffmpeg"

        try store.saveSettings(settings)

        XCTAssertEqual(IndexStore(directory: dataDir).loadSettings(), settings)
    }

    @MainActor
    func testUpdateDurationsFillsOnlyUnknownDurationsAndPersists() throws {
        let store = LibraryStore(directory: dataDir)
        var known = sampleTrack()
        known.duration = 12
        var unknown = sampleTrack()
        unknown.duration = 0
        store.index.tracks = [known, unknown]

        store.updateDurations([known.id: 99, unknown.id: 42.5])

        XCTAssertEqual(store.index.tracks[0].duration, 12)
        XCTAssertEqual(store.index.tracks[1].duration, 42.5)
        let reloaded = IndexStore(directory: dataDir).loadIndex()
        XCTAssertEqual(reloaded.tracks.first(where: { $0.id == unknown.id })?.duration, 42.5)
    }

    @MainActor
    func testLibraryStoreSavesSettingsThroughItsOwnStore() async throws {
        let store = LibraryStore(directory: dataDir)
        store.settings.lastTrackID = UUID()
        store.settings.lastPosition = 12.5

        store.saveSettings()

        let reloaded = IndexStore(directory: dataDir).loadSettings()
        XCTAssertEqual(reloaded.lastTrackID, store.settings.lastTrackID)
        XCTAssertEqual(reloaded.lastPosition, 12.5)
    }

    func testDefaultsMatchPlan() {
        let settings = AppSettings()
        XCTAssertEqual(settings.themePreset, "deepBlue")
        XCTAssertEqual(settings.themeMode, "system")
        XCTAssertNil(settings.customAccentHex)
        XCTAssertEqual(settings.lyricsOpacity, 0.26)
        XCTAssertFalse(settings.lyricsOutline)
        XCTAssertEqual(settings.lyricsLineMode, "two")
        XCTAssertFalse(settings.lyricsLocked)
        XCTAssertEqual(settings.rowStyle, "index")
        XCTAssertFalse(settings.showMainSpectrum)
        XCTAssertTrue(settings.hideFromScreenCapture)
        XCTAssertTrue(settings.keepRunningOnClose)
        XCTAssertTrue(settings.miniAlwaysOnTop)
        XCTAssertTrue(settings.onlineLyricsEnabled)
        XCTAssertEqual(settings.playbackMode, "sequential")
        XCTAssertEqual(settings.lastQueue, [])
        XCTAssertNil(settings.lastTrackID)
        XCTAssertEqual(settings.lastPosition, 0)
        XCTAssertNil(settings.ffmpegPath)
    }

    func testCorruptIndexReturnsEmptyAndLeavesEverythingElseIntact() throws {
        let store = IndexStore(directory: dataDir)
        let track = sampleTrack()
        let playlist = Playlist(name: "收藏", trackIDs: [track.id])
        var settings = AppSettings()
        settings.themePreset = "forest"
        let undoDir = dataDir.appendingPathComponent("undo", isDirectory: true)
        let undoFile = undoDir.appendingPathComponent("record.json")

        try store.saveIndex(LibraryIndex(tracks: [track], folders: [libraryRoot]))
        try store.savePlaylists([playlist])
        try store.saveSettings(settings)
        try fm.createDirectory(at: undoDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: undoFile)
        // First save has no previous version, so the fallback is the default value.
        XCTAssertFalse(fm.fileExists(atPath: dataDir.appendingPathComponent("library.json.bak").path))

        try Data("{".utf8).write(to: dataDir.appendingPathComponent("library.json"))

        let index = store.loadIndex()
        XCTAssertTrue(index.tracks.isEmpty)
        XCTAssertTrue(index.folders.isEmpty)
        // The corrupt index must never take the rest of the user's data with it.
        XCTAssertEqual(store.loadPlaylists(), [playlist])
        XCTAssertEqual(store.loadSettings().themePreset, "forest")
        XCTAssertTrue(fm.fileExists(atPath: undoFile.path))
    }

    func testCorruptIndexFallsBackToPreviousVersion() throws {
        let store = IndexStore(directory: dataDir)
        let old = LibraryIndex(tracks: [sampleTrack()], folders: [libraryRoot])
        let new = LibraryIndex(tracks: [sampleTrack(), sampleTrack()], folders: [libraryRoot])

        try store.saveIndex(old)
        try store.saveIndex(new)
        try Data("{".utf8).write(to: dataDir.appendingPathComponent("library.json"))

        let recovered = store.loadIndex()
        XCTAssertEqual(recovered.tracks, old.tracks)
    }

    func testSavingAfterRecoveryNeverCopiesCorruptFileIntoBackup() throws {
        let store = IndexStore(directory: dataDir)
        let old = LibraryIndex(tracks: [sampleTrack()], folders: [libraryRoot])
        let middle = LibraryIndex(tracks: [sampleTrack(), sampleTrack()], folders: [libraryRoot])
        let latest = LibraryIndex(tracks: [sampleTrack(), sampleTrack(), sampleTrack()], folders: [libraryRoot])

        try store.saveIndex(old)
        try store.saveIndex(middle) // .bak == old
        try Data("{".utf8).write(to: dataDir.appendingPathComponent("library.json"))
        XCTAssertEqual(store.loadIndex().tracks, old.tracks)

        try store.saveIndex(latest)
        try Data("{".utf8).write(to: dataDir.appendingPathComponent("library.json"))

        XCTAssertEqual(store.loadIndex().tracks, old.tracks)
    }

    func testCorruptPlaylistsRecoversFromBackup() throws {
        let store = IndexStore(directory: dataDir)
        let first = Playlist(name: "旧列表", trackIDs: [UUID()])
        let second = Playlist(name: "新列表", trackIDs: [UUID(), UUID()])

        try store.savePlaylists([first])
        try store.savePlaylists([second])
        XCTAssertTrue(fm.fileExists(atPath: dataDir.appendingPathComponent("playlists.json.bak").path))

        try Data("{".utf8).write(to: dataDir.appendingPathComponent("playlists.json"))

        XCTAssertEqual(store.loadPlaylists(), [first])
    }

    func testUnreadablePlaylistsReturnEmptyInsteadOfThrowing() throws {
        try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: dataDir.appendingPathComponent("playlists.json"))

        XCTAssertEqual(IndexStore(directory: dataDir).loadPlaylists(), [])
    }

    func testCorruptSettingsReturnDefaults() throws {
        try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: dataDir.appendingPathComponent("settings.json"))

        XCTAssertEqual(IndexStore(directory: dataDir).loadSettings(), AppSettings())
    }

    // MARK: - Incremental rescan

    @MainActor
    func testAddFolderScansAndPersists() async throws {
        try makeFile("第一首.mp3")
        let reader = StubReader()
        reader.setMetadata([
            "第一首.mp3": AudioMetadata(title: "第一首", artist: "歌手甲", duration: 12),
        ])

        let store = LibraryStore(directory: dataDir)
        await store.addFolder(libraryRoot, reader: reader)

        XCTAssertEqual(store.index.folders.map(\.standardizedFileURL), [libraryRoot.standardizedFileURL])
        let track = try track(named: "第一首", in: store)
        XCTAssertEqual(track.artist, "歌手甲")
        XCTAssertEqual(track.duration, 12)
        XCTAssertGreaterThan(track.fileSize, 0)
        XCTAssertEqual(persistedIndex().tracks.map(\.id), [track.id])
    }

    @MainActor
    func testAddSameFolderTwiceDoesNotDuplicate() async throws {
        try makeFile("重复.mp3")
        let reader = StubReader()
        reader.setMetadata(["重复.mp3": AudioMetadata(title: "重复", duration: 10)])
        let store = LibraryStore(directory: dataDir)

        await store.addFolder(libraryRoot, reader: reader)
        await store.addFolder(libraryRoot, reader: reader)

        XCTAssertEqual(store.index.folders.count, 1)
        XCTAssertEqual(store.index.tracks.count, 1)
    }

    @MainActor
    func testRescanAddsNewTracksAndKeepsExistingIDs() async throws {
        let firstURL = try makeFile("第一首.mp3")
        let reader = StubReader()
        reader.setMetadata([
            "第一首.mp3": AudioMetadata(title: "第一首", duration: 10),
        ])
        let store = LibraryStore(directory: dataDir)
        await store.addFolder(libraryRoot, reader: reader)
        let firstID = try track(named: "第一首", in: store).id

        let secondURL = try makeFile("第二首.mp3")
        reader.setMetadata([
            "第一首.mp3": AudioMetadata(title: "第一首", duration: 10),
            "第二首.mp3": AudioMetadata(title: "第二首", duration: 20),
        ])
        await store.rescan(reader: reader)

        XCTAssertEqual(store.index.tracks.count, 2)
        XCTAssertEqual(try track(named: "第一首", in: store).id, firstID)
        XCTAssertEqual(try track(named: "第二首", in: store).url.standardizedFileURL,
                       secondURL.standardizedFileURL)
        XCTAssertEqual(Set(persistedIndex().tracks.map(\.id)), Set(store.index.tracks.map(\.id)))
        XCTAssertEqual(try XCTUnwrap(store.index.tracks.first { $0.id == firstID }).url,
                       firstURL.standardizedFileURL)
    }

    @MainActor
    func testRescanUpdatesChangedTrackButKeepsID() async throws {
        let url = try makeFile("变化.mp3")
        let reader = StubReader()
        reader.setMetadata(["变化.mp3": AudioMetadata(title: "旧标题", artist: "旧歌手", duration: 10)])
        let store = LibraryStore(directory: dataDir)
        await store.addFolder(libraryRoot, reader: reader)
        let originalID = try track(named: "旧标题", in: store).id

        try appendBytes(64, to: url)
        reader.setMetadata(["变化.mp3": AudioMetadata(title: "新标题", artist: "新歌手", duration: 99)])
        await store.rescan(reader: reader)

        XCTAssertEqual(store.index.tracks.count, 1)
        let updated = try track(named: "新标题", in: store)
        XCTAssertEqual(updated.id, originalID)
        XCTAssertEqual(updated.artist, "新歌手")
        XCTAssertEqual(updated.duration, 99)
        XCTAssertFalse(updated.isMissing)
        XCTAssertEqual(persistedIndex().tracks.first?.title, "新标题")
    }

    @MainActor
    func testRescanKeepsExistingTrackWhenFileIsUnchanged() async throws {
        try makeFile("不变.mp3")
        let reader = StubReader()
        reader.setMetadata(["不变.mp3": AudioMetadata(title: "原名", duration: 10)])
        let store = LibraryStore(directory: dataDir)
        await store.addFolder(libraryRoot, reader: reader)
        let originalID = try track(named: "原名", in: store).id

        reader.setMetadata(["不变.mp3": AudioMetadata(title: "不该采用", duration: 10)])
        await store.rescan(reader: reader)

        XCTAssertEqual(store.index.tracks.count, 1)
        let unchanged = try track(named: "原名", in: store)
        XCTAssertEqual(unchanged.id, originalID)
        XCTAssertFalse(unchanged.isMissing)
    }

    @MainActor
    func testRescanMarksMissingTracksAndKeepsPlaylist() async throws {
        let keepURL = try makeFile("保留.mp3")
        let goneURL = try makeFile("消失.mp3")
        let reader = StubReader()
        reader.setMetadata([
            "保留.mp3": AudioMetadata(title: "保留", duration: 10),
            "消失.mp3": AudioMetadata(title: "消失", duration: 20),
        ])
        let store = LibraryStore(directory: dataDir)
        await store.addFolder(libraryRoot, reader: reader)
        let keepID = try track(named: "保留", in: store).id
        let goneID = try track(named: "消失", in: store).id
        let playlist = Playlist(name: "收藏", trackIDs: [keepID, goneID])
        try IndexStore(directory: dataDir).savePlaylists([playlist])
        // Simulate an index written before TrackFactory repaired mojibake:
        // load() must heal the title in place so a rescan keeps it readable.
        var persisted = IndexStore(directory: dataDir).loadIndex()
        if let position = persisted.tracks.firstIndex(where: { $0.id == keepID }) {
            persisted.tracks[position].title = String(
                data: Data(Array("保留".utf8)),
                encoding: .isoLatin1
            )!
        }
        try IndexStore(directory: dataDir).saveIndex(persisted)
        store.load()
        XCTAssertEqual(try track(named: "保留", in: store).id, keepID)

        try fm.removeItem(at: goneURL)
        await store.rescan(reader: reader)

        XCTAssertEqual(store.index.tracks.count, 2)
        let missing = try track(named: "消失", in: store)
        XCTAssertEqual(missing.id, goneID)
        XCTAssertTrue(missing.isMissing)
        XCTAssertEqual(store.missingTracks, [missing])
        XCTAssertFalse(try track(named: "保留", in: store).isMissing)
        XCTAssertEqual(try XCTUnwrap(store.index.tracks.first { $0.id == keepID }).url.standardizedFileURL,
                       keepURL.standardizedFileURL)
        // Missing tracks stay in playlists so the user can relocate them.
        XCTAssertEqual(store.playlists, [playlist])
        XCTAssertEqual(IndexStore(directory: dataDir).loadPlaylists(), [playlist])
    }

    @MainActor
    func testRescanDoesNotMarkUnreadableFilesAsMissing() async throws {
        let url = try makeFile("坏文件.mp3")
        let reader = StubReader()
        reader.setMetadata(["坏文件.mp3": AudioMetadata(title: "坏文件", duration: 10)])
        let store = LibraryStore(directory: dataDir)
        await store.addFolder(libraryRoot, reader: reader)

        reader.markUnreadable(["坏文件.mp3"])
        await store.rescan(reader: reader)

        XCTAssertEqual(store.unreadableURLs.map(\.standardizedFileURL), [url.standardizedFileURL])
        let track = try track(named: "坏文件", in: store)
        XCTAssertFalse(track.isMissing)
        XCTAssertTrue(store.missingTracks.isEmpty)
    }

    @MainActor
    func testRemoveMissingTracksPrunesPlaylists() async throws {
        try makeFile("留下.mp3")
        let goneURL = try makeFile("移除.mp3")
        let reader = StubReader()
        reader.setMetadata([
            "留下.mp3": AudioMetadata(title: "留下", duration: 10),
            "移除.mp3": AudioMetadata(title: "移除", duration: 20),
        ])
        let store = LibraryStore(directory: dataDir)
        await store.addFolder(libraryRoot, reader: reader)
        let keepID = try track(named: "留下", in: store).id
        let goneID = try track(named: "移除", in: store).id
        store.playlists = [Playlist(name: "收藏", trackIDs: [keepID, goneID])]

        try fm.removeItem(at: goneURL)
        await store.rescan(reader: reader)
        store.removeMissingTracks()

        XCTAssertEqual(store.index.tracks.map(\.id), [keepID])
        XCTAssertEqual(store.playlists.first?.trackIDs, [keepID])
        XCTAssertEqual(persistedIndex().tracks.map(\.id), [keepID])
        XCTAssertEqual(IndexStore(directory: dataDir).loadPlaylists().first?.trackIDs, [keepID])
    }

    @MainActor
    func testRescanWritesArtworkForNewAndChangedTracks() async throws {
        let url = try makeFile("封面.mp3")
        let reader = StubReader()
        reader.setMetadata([
            "封面.mp3": AudioMetadata(title: "封面", duration: 10, artworkData: Data([0xAA, 0xBB])),
        ])
        let store = LibraryStore(directory: dataDir)
        await store.addFolder(libraryRoot, reader: reader)

        let created = try track(named: "封面", in: store)
        XCTAssertEqual(created.artworkFileName, "\(created.id.uuidString).jpg")
        let coverURL = dataDir.appendingPathComponent("covers/\(created.id.uuidString).jpg")
        XCTAssertEqual(try Data(contentsOf: coverURL), Data([0xAA, 0xBB]))

        try appendBytes(16, to: url)
        reader.setMetadata([
            "封面.mp3": AudioMetadata(title: "封面", duration: 11, artworkData: Data([0xCC])),
        ])
        await store.rescan(reader: reader)

        let updated = try track(named: "封面", in: store)
        XCTAssertEqual(updated.id, created.id)
        XCTAssertEqual(updated.artworkFileName, "\(created.id.uuidString).jpg")
        XCTAssertEqual(try Data(contentsOf: coverURL), Data([0xCC]))
    }

    @MainActor
    func testRemoveFolderRemovesItsTracksAndPlaylistEntries() async throws {
        let firstFolder = try makeSubfolder("甲")
        let secondFolder = try makeSubfolder("乙")
        try makeFile("甲曲.mp3", in: firstFolder)
        try makeFile("乙曲.mp3", in: secondFolder)
        let reader = StubReader()
        reader.setMetadata([
            "甲曲.mp3": AudioMetadata(title: "甲曲", duration: 10),
            "乙曲.mp3": AudioMetadata(title: "乙曲", duration: 20),
        ])
        let store = LibraryStore(directory: dataDir)
        await store.addFolder(firstFolder, reader: reader)
        await store.addFolder(secondFolder, reader: reader)
        let firstID = try track(named: "甲曲", in: store).id
        let secondID = try track(named: "乙曲", in: store).id
        store.playlists = [Playlist(name: "收藏", trackIDs: [firstID, secondID])]

        store.removeFolder(firstFolder)

        XCTAssertEqual(store.index.folders.map(\.standardizedFileURL), [secondFolder.standardizedFileURL])
        XCTAssertEqual(store.index.tracks.map(\.id), [secondID])
        XCTAssertEqual(store.playlists.first?.trackIDs, [secondID])
        XCTAssertEqual(persistedIndex().tracks.map(\.id), [secondID])
    }

    @MainActor
    func testUpdateTrackPersistsEdits() async throws {
        try makeFile("编辑.mp3")
        let reader = StubReader()
        reader.setMetadata(["编辑.mp3": AudioMetadata(title: "原名", duration: 10)])
        let store = LibraryStore(directory: dataDir)
        await store.addFolder(libraryRoot, reader: reader)

        var track = try track(named: "原名", in: store)
        track.title = "改后的名字"
        track.artist = "改后的歌手"
        store.updateTrack(track)

        let persisted = try XCTUnwrap(persistedIndex().tracks.first)
        XCTAssertEqual(persisted.id, track.id)
        XCTAssertEqual(persisted.title, "改后的名字")
        XCTAssertEqual(persisted.artist, "改后的歌手")
    }

    @MainActor
    func testLoadRepairsGarbledTitlesAndPersists() throws {
        let id = UUID()
        let garbled = Track(
            id: id,
            url: URL(fileURLWithPath: "/tmp/天空之城.mp3"),
            title: misread("天空之城"),
            artist: misread("久石让"),
            album: misread("天空之城"),
            albumArtist: misread("久石让", encoding: gb18030)
        )
        try IndexStore(directory: dataDir).saveIndex(
            LibraryIndex(tracks: [garbled], folders: [libraryRoot])
        )

        let store = LibraryStore(directory: dataDir)
        store.load()

        let loaded = try XCTUnwrap(store.index.tracks.first)
        XCTAssertEqual(loaded.id, id)
        XCTAssertEqual(loaded.title, "天空之城")
        XCTAssertEqual(loaded.artist, "久石让")
        XCTAssertEqual(loaded.album, "天空之城")
        XCTAssertEqual(loaded.albumArtist, "久石让")
        // The healed row is written back, so the next launch starts clean.
        XCTAssertEqual(persistedIndex().tracks.first?.title, "天空之城")
    }
}
