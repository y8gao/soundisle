import XCTest
@testable import SoundIsleCore

final class FileOrganizerTests: XCTestCase {
    private var tempDir: URL!
    private var libraryDir: URL!
    private var destinationRoot: URL!
    private var undoDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoundIsleOrganizerTests-\(UUID().uuidString)", isDirectory: true)
        libraryDir = tempDir.appendingPathComponent("library", isDirectory: true)
        destinationRoot = tempDir.appendingPathComponent("organized", isDirectory: true)
        undoDir = tempDir.appendingPathComponent("undo", isDirectory: true)
        for directory in [libraryDir, destinationRoot, undoDir] {
            try FileManager.default.createDirectory(at: directory!, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    @discardableResult
    private func makeFile(_ name: String, in directory: URL, contents: String = "audio") throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func makeOrganizer() -> FileOrganizer {
        FileOrganizer(undo: OrganizeUndoStore(directory: undoDir))
    }

    private func motherTrack(url: URL? = nil) -> Track {
        Track(
            url: url ?? libraryDir.appendingPathComponent("a.mp3"),
            title: "母亲",
            artist: "阎维文",
            album: "战士情歌",
            trackNumber: 1
        )
    }

    private var motherTemplate: String { "{artist}/{album}/{track} {title}" }

    private func relativePath(_ url: URL, from root: URL) -> String {
        let prefix = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    // MARK: - Template rendering

    func testRenderTemplateBuildsPathFromTags() {
        let rendered = OrganizeTemplate.render(
            template: motherTemplate,
            track: motherTrack(),
            root: destinationRoot
        )

        XCTAssertEqual(relativePath(rendered, from: destinationRoot), "阎维文/战士情歌/1 母亲.mp3")
    }

    func testRenderFallsBackToUnknownArtistAndAlbum() {
        let track = Track(
            url: libraryDir.appendingPathComponent("a.mp3"),
            title: "母亲",
            artist: "",
            album: ""
        )

        let rendered = OrganizeTemplate.render(
            template: motherTemplate,
            track: track,
            root: destinationRoot
        )

        XCTAssertEqual(relativePath(rendered, from: destinationRoot), "未知歌手/未知专辑/母亲.mp3")
    }

    func testRenderUsesAlbumArtistAndYearAndExplicitExtension() {
        var track = motherTrack()
        track.albumArtist = "群星"
        track.year = 2004
        track.url = libraryDir.appendingPathComponent("a.flac")

        let rendered = OrganizeTemplate.render(
            template: "{albumArtist}/{year}/{title}.{ext}",
            track: track,
            root: destinationRoot
        )

        XCTAssertEqual(relativePath(rendered, from: destinationRoot), "群星/2004/母亲.flac")
    }

    func testRenderSanitizesIllegalCharactersPerComponent() {
        var track = motherTrack()
        track.artist = "刀郎/云朵"
        track.title = "A:B"

        let rendered = OrganizeTemplate.render(
            template: motherTemplate,
            track: track,
            root: destinationRoot
        )

        XCTAssertEqual(relativePath(rendered, from: destinationRoot), "刀郎、云朵/战士情歌/1 A-B.mp3")
    }

    func testRenderDoesNotEscapeRootForDotDotTitle() {
        var track = motherTrack()
        track.title = ".."

        let rendered = OrganizeTemplate.render(
            template: "{title}",
            track: track,
            root: destinationRoot
        )

        XCTAssertTrue(rendered.standardizedFileURL.path.hasPrefix(destinationRoot.standardizedFileURL.path + "/"))
    }

    // MARK: - Conflict numbering

    func testPlanNumbersExistingConflictWithoutOverwriting() throws {
        let source = try makeFile("a.mp3", in: libraryDir)
        let existing = try makeFile(
            "1 母亲.mp3",
            in: destinationRoot.appendingPathComponent("阎维文/战士情歌"),
            contents: "original"
        )
        let organizer = makeOrganizer()

        let items = organizer.plan([motherTrack(url: source)], template: motherTemplate, root: destinationRoot, copy: false)

        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].conflictResolved)
        XCTAssertEqual(items[0].destination.lastPathComponent, "1 母亲 (2).mp3")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "original")
    }

