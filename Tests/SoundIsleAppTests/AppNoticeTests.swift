import XCTest
@testable import SoundIsle

final class AppNoticeTests: XCTestCase {
    /// Failures wait for the user; ordinary reports get a few seconds. This is
    /// what lets the list's banner go away and everything else live in the
    /// window notice without losing an error to a passing glance.
    func testFailuresAndProgressDoNotDismissThemselves() {
        XCTAssertEqual(AppNotice(kind: .warning, text: "x").duration, 0)
        XCTAssertEqual(AppNotice(kind: .busy, text: "x").duration, 0)
    }

    func testReportsDismissThemselves() {
        XCTAssertEqual(AppNotice(kind: .success, text: "x").duration, 3)
        XCTAssertEqual(AppNotice(kind: .info, text: "x").duration, 6)
    }
}
