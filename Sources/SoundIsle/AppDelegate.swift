import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel

    private var menuBar: MenuBarController?
    private var mediaKeys: MediaKeyController?
    private var miniPlayer: MiniPlayerWindowController?
    private var lyricsOverlay: LyricsOverlayWindowController?
    /// The SwiftUI window survives "closing" because `WindowConfigurator`
    /// hides it when `keepRunningOnClose` is on, so this stays valid.
    private weak var mainWindow: NSWindow?

    override init() {
        model = AppModel.production()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let miniPlayer = MiniPlayerWindowController(model: model)
        miniPlayer.onExpand = { [weak self] in self?.showMainWindow() }
        self.miniPlayer = miniPlayer
        model.miniPlayer = miniPlayer
        // Apply a persisted `showMainSpectrum` even when the mini starts hidden.
        model.refreshSpectrumConsumers()

        let lyricsOverlay = LyricsOverlayWindowController(model: model)
        lyricsOverlay.setLocked(model.isLyricsLocked)
        model.lyricsOverlay = lyricsOverlay
        self.lyricsOverlay = lyricsOverlay

        menuBar = MenuBarController(model: model, miniPlayer: miniPlayer) { [weak self] in
            self?.showMainWindow()
        }
        mediaKeys = MediaKeyController(model: model)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeMain(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        DispatchQueue.main.async { [weak self] in
            self?.captureMainWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !model.library.settings.keepRunningOnClose
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.savePlaybackState()
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindow ?? NSApp.windows.first(where: { isMainWindow($0) }) {
            mainWindow = window
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else {
            // SwiftUI owns window creation; its "New Window" command is the
            // only AppKit-safe way to ask for one on macOS 12.
            NSApp.sendAction(Selector(("newWindow:")), to: nil, from: nil)
        }
    }

    // MARK: - Main window tracking

    @objc private func windowDidBecomeMain(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, isMainWindow(window) else { return }
        mainWindow = window
    }

    private func captureMainWindow() {
        if let window = NSApp.windows.first(where: isMainWindow) {
            mainWindow = window
        }
    }

    private func isMainWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.canBecomeMain
    }
}
