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

        let items = organizer.plan([motherTrack(url: source)], template: motherTemplate, root: destinationRoot)

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
            root: destinationRoot
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
        let items = organizer.plan([motherTrack(url: source)], template: motherTemplate, root: destinationRoot)

        try organizer.apply(items, copy: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: items[0].destination.path))
        XCTAssertEqual(try String(contentsOf: items[0].destination, encoding: .utf8), "audio")
    }

    func testApplyMoveRemovesSourceAndUndoRestoresIt() throws {
        let source = try makeFile("a.mp3", in: libraryDir, contents: "audio")
        let organizer = makeOrganizer()
        let items = organizer.plan([motherTrack(url: source)], template: motherTemplate, root: destinationRoot)

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
        let items = organizer.plan([motherTrack(url: source)], template: motherTemplate, root: destinationRoot)

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
            root: destinationRoot
        )
        try makeOrganizer().apply(items, copy: false)

        let reopened = makeOrganizer()
        let undone = try reopened.undoLast()

        XCTAssertEqual(undone, items)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    // MARK: - Data-loss paths

    func testApplyRefusesExistingDestinationWithoutOverwriting() throws {
        let source = try makeFile("a.mp3", in: libraryDir, contents: "source")
        let organizer = makeOrganizer()
        let items = organizer.plan(
            [motherTrack(url: source)],
            template: motherTemplate,
            root: destinationRoot
        )
        // The destination appears after the preview was produced.
        let existing = try makeFile(
            items[0].destination.lastPathComponent,
            in: items[0].destination.deletingLastPathComponent(),
            contents: "keep-me"
        )

        XCTAssertThrowsError(try organizer.apply(items, copy: false)) { error in
            guard let organizeError = error as? OrganizeError,
                  case .destinationExists(_) = organizeError else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep-me")
        XCTAssertTrue(organizer.undo.entries.isEmpty)
    }

    func testPartialApplyThenUndoReturnsOnlyAppliedRows() throws {
        let firstSource = try makeFile("a.mp3", in: libraryDir, contents: "a")
        let secondSource = try makeFile("b.mp3", in: libraryDir, contents: "b")
        var second = motherTrack(url: secondSource)
        // Different artist => different destination parent, so only the second
        // row can be blocked.
        second.artist = ""
        let organizer = makeOrganizer()
        let items = organizer.plan(
            [motherTrack(url: firstSource), second],
            template: motherTemplate,
            root: destinationRoot
        )
        XCTAssertEqual(items.count, 2)

        let blockedParent = items[1].destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: blockedParent.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-a-directory".utf8).write(to: blockedParent)

        XCTAssertThrowsError(try organizer.apply(items, copy: false)) { error in
            guard let organizeError = error as? OrganizeError,
                  case let .applyFailed(applied, _) = organizeError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(applied, [items[0]])
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: items[0].destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondSource.path))

        // The un-applied row has no destination, so undo reports only the row
        // that actually moved and still clears the entry.
        let restored = try organizer.undoLast()
        XCTAssertEqual(restored, [items[0]])
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstSource.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: items[0].destination.path))
        XCTAssertNil(try organizer.undoLast())
    }

    @MainActor
    func testPartialUndoFailureUpdatesRestoredTrackAndRescanKeepsIdentity() async throws {
        let dataDirectory = tempDir.appendingPathComponent("data-partial-undo", isDirectory: true)
        let library = LibraryStore(directory: dataDirectory)
        library.index.folders = [libraryDir]
        // Non-native extension so the scanner includes these dummy files.
        try makeFile("a.wma", in: libraryDir, contents: "a")
        try makeFile("b.wma", in: libraryDir, contents: "b")
        await library.rescan()
        XCTAssertEqual(library.index.tracks.count, 2)
        let idBySource = Dictionary(uniqueKeysWithValues: library.index.tracks.map {
            ($0.url.standardizedFileURL, $0.id)
        })

        let organizer = makeOrganizer()
        let items = organizer.plan(
            library.index.tracks,
            template: "{title}",
            root: destinationRoot
        )
        XCTAssertEqual(items.count, 2)
        try organizer.apply(items, copy: false)
        library.updateTrackURLs(OrganizeURLMapping.apply(items))
        library.ensureFoldersCovering([destinationRoot])
        await library.rescan()

        // Undo walks rows in reverse: items[1] restores, then items[0] hits
        // the recreated source path and fails.
        try makeFile(items[0].source.lastPathComponent, in: libraryDir, contents: "conflict")

        var restored: [OrganizePlanItem] = []
        do {
            _ = try organizer.undoLast()
            XCTFail("undo should fail on the conflicting source")
        } catch let error as OrganizeError {
            guard case let .undoFailed(rows, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            restored = rows
        }

        XCTAssertEqual(restored, [items[1]])

        // Mirrors AppModel's catch branch: the successfully restored row must
        // update the index immediately, or the next rescan loses its ID.
        library.updateTrackURLs(OrganizeURLMapping.undo(restored))
        for item in items {
            let id = try XCTUnwrap(idBySource[item.source.standardizedFileURL])
            let track = try XCTUnwrap(library.index.tracks.first { $0.id == id })
            let expected = item == items[0] ? item.destination : item.source
            XCTAssertEqual(track.url.standardizedFileURL, expected.standardizedFileURL)
        }

        await library.rescan()
        for item in items {
            let id = try XCTUnwrap(idBySource[item.source.standardizedFileURL])
            XCTAssertEqual(library.index.tracks.filter { $0.id == id }.count, 1)
            let track = try XCTUnwrap(library.index.tracks.first { $0.id == id })
            XCTAssertFalse(track.isMissing)
            let expected = item == items[0] ? item.destination : item.source
            XCTAssertEqual(track.url.standardizedFileURL, expected.standardizedFileURL)
        }
    }

    func testCrossVolumeCheckFailsClosedWhenVolumesAreUnknown() {
        // A manager that sees no filesystem forces `volumeIdentifier` to
        // return nil; the safe answer is "ask the user".
        XCTAssertTrue(
            FileOrganizer.crossesVolumes(
                source: tempDir.appendingPathComponent("a.mp3"),
                destination: tempDir.appendingPathComponent("b.mp3"),
                manager: NothingExistsFileManager()
            )
        )
    }

    func testCrossVolumeCheckSeesSameVolume() {
        XCTAssertFalse(
            FileOrganizer.crossesVolumes(
                source: libraryDir.appendingPathComponent("a.mp3"),
                destination: destinationRoot.appendingPathComponent("b.mp3")
            )
        )
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

    /// Files organized into a brand-new root must stay visible: the root is
    /// added to `index.folders`, so a later rescan still finds the track.
    @MainActor
    func testRescanFindsTrackAfterOrganizingIntoNewRoot() async throws {
        let dataDirectory = tempDir.appendingPathComponent("data-rescan", isDirectory: true)
        let library = LibraryStore(directory: dataDirectory)
        library.index.folders = [libraryDir]
        try makeFile("song.wma", in: libraryDir, contents: "dummy audio")

        await library.rescan()
        let original = try XCTUnwrap(library.index.tracks.first { $0.url.lastPathComponent == "song.wma" })

        let organizer = makeOrganizer()
        let items = organizer.plan(
            library.index.tracks,
            template: "{artist}/{album}/{title}",
            root: destinationRoot
        )
        try organizer.apply(items, copy: false)
        XCTAssertEqual(items.count, 1)

        library.updateTrackURLs([
            items[0].source.standardizedFileURL: items[0].destination.standardizedFileURL
        ])
        XCTAssertTrue(library.ensureFoldersCovering([destinationRoot]))

        await library.rescan()

        let rescanned = library.index.tracks.first { $0.id == original.id }
        XCTAssertEqual(rescanned?.url.standardizedFileURL, items[0].destination.standardizedFileURL)
        XCTAssertEqual(rescanned?.isMissing, false)
        XCTAssertTrue(library.index.folders.contains {
            $0.standardizedFileURL == destinationRoot.standardizedFileURL
        })

        let reloaded = IndexStore(directory: dataDirectory).loadIndex()
        XCTAssertTrue(reloaded.folders.contains {
            $0.standardizedFileURL == destinationRoot.standardizedFileURL
        })
    }

    // MARK: - Corrupt undo history

    func testOrganizeHistoryRecoversFromBackup() throws {
        let source = libraryDir.appendingPathComponent("a.mp3")
        let destination = destinationRoot.appendingPathComponent("b.mp3")
        let item = OrganizePlanItem(source: source, destination: destination, conflictResolved: false)
        let store = OrganizeUndoStore(directory: undoDir)
        try store.record([item], copy: false)
        try store.record([item], copy: false)

        let file = undoDir.appendingPathComponent("organize.json")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: file.appendingPathExtension("bak").path
        ))
        try Data("{".utf8).write(to: file)

        let reopened = OrganizeUndoStore(directory: undoDir)
        XCTAssertEqual(reopened.entries.count, 1)
        XCTAssertNotNil(reopened.loadNotice)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testOrganizeHistoryCorruptionWithoutBackupReports() throws {
        try Data("{".utf8).write(to: undoDir.appendingPathComponent("organize.json"))

        let store = OrganizeUndoStore(directory: undoDir)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNotNil(store.loadNotice)
    }
}

/// Simulates an unreadable filesystem so volume detection cannot resolve.
private final class NothingExistsFileManager: FileManager {
    override func fileExists(atPath path: String) -> Bool { false }

}
