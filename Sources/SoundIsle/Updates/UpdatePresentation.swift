import Foundation

/// Turns an update state into what each surface shows. The views only render
/// what this returns, so the rules — which states get a pill, which tone the
/// settings line takes, whether the menu bar offers anything — are testable
/// without a running app.
enum UpdatePresentation {
    // MARK: Top-bar pill

    enum PillKind: Equatable {
        case available
        case downloading
        case ready
    }

    struct Pill: Equatable {
        let kind: PillKind
        let version: String
    }

    static func pill(for state: UpdateController.State) -> Pill? {
        switch state {
        case .available(let release):
            return Pill(kind: .available, version: release.version.raw)
        case .downloading(let version):
            return Pill(kind: .downloading, version: version.raw)
        case .ready(let version):
            return Pill(kind: .ready, version: version.raw)
        case .idle, .checking, .upToDate, .failed, .installed:
            return nil
        }
    }

    // MARK: Settings status line

    enum Tone: Equatable {
        case neutral
        case accent
        case warning
    }

    enum StatusForm: Equatable {
        case checking
        case upToDate
        case available
        case downloading
        case ready
        case failed
        case installed
    }

    struct Status: Equatable {
        let form: StatusForm
        let tone: Tone
        /// Present for every form that names a version.
        let version: String?
        let failure: UpdateController.Failure?

        var isFailure: Bool { form == .failed }
    }

    static func status(for state: UpdateController.State, currentVersion: String) -> Status? {
        switch state {
        case .idle:
            return nil
        case .checking:
            return Status(form: .checking, tone: .neutral, version: nil, failure: nil)
        case .upToDate:
            return Status(form: .upToDate, tone: .neutral, version: currentVersion, failure: nil)
        case .available(let release):
            return Status(form: .available, tone: .accent, version: release.version.raw, failure: nil)
        case .downloading(let version):
            return Status(form: .downloading, tone: .accent, version: version.raw, failure: nil)
        case .ready(let version):
            return Status(form: .ready, tone: .accent, version: version.raw, failure: nil)
        case .failed(let failure):
            return Status(form: .failed, tone: .warning, version: nil, failure: failure)
        case .installed(let version):
            return Status(form: .installed, tone: .accent, version: version.raw, failure: nil)
        }
    }

    // MARK: Menu bar

    enum MenuEntry: Equatable {
        case available(String)
        case downloading
        case ready
    }

    static func menuBar(for state: UpdateController.State) -> MenuEntry? {
        switch state {
        case .available(let release): return .available(release.version.raw)
        case .downloading: return .downloading
        case .ready: return .ready
        case .idle, .checking, .upToDate, .failed, .installed: return nil
        }
    }
}
