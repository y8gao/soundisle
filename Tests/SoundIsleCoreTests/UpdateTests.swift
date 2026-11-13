import Foundation
import XCTest
@testable import SoundIsleCore

final class AppVersionTests: XCTestCase {
    func testParsesPlainAndPrefixedVersions() {
        XCTAssertEqual(AppVersion("0.7.2")?.components, [0, 7, 2])
        XCTAssertEqual(AppVersion("v1.0")?.components, [1, 0])
        XCTAssertEqual(AppVersion(" 2.10.3 ")?.components, [2, 10, 3])
        XCTAssertEqual(AppVersion("v0.8.0-beta.1")?.components, [0, 8, 0])
        XCTAssertEqual(AppVersion("1.2.3+build9")?.components, [1, 2, 3])
    }

    func testRejectsNonVersions() {
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("latest"))
        XCTAssertNil(AppVersion("1.x.0"))
    }

    func testComparesComponentWiseNotLexically() {
        // The reason this type exists: "0.7.10" is newer than "0.7.9".
        XCTAssertLessThan(AppVersion("0.7.9")!, AppVersion("0.7.10")!)
        XCTAssertLessThan(AppVersion("0.9")!, AppVersion("1.0")!)
        XCTAssertFalse(AppVersion("1.0")! < AppVersion("1.0.0")!)
        XCTAssertEqual(AppVersion("1.0")!, AppVersion("1.0.0")!)
        XCTAssertGreaterThan(AppVersion("1.0.1")!, AppVersion("1.0")!)
    }
}

final class UpdateReleaseDecoderTests: XCTestCase {
    func testDecodesSiteManifest() throws {
        let json = """
        {
          "version": "0.7.3",
          "page": "https://github.com/y8gao/soundisle/releases/tag/v0.7.3",
          "notes": "- fixed",
          "zip": {
            "url": "https://y8gao.pages.dev/downloads/SoundIsle-0.7.3-macOS-universal.zip",
            "sha256": "ABCDEF",
            "size": 4873520
          },
          "dmg": {
            "url": "https://y8gao.pages.dev/downloads/SoundIsle-0.7.3-macOS-universal.dmg"
          }
        }
        """.data(using: .utf8)!

        let release = try XCTUnwrap(UpdateReleaseDecoder.decode(json))
        XCTAssertEqual(release.version, AppVersion("0.7.3"))
        XCTAssertEqual(release.notes, "- fixed")
        XCTAssertEqual(release.pageURL?.absoluteString, "https://github.com/y8gao/soundisle/releases/tag/v0.7.3")
        XCTAssertEqual(release.zip?.sha256, "abcdef")
        XCTAssertEqual(release.zip?.size, 4873520)
        XCTAssertEqual(release.dmg?.url.lastPathComponent, "SoundIsle-0.7.3-macOS-universal.dmg")
        XCTAssertNotNil(release.installable)
    }

    func testDecodesGitHubRelease() throws {
        let json = """
        {
          "tag_name": "v0.7.3",
          "html_url": "https://github.com/y8gao/soundisle/releases/tag/v0.7.3",
          "body": "notes here",
          "assets": [
            { "name": "SoundIsle-0.7.3-macOS-universal.dmg", "browser_download_url": "https://example.com/a.dmg", "size": 5666797 },
            { "name": "SoundIsle-0.7.3-macOS-universal.zip", "browser_download_url": "https://example.com/a.zip", "size": 4873520 }
          ]
        }
        """.data(using: .utf8)!

        let release = try XCTUnwrap(UpdateReleaseDecoder.decode(json))
        XCTAssertEqual(release.version, AppVersion("0.7.3"))
        XCTAssertEqual(release.zip?.url.absoluteString, "https://example.com/a.zip")
        XCTAssertEqual(release.dmg?.size, 5666797)
        // No checksum from the API: announce it, never install it silently.
        XCTAssertNil(release.installable)
    }

    func testRejectsPayloadWithoutVersion() {
        XCTAssertNil(UpdateReleaseDecoder.decode(#"{"assets": []}"#.data(using: .utf8)!))
        XCTAssertNil(UpdateReleaseDecoder.decode(Data()))
    }
}

final class UpdateServiceTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testReportsUpdateFromTheFirstSource() async {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url, UpdateService.manifestURL)
            let body = #"{"version":"9.9.9","zip":{"url":"https://example.com/a.zip","sha256":"aa"}}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let service = UpdateService(current: AppVersion("0.7.2")!, session: session())
        guard case .update(let release) = await service.check() else {
            return XCTFail("expected an update")
        }
        XCTAssertEqual(release.version, AppVersion("9.9.9"))
    }

