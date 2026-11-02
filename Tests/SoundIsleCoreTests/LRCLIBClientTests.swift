import Foundation
import XCTest
@testable import SoundIsleCore

/// Intercepts every request made by the injected `URLSession` so the tests can
/// assert the exact LRCLIB URL and return canned JSON.
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
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

final class LRCLIBClientTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func respond(
        status: Int,
        json: String
    ) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(json.utf8))
        }
    }

    func testPrefersSyncedLyricsAndBuildsEncodedRequest() async throws {
        var captured: URLRequest?
        MockURLProtocol.handler = { request in
            captured = request
            let body = #"{"syncedLyrics":"[00:01.00]第一句\n[00:02.00]第二句","plainLyrics":"第一句\n第二句"}"#
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }

        let client = LRCLIBClient(session: session)
        let lyrics = try await client.fetch(
            title: "母亲",
            artist: "阎维文 & Friends",
            duration: 215.4
        )

        let request = try XCTUnwrap(captured)
        let components = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "lrclib.net")
        XCTAssertEqual(components.path, "/api/get")
        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) }
        )
        XCTAssertEqual(items["track_name"], "母亲")
        XCTAssertEqual(items["artist_name"], "阎维文 & Friends")
        XCTAssertEqual(items["duration"], "215")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "SoundIsle/0.1")
        // URLComponents must percent-encode the Chinese title and the ampersand.
        XCTAssertTrue(request.url!.absoluteString.contains("track_name=%E6%AF%8D%E4%BA%B2"))

        XCTAssertEqual(lyrics?.isSynced, true)
        XCTAssertEqual(lyrics?.lines.count, 2)
        XCTAssertEqual(lyrics?.lines.first?.text, "第一句")
        XCTAssertEqual(lyrics?.lines.last?.text, "第二句")
    }

    func testNotFoundReturnsNil() async throws {
        MockURLProtocol.handler = respond(
            status: 404,
            json: #"{"code":404,"name":"TrackNotFound","message":"not found"}"#
        )

        let lyrics = try await LRCLIBClient(session: session).fetch(
            title: "不存在",
            artist: "无人",
            duration: 100
        )

        XCTAssertNil(lyrics)
    }

    func testFallsBackToPlainLyrics() async throws {
        MockURLProtocol.handler = respond(
            status: 200,
            json: #"{"syncedLyrics":null,"plainLyrics":"第一句\n第二句"}"#
        )

        let lyrics = try await LRCLIBClient(session: session).fetch(
            title: "母亲",
            artist: "阎维文",
            duration: 215
        )

        XCTAssertEqual(lyrics?.isSynced, false)
        XCTAssertEqual(lyrics?.lines.map(\.text), ["第一句", "第二句"])
    }

    func testEmptyResponseReturnsNil() async throws {
        MockURLProtocol.handler = respond(
            status: 200,
            json: #"{"syncedLyrics":null,"plainLyrics":null}"#
        )

        let lyrics = try await LRCLIBClient(session: session).fetch(
            title: "母亲",
            artist: "阎维文",
            duration: 215
        )

        XCTAssertNil(lyrics)
    }

    func testNetworkErrorPropagates() async {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }

        do {
            _ = try await LRCLIBClient(session: session).fetch(
                title: "母亲",
                artist: "阎维文",
                duration: 215
            )
            XCTFail("Expected the network error to propagate")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    func testServerErrorPropagates() async {
        MockURLProtocol.handler = respond(status: 500, json: "{}")

        do {
            _ = try await LRCLIBClient(session: session).fetch(
                title: "母亲",
                artist: "阎维文",
                duration: 215
            )
            XCTFail("Expected a bad status to throw")
        } catch {
            // Any error is fine here; the service turns it into a silent nil.
        }
    }
}