    func testPlanNumbersConflictsBetweenPlannedTracks() throws {
        let first = try makeFile("a.mp3", in: libraryDir, contents: "a")
        let second = try makeFile("b.mp3", in: libraryDir, contents: "b")
        let organizer = makeOrganizer()

        let items = organizer.plan(
            [motherTrack(url: first), motherTrack(url: second)],
            template: motherTemplate,
            root: destinationRoot,
            copy: false
        )

        XCTAssertEqual(items.count, 2)
        XCTAssertFalse(items[0].conflictResolved)
        XCTAssertEqual(relativePath(items[0].destination, from: destinationRoot), "阎维文/战士情歌/1 母亲.mp3")
        XCTAssertTrue(items[1].conflictResolved)
        XCTAssertEqual(relativePath(items[1].destination, from: destinationRoot), "阎维文/战士情歌/1 母亲 (2).mp3")
    }

    // MARK: - Apply and undo

    func testApplyCopyLeavesSourceInPlace() throws {
        let source = try makeFile("a.mp3", in: libraryDir, contents: "audio")
        let organizer = makeOrganizer()
        let items = organizer.plan([motherTrack(url: source)], template: motherTemplate, root: destinationRoot, copy: true)

        try organizer.apply(items, copy: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: items[0].destination.path))
        XCTAssertEqual(try String(contentsOf: items[0].destination, encoding: .utf8), "audio")
    }

    func testApplyMoveRemovesSourceAndUndoRestoresIt() throws {
        let source = try makeFile("a.mp3", in: libraryDir, contents: "audio")
        let organizer = makeOrganizer()
        let items = organizer.plan([motherTrack(url: source)], template: motherTemplate, root: destinationRoot, copy: false)

        try organizer.apply(items, copy: false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: items[0].destination.path))

        let undone = try organizer.undoLast()

        XCTAssertEqual(undone, items)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: items[0].destination.path))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "audio")
    }

    func testUndoCopyRemovesDestinationAndKeepsSource() throws {
        let source = try makeFile("a.mp3", in: libraryDir)
        let organizer = makeOrganizer()
        let items = organizer.plan([motherTrack(url: source)], template: motherTemplate, root: destinationRoot, copy: true)

        try organizer.apply(items, copy: true)
        _ = try organizer.undoLast()

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: items[0].destination.path))
        XCTAssertNil(try organizer.undoLast())
    }

    func testUndoHistorySurvivesReinitialization() throws {
        let source = try makeFile("a.mp3", in: libraryDir)
        let items = makeOrganizer().plan(
            [motherTrack(url: source)],
            template: motherTemplate,
            root: destinationRoot,
            copy: false
        )
        try makeOrganizer().apply(items, copy: false)

        let reopened = makeOrganizer()
        let undone = try reopened.undoLast()

        XCTAssertEqual(undone, items)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    // MARK: - Library URL updates

    @MainActor
    func testUpdatingTrackURLsKeepsIdentityAndPersists() throws {
        let dataDirectory = tempDir.appendingPathComponent("data", isDirectory: true)
        let store = LibraryStore(directory: dataDirectory)
        let source = libraryDir.appendingPathComponent("a.mp3")
        let destination = destinationRoot.appendingPathComponent("阎维文/战士情歌/1 母亲.mp3")
        let track = motherTrack(url: source)
        store.index.tracks = [track]

        store.updateTrackURLs([source: destination])

        XCTAssertEqual(store.index.tracks.count, 1)
        XCTAssertEqual(store.index.tracks.first?.id, track.id)
        XCTAssertEqual(store.index.tracks.first?.url.standardizedFileURL, destination.standardizedFileURL)

        let reloaded = IndexStore(directory: dataDirectory).loadIndex()
        XCTAssertEqual(reloaded.tracks.first?.id, track.id)
        XCTAssertEqual(reloaded.tracks.first?.url.standardizedFileURL, destination.standardizedFileURL)
    }
}
