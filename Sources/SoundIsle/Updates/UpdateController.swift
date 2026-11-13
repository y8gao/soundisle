import AppKit
import Foundation
import SoundIsleCore

/// Watches for new releases, stages them, and swaps them in.
///
/// The check runs shortly after launch and then hourly while the app is open.
/// Nothing is installed behind the user's back unless they picked automatic
/// mode, and nothing is installed at all without a checksum to verify: the
/// GitHub fallback announces versions but never installs them.
@MainActor
final class UpdateController: ObservableObject {
    enum Mode: String, CaseIterable {
        case automatic
        case notify
        case off

        var title: String {
            switch self {
            case .automatic: return L("自动下载安装")
            case .notify: return L("更新提醒")
            case .off: return L("不提醒")
            }
        }
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        /// A newer build exists but is not on disk yet.
        case available(UpdateRelease)
        case downloading(AppVersion)
        /// Downloaded, verified and unpacked: it applies on quit, or now.
        case ready(AppVersion)
        case failed(Failure)
        /// The build that replaced the old one on the last run.
        case installed(AppVersion)
    }

    enum Failure: Error, Equatable {
        case check
        case checksum
        case unpack
        case notWritable(String)

        var message: String {
            switch self {
            case .check: return L("无法检查更新，请稍后再试")
            case .checksum: return L("更新包校验失败，已取消安装")
            case .unpack: return L("无法解压更新包")
            case .notWritable(let path): return Lf("没有写入权限：%@，请手动下载安装", path)
            }
        }
    }

    @Published private(set) var state: State = .idle
    let currentVersion: AppVersion

    var modeProvider: () -> String
    var skippedVersion: () -> String?
    var setSkippedVersion: (String?) -> Void
    var notify: (AppNotice) -> Void = { _ in }

    private let service: UpdateService
    private let session: URLSession
    private let bundleURL: URL
    private let updatesDirectory: URL
    private var timer: Timer?
    private var didStart = false
    private var isBusy = false

    private var stagedMarker: URL { updatesDirectory.appendingPathComponent("staged.json") }
    /// Outside `updatesDirectory` on purpose: the swap script deletes that
    /// whole directory after applying, and this marker has to survive one
    /// launch so the new build can say it arrived.
    private var appliedMarker: URL {
        updatesDirectory.deletingLastPathComponent().appendingPathComponent("applied-update.json")
    }

    init(
        currentVersion: AppVersion,
        supportDirectory: URL,
        modeProvider: @escaping () -> String,
        skippedVersion: @escaping () -> String?,
        setSkippedVersion: @escaping (String?) -> Void,
        service: UpdateService? = nil,
        session: URLSession = .shared,
        bundleURL: URL = Bundle.main.bundleURL
    ) {
        self.currentVersion = currentVersion
        self.updatesDirectory = supportDirectory.appendingPathComponent("updates", isDirectory: true)
        self.modeProvider = modeProvider
        self.skippedVersion = skippedVersion
        self.setSkippedVersion = setSkippedVersion
        self.service = service ?? UpdateService(current: currentVersion)
        self.session = session
        self.bundleURL = bundleURL
    }

    var mode: Mode { Mode(rawValue: modeProvider()) ?? .notify }

    var availableRelease: UpdateRelease? {
        if case .available(let release) = state { return release }
        return nil
    }

    var readyVersion: AppVersion? {
        if case .ready(let version) = state { return version }
        return nil
    }

    /// The version this build reports, straight from the bundle.
    static var installedVersion: AppVersion {
        let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return AppVersion(raw ?? "") ?? AppVersion("0")!
    }

    // MARK: - Schedule

