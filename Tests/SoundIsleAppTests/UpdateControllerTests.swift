import Foundation
import XCTest
@testable import SoundIsle
import SoundIsleCore

/// Intercepts every request so a test can serve a manifest and a release
/// archive without a network.
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var requests: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url { Self.requests.append(url) }
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class UpdateControllerTests: XCTestCase {
    private var support: URL!
    private var archive: (url: URL, sha256: String)!
    private var mode = "automatic"
    private var skipped: String?
    private var notices: [AppNotice] = []
    private var requests: [String] = []

    private let manifestURL = URL(string: "https://example.test/latest.json")!

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        archive = try Self.makeReleaseArchive(in: support)
        mode = "automatic"
        skipped = nil
        notices = []
        requests = []
        MockURLProtocol.requests = []
    }

    override func tearDownWithError() throws {
        MockURLProtocol.handler = nil
        try? FileManager.default.removeItem(at: support)
    }

    // MARK: - Helpers

    /// A real zip with a `.app` inside, so the unpack step is exercised for
    /// real rather than stubbed.
    private static func makeReleaseArchive(in root: URL) throws -> (URL, String) {
        let app = root.appendingPathComponent("build/声屿.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: app.appendingPathComponent("SoundIsle"))
        let zip = root.appendingPathComponent("release.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
        try process.run()
        process.waitUntilExit()
        return (zip, try UpdateInstaller.sha256(ofFileAt: zip))
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func serveManifest(version: String, sha256: String? = nil, page: String = "https://example.test/release") {
        let digest = sha256 ?? archive.sha256
        MockURLProtocol.handler = { request in
            let body: String
            if request.url?.path.hasSuffix(".zip") == true {
                body = ""
            } else {
                body = """
                {"version":"\(version)","page":"\(page)","zip":{"url":"https://example.test/release.zip","sha256":"\(digest)"}}
                """
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                request.url?.path.hasSuffix(".zip") == true ? (try? Data(contentsOf: self.archive.url)) ?? Data() : Data(body.utf8)
            )
        }
    }

    private func makeController() -> UpdateController {
        let service = UpdateService(
            current: AppVersion("0.7.2")!,
            sources: [.manifest(manifestURL)],
            session: session()
        )
        let controller = UpdateController(
            currentVersion: AppVersion("0.7.2")!,
            supportDirectory: support,
            modeProvider: { [unowned self] in self.mode },
            skippedVersion: { [unowned self] in self.skipped },
            setSkippedVersion: { [unowned self] in self.skipped = $0 },
            service: service,
            session: session(),
            bundleURL: support.appendingPathComponent("installed/声屿.app")
        )
        controller.notify = { [unowned self] in self.notices.append($0) }
        return controller
    }

    private func stagedApp(version: String) -> URL {
        support.appendingPathComponent("updates/\(version)/声屿.app")
    }

    // MARK: - Automatic

    func testAutomaticModeStagesTheReleaseAndOffersARestart() async throws {
        serveManifest(version: "9.9.9")
        let controller = makeController()

        await controller.check()

        XCTAssertEqual(controller.state, .ready(AppVersion("9.9.9")!))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedApp(version: "9.9.9").path))
        XCTAssertEqual(notices.last?.actionTitle, "现在重启")
        XCTAssertTrue(notices.contains { $0.text.contains("9.9.9") })
        // Nothing is applied until the user asks or quits.
        XCTAssertTrue(notices.allSatisfy { $0.actionTitle != "立即安装" })
    }

    func testAutomaticModeNeverTouchesTheInstalledApp() async throws {
        serveManifest(version: "9.9.9")
        let controller = makeController()
        let installed = support.appendingPathComponent("installed/声屿.app")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)

        await controller.check()

        // The running bundle is only ever replaced by the quit-time script.
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.appendingPathComponent("SoundIsle").path))
    }

    // MARK: - Notify only

    func testNotifyModeAnnouncesWithoutDownloading() async throws {
        mode = "notify"
        serveManifest(version: "9.9.9")
        let controller = makeController()

        await controller.check()

        XCTAssertEqual(controller.state, .available(try XCTUnwrap(controller.availableRelease)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedApp(version: "9.9.9").path))
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.path.hasSuffix(".zip") })
        XCTAssertTrue(notices.contains { $0.text.contains("发现新版本") })
    }

    // MARK: - Off

    func testOffModeSkipsPeriodicChecksButStillAnswersTheUser() async throws {
        mode = "off"
        serveManifest(version: "9.9.9")
        let controller = makeController()

        await controller.check()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(MockURLProtocol.requests.isEmpty)

        await controller.check(manual: true)
        XCTAssertNotNil(controller.availableRelease)
        XCTAssertFalse(MockURLProtocol.requests.isEmpty)
    }

    // MARK: - Skipping a version

    func testSkippedVersionStaysQuietUntilTheNextOne() async throws {
        mode = "notify"
        skipped = "9.9.9"
        serveManifest(version: "9.9.9")
        let controller = makeController()

        await controller.check()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(notices.isEmpty)

        // The user asking directly still gets an answer.
        await controller.check(manual: true)
        XCTAssertNotNil(controller.availableRelease)

        // A newer version is not suppressed by the old skip.
        serveManifest(version: "9.9.10")
        await controller.check()
        XCTAssertEqual(controller.availableRelease?.version, AppVersion("9.9.10")!)
    }

    func testSkipRecordsTheVersionAndClearsThePill() async throws {
        mode = "notify"
        serveManifest(version: "9.9.9")
        let controller = makeController()
        await controller.check()
        let release = try XCTUnwrap(controller.availableRelease)

        controller.skip(release)

        XCTAssertEqual(skipped, "9.9.9")
        XCTAssertEqual(controller.state, .idle)
    }

    // MARK: - Failures

    func testChecksumMismatchRefusesToStage() async throws {
        serveManifest(version: "9.9.9", sha256: String(repeating: "0", count: 64))
        let controller = makeController()

        await controller.check(manual: true)

        XCTAssertEqual(controller.state, .failed(.checksum))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedApp(version: "9.9.9").path))
    }

    func testUnreachableSourcesFailPeriodicallyWithoutANotice() async throws {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
        }
        let controller = makeController()

        await controller.check()
        XCTAssertEqual(controller.state, .failed(.check))
        XCTAssertTrue(notices.isEmpty)

        await controller.check(manual: true)
        XCTAssertEqual(notices.last?.kind, .warning)
        XCTAssertEqual(notices.last?.actionTitle, "重试")
    }

    func testUpToDateOnlySpeaksWhenAsked() async throws {
        serveManifest(version: "0.7.2")
        let controller = makeController()

        await controller.check()
        XCTAssertEqual(controller.state, .upToDate)
        XCTAssertTrue(notices.isEmpty)

        await controller.check(manual: true)
        XCTAssertTrue(notices.contains { $0.kind == .success && $0.text.contains("0.7.2") })
    }

    // MARK: - Across launches

    func testAStagedUpdateSurvivesARelaunch() async throws {
        serveManifest(version: "9.9.9")
        let first = makeController()
        await first.check()
        XCTAssertEqual(first.state, .ready(AppVersion("9.9.9")!))

        let second = makeController()
        second.start()
        XCTAssertEqual(second.state, .ready(AppVersion("9.9.9")!))
    }

    func testAnAppliedUpdateIsAnnouncedExactlyOnce() throws {
        let marker = support.appendingPathComponent("applied-update.json")
        let payload = ["version": "9.9.9", "path": stagedApp(version: "9.9.9").path]
        try JSONSerialization.data(withJSONObject: payload).write(to: marker)

        let controller = makeController()
        controller.start()

        XCTAssertTrue(notices.contains { $0.kind == .success && $0.text.contains("9.9.9") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        notices = []
        controller.start()   // `didStart` guard, but the marker is gone anyway.
        XCTAssertTrue(notices.isEmpty)
    }
}
