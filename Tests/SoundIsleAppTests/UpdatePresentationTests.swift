import Foundation
import XCTest
@testable import SoundIsle
import SoundIsleCore

/// The surfaces are three views, but what they show is one set of rules.
/// These pin the rules down: which states get a pill, which tone the settings
/// line takes, and what the menu bar offers.
final class UpdatePresentationTests: XCTestCase {
    private let release = UpdateRelease(version: AppVersion("9.9.9")!)
    private let current = "0.7.2"

    // MARK: - Pill

    func testPillOnlyAppearsWhenThereIsSomethingToDo() {
        XCTAssertNil(UpdatePresentation.pill(for: .idle))
        XCTAssertNil(UpdatePresentation.pill(for: .checking))
        XCTAssertNil(UpdatePresentation.pill(for: .upToDate))
        XCTAssertNil(UpdatePresentation.pill(for: .failed(.check)))
        XCTAssertNil(UpdatePresentation.pill(for: .installed(AppVersion("9.9.9")!)))

        XCTAssertEqual(
            UpdatePresentation.pill(for: .available(release)),
            .init(kind: .available, version: "9.9.9")
        )
        XCTAssertEqual(
            UpdatePresentation.pill(for: .downloading(AppVersion("9.9.9")!)),
            .init(kind: .downloading, version: "9.9.9")
        )
        XCTAssertEqual(
            UpdatePresentation.pill(for: .ready(AppVersion("9.9.9")!)),
            .init(kind: .ready, version: "9.9.9")
        )
    }

    // MARK: - Settings line

    func testEachStateHasASettingsLineWithTheRightTone() {
        XCTAssertNil(UpdatePresentation.status(for: .idle, currentVersion: current))

        let checking = UpdatePresentation.status(for: .checking, currentVersion: current)
        XCTAssertEqual(checking?.form, .checking)
        XCTAssertEqual(checking?.tone, .neutral)

        let upToDate = UpdatePresentation.status(for: .upToDate, currentVersion: current)
        XCTAssertEqual(upToDate?.form, .upToDate)
        XCTAssertEqual(upToDate?.version, current)
        XCTAssertEqual(upToDate?.tone, .neutral)

        let available = UpdatePresentation.status(for: .available(release), currentVersion: current)
        XCTAssertEqual(available?.form, .available)
        XCTAssertEqual(available?.version, "9.9.9")
        XCTAssertEqual(available?.tone, .accent)

        let downloading = UpdatePresentation.status(
            for: .downloading(AppVersion("9.9.9")!), currentVersion: current
        )
        XCTAssertEqual(downloading?.form, .downloading)

        let ready = UpdatePresentation.status(for: .ready(AppVersion("9.9.9")!), currentVersion: current)
        XCTAssertEqual(ready?.form, .ready)

        let installed = UpdatePresentation.status(
            for: .installed(AppVersion("9.9.9")!), currentVersion: current
        )
        XCTAssertEqual(installed?.form, .installed)
        XCTAssertEqual(installed?.tone, .accent)
    }

    func testOnlyFailuresUseTheWarningTone() {
        let cases: [UpdateController.State] = [
            .idle, .checking, .upToDate, .available(release),
            .downloading(AppVersion("9.9.9")!), .ready(AppVersion("9.9.9")!),
            .installed(AppVersion("9.9.9")!)
        ]
        for state in cases {
            XCTAssertNotEqual(
                UpdatePresentation.status(for: state, currentVersion: current)?.tone,
                .warning,
                "\(state) must not read as a warning"
            )
        }

        let failed = UpdatePresentation.status(for: .failed(.checksum), currentVersion: current)
        XCTAssertEqual(failed?.tone, .warning)
        XCTAssertEqual(failed?.failure, .checksum)
        XCTAssertNil(failed?.version)
    }

    /// Nothing on these surfaces may ever read "up to date" while an update is
    /// waiting — that is the one message that would stop the user acting.
    func testNoPendingStateIsReportedAsUpToDate() {
        for state: UpdateController.State in [
            .available(release),
            .downloading(AppVersion("9.9.9")!),
            .ready(AppVersion("9.9.9")!)
        ] {
            XCTAssertNotEqual(
                UpdatePresentation.status(for: state, currentVersion: current)?.form,
                .upToDate
            )
            XCTAssertNotNil(UpdatePresentation.pill(for: state))
        }
    }

    // MARK: - Menu bar

    func testMenuBarMirrorsThePill() {
        XCTAssertNil(UpdatePresentation.menuBar(for: .idle))
        XCTAssertNil(UpdatePresentation.menuBar(for: .upToDate))
        XCTAssertEqual(UpdatePresentation.menuBar(for: .available(release)), .available("9.9.9"))
        XCTAssertEqual(UpdatePresentation.menuBar(for: .downloading(AppVersion("9.9.9")!)), .downloading)
        XCTAssertEqual(UpdatePresentation.menuBar(for: .ready(AppVersion("9.9.9")!)), .ready)
    }
}
