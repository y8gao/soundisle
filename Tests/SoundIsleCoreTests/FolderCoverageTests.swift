import XCTest
@testable import SoundIsleCore

final class FolderCoverageTests: XCTestCase {
    private var tempDir: URL!
    private var library: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoundIsleCoverageTests-\(UUID().uuidString)", isDirectory: true)
        library = tempDir.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testAlreadyCoveredFolderListIsUnchanged() {
        let destination = library.appendingPathComponent("Artist/Album", isDirectory: true)

        let result = FolderCoverage.ensureCovered(destination: destination, folders: [library])

        XCTAssertEqual(result, [library.standardizedFileURL])
    }

    func testOutsideRootIsAppendedOnce() {
        let outside = tempDir.appendingPathComponent("organized", isDirectory: true)

        let result = FolderCoverage.ensureCovered(destination: outside, folders: [library])
        let repeated = FolderCoverage.ensureCovered(destination: outside, folders: result)

        XCTAssertEqual(result, [library.standardizedFileURL, outside.standardizedFileURL])
        XCTAssertEqual(repeated, result)
    }

    func testNestedAndDuplicateRootsAreStandardizedAndDeduped() {
        let nested = library.appendingPathComponent("Artist", isDirectory: true)
        let destination = nested.appendingPathComponent("Album", isDirectory: true)

        let result = FolderCoverage.ensureCovered(
            destination: destination,
            folders: [library, library, nested]
        )

        XCTAssertEqual(result, [library.standardizedFileURL, nested.standardizedFileURL])
    }
}