    func start() {
        guard !didStart else { return }
        didStart = true

        announceAppliedIfNeeded()
        restoreStagedIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.check() }
        }

        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.check() }
        }
        timer.tolerance = 120
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        didStart = false
    }

    // MARK: - Checking

    func check(manual: Bool = false) async {
        guard !isBusy else { return }
        if !manual, mode == .off { return }
        if !manual, readyVersion != nil { return }

        isBusy = true
        state = .checking
        let result = await service.check()
        isBusy = false

        switch result {
        case .update(let release):
            // A version the user ignored stays quiet until the next one.
            if !manual, release.version.raw == skippedVersion() {
                state = .idle
                return
            }
            if case .ready(let staged) = state, staged == release.version {
                return
            }
            state = .available(release)
            notify(
                AppNotice(
                    kind: .info,
                    text: Lf("发现新版本 %@", release.version.raw),
                    actionTitle: L("查看更新说明"),
                    action: { [weak self] in self?.openReleasePage(release) }
                )
            )
            if mode == .automatic, release.installable != nil {
                await downloadAndStage(release, manual: false)
            }
        case .upToDate:
            state = .upToDate
            if manual {
                notify(AppNotice(kind: .success, text: Lf("已是最新版本 %@", currentVersion.raw)))
            }
        case .failed:
            state = .failed(.check)
            if manual {
                notify(
                    AppNotice(
                        kind: .warning,
                        text: L("无法检查更新，请稍后再试"),
                        actionTitle: L("重试"),
                        action: { [weak self] in
                            Task { @MainActor in await self?.check(manual: true) }
                        }
                    )
                )
            }
        }
    }

    // MARK: - Downloading and staging

    /// Download, verify, unpack, and remember where the new bundle sits. It is
    /// not applied here: the swap happens on quit, or when the user asks for
    /// it. A running app taking itself down mid-playback is the one thing an
    /// updater must never do.
    func downloadAndStage(_ release: UpdateRelease, manual: Bool) async {
        guard let asset = release.installable, let expected = asset.sha256 else {
            state = .available(release)
            return
        }
        guard !isBusy else { return }

        isBusy = true
        state = .downloading(release.version)
        do {
            let (downloaded, _) = try await session.download(from: asset.url)
            guard try UpdateInstaller.sha256(ofFileAt: downloaded) == expected.lowercased() else {
                throw Failure.checksum
            }

            let staging = updatesDirectory.appendingPathComponent("staging", isDirectory: true)
            let unpacked = try UpdateInstaller.unpack(downloaded, into: staging)

            let destination = updatesDirectory.appendingPathComponent(release.version.raw, isDirectory: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let stagedApp = destination.appendingPathComponent(unpacked.lastPathComponent)
            try FileManager.default.moveItem(at: unpacked, to: stagedApp)
            try? FileManager.default.removeItem(at: staging)

            writeMarker(at: stagedMarker, version: release.version)
            state = .ready(release.version)
            notify(
                AppNotice(
                    kind: .info,
                    text: Lf("%@ 已就绪，重启后生效", release.version.raw),
                    actionTitle: L("现在重启"),
                    action: { [weak self] in self?.restartToApply() }
                )
            )
        } catch {
            state = .failed(Self.failure(from: error))
            if manual {
                notify(AppNotice(kind: .warning, text: Self.failure(from: error).message))
            }
            // An automatic failure stays in settings: the user never asked for
            // this check and should not be interrupted by it.
        }
        isBusy = false
    }

    func installAvailable() async {
        guard let release = availableRelease else { return }
        await downloadAndStage(release, manual: true)
    }

    // MARK: - Applying

    /// Replace the bundle now and reopen.
    func restartToApply() {
        guard applyStaged(relaunch: true) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApplication.shared.terminate(nil)
        }
    }

    /// Called as the app quits: swap the bundle while it is closed, so the
    /// next launch is already the new build.
    func applyOnQuit() {
        _ = applyStaged(relaunch: false)
    }

    private func applyStaged(relaunch: Bool) -> Bool {
        guard let staged = readMarker(stagedMarker) else { return false }
        do {
            try UpdateInstaller.swapAfterQuit(
                newApp: staged.url,
                target: bundleURL,
                pid: ProcessInfo.processInfo.processIdentifier,
                staging: updatesDirectory,
                relaunch: relaunch
            )
            writeMarker(at: appliedMarker, version: staged.version)
            return true
        } catch {
            state = .failed(Self.failure(from: error))
            notify(AppNotice(kind: .warning, text: Self.failure(from: error).message))
            return false
        }
    }

    // MARK: - Ignoring a version

    func skip(_ release: UpdateRelease) {
        setSkippedVersion(release.version.raw)
        state = .idle
        notify(AppNotice(kind: .success, text: Lf("已忽略 %@，下个版本再提醒", release.version.raw)))
    }

    func clearSkippedVersion() {
        setSkippedVersion(nil)
    }

    func openReleasePage(_ release: UpdateRelease) {
        let fallback = URL(string: "https://github.com/y8gao/soundisle/releases/latest")
        guard let url = release.pageURL ?? fallback else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Markers

    private struct Marker {
        let version: AppVersion
        let url: URL
    }

    private func writeMarker(at url: URL, version: AppVersion) {
        try? FileManager.default.createDirectory(at: updatesDirectory, withIntermediateDirectories: true)
        // `path` is recorded next to the version so the staged bundle can be
        // found again after a relaunch that did not apply it.
        let payload: [String: String] = [
            "version": version.raw,
            "path": updatesDirectory
                .appendingPathComponent(version.raw, isDirectory: true)
                .appendingPathComponent("声屿.app")
                .path
        ]
        try? JSONSerialization.data(withJSONObject: payload).write(to: url)
    }

    /// `requiresExistingApp` guards the staged marker: a staged entry whose
    /// bundle is gone must not resurrect a "ready" pill. The applied marker is
    /// written just before the swap script deletes that directory, so its path
    /// never survives — it carries the version, not a promise about a file.
    private func readMarker(_ url: URL, requiresExistingApp: Bool = true) -> Marker? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let versionText = object["version"],
              let version = AppVersion(versionText),
              let path = object["path"]
        else { return nil }
        if requiresExistingApp, !FileManager.default.fileExists(atPath: path) { return nil }
        return Marker(version: version, url: URL(fileURLWithPath: path))
    }

    private func restoreStagedIfNeeded() {
        guard let staged = readMarker(stagedMarker) else { return }
        state = .ready(staged.version)
    }

    private func announceAppliedIfNeeded() {
        guard let applied = readMarker(appliedMarker, requiresExistingApp: false) else { return }
        try? FileManager.default.removeItem(at: appliedMarker)
        notify(
            AppNotice(
                kind: .success,
                text: Lf("更新已安装，这是 %@", applied.version.raw)
            )
        )
    }

    // MARK: - Errors

    private enum InstallFailure: Error {
        case checksum
        case unpack
    }

    private static func failure(from error: Error) -> Failure {
        if let failure = error as? Failure { return failure }
        if let installError = error as? UpdateInstaller.InstallError {
            switch installError {
            case .checksumMismatch: return .checksum
            case .unpackFailed: return .unpack
            case .notWritable(let path): return .notWritable(path)
            }
        }
        if case .checksum = (error as? InstallFailure) { return .checksum }
        return .unpack
    }
}