    func testReportsUpToDateForTheSameVersion() async {
        MockURLProtocol.handler = { request in
            let body = #"{"version":"0.7.2"}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let service = UpdateService(current: AppVersion("0.7.2")!, session: session())
        let check = await service.check()
        XCTAssertEqual(check, .upToDate)
    }

    func testFallsBackWhenTheFirstSourceIsBroken() async {
        var seen: [String] = []
        MockURLProtocol.handler = { request in
            seen.append(request.url!.absoluteString)
            if request.url == UpdateService.manifestURL {
                // A blocked or half-written mirror: not JSON at all.
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("<html>".utf8))
            }
            let body = #"{"tag_name":"v0.8.0","assets":[]}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let service = UpdateService(current: AppVersion("0.7.2")!, session: session())
        guard case .update(let release) = await service.check() else {
            return XCTFail("expected the fallback to answer")
        }
        XCTAssertEqual(release.version, AppVersion("0.8.0"))
        XCTAssertEqual(seen, [UpdateService.manifestURL.absoluteString, UpdateService.githubURL.absoluteString])
    }

    func testReportsFailureWhenEverySourceFails() async {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
        }
        let service = UpdateService(current: AppVersion("0.7.2")!, session: session())
        let check = await service.check()
        XCTAssertEqual(check, .failed)
    }
}

final class UpdateInstallerTests: XCTestCase {
    func testHashesAFileTheWayShasumDoes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("soundisle-hash-\(UUID().uuidString).bin")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(
            try UpdateInstaller.sha256(ofFileAt: url),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
    }

    func testSwapScriptQuotesPathsAndWaitsForTheProcess() {
        let script = UpdateInstaller.swapScript(
            newApp: URL(fileURLWithPath: "/tmp/it's here/声屿.app"),
            target: URL(fileURLWithPath: "/Applications/声屿.app"),
            pid: 4242,
            staging: URL(fileURLWithPath: "/tmp/staging dir")
        )
        XCTAssertTrue(script.contains("target='/Applications/声屿.app'"))
        XCTAssertTrue(script.contains("new='/tmp/it'\\''s here/声屿.app'"))
        XCTAssertTrue(script.contains("while kill -0 4242 2>/dev/null; do sleep 0.3; done"))
        XCTAssertTrue(script.contains("if ! /usr/bin/ditto \"$new\" \"$target\""))
        XCTAssertTrue(script.contains("/bin/mv \"$target.old\" \"$target\""))
        XCTAssertTrue(script.contains("/usr/bin/xattr -dr com.apple.quarantine"))
        XCTAssertTrue(script.contains("/usr/bin/open \"$target\""))
    }

    func testSwapWithoutRelaunchLeavesTheAppClosed() {
        let script = UpdateInstaller.swapScript(
            newApp: URL(fileURLWithPath: "/tmp/new/声屿.app"),
            target: URL(fileURLWithPath: "/Applications/声屿.app"),
            pid: 1,
            staging: URL(fileURLWithPath: "/tmp/staging"),
            relaunch: false
        )
        XCTAssertFalse(script.contains("/usr/bin/open"))
        // Still swaps and still clears the quarantine flag.
        XCTAssertTrue(script.contains("/usr/bin/ditto"))
        XCTAssertTrue(script.contains("/usr/bin/xattr -dr com.apple.quarantine"))
    }

    func testUnpackFindsTheAppInsideTheArchive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("soundisle-unpack-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source/声屿.app")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: source.appendingPathComponent("SoundIsle"))

        let archive = root.appendingPathComponent("release.zip")
        let zip = Process()
        zip.executableURL = UpdateInstaller.ditto
        zip.arguments = ["-c", "-k", "--keepParent", source.path, archive.path]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)

        let unpacked = try UpdateInstaller.unpack(archive, into: root.appendingPathComponent("out"))
        XCTAssertEqual(unpacked.lastPathComponent, "声屿.app")
        defer { try? FileManager.default.removeItem(at: root) }
    }
}
