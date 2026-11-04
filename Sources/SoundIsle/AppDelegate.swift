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

        menuBar = MenuBarController(
            model: model,
            miniPlayer: miniPlayer,
            showMainWindow: { [weak self] in self?.showMainWindow() },
            showMiniPlayer: { [weak self] in self?.showMiniPlayer() }
        )
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
        // SwiftUI installs its default menus after launch; trim once the menu
        // has settled and again on activation as a safety net.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.trimMainMenu()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.trimMainMenu()
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

    /// Main window and mini player are mutually exclusive: whichever is
    /// summoned hides the other. Closing still honors `keepRunningOnClose`
    /// because `WindowConfigurator` hides rather than destroys the window.
    func showMainWindow() {
        miniPlayer?.hide()
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindow ?? NSApp.windows.first(where: { isMainWindow($0) }) {
            mainWindow = window
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            model.clearSearchFocus()
            // SwiftUI can restore the search field as first responder when a
            // window becomes key; clear it after the window settles.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                window.makeFirstResponder(nil)
                self.model.clearSearchFocus()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                window.makeFirstResponder(nil)
                self?.model.clearSearchFocus()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.trimMainMenu()
            }
        } else {
            // SwiftUI owns window creation; its "New Window" command is the
            // only AppKit-safe way to ask for one on macOS 12.
            NSApp.sendAction(Selector(("newWindow:")), to: nil, from: nil)
        }
    }

    /// Mini mode: order the main window out (without closing it) and float the
    /// mini player. Returning to the main window goes through `showMainWindow`.
    func showMiniPlayer() {
        model.clearSearchFocus()
        NSApp.windows.filter { isMainWindow($0) }.forEach { $0.makeFirstResponder(nil) }
        model.showMiniPlayer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.trimMainMenu()
        }
    }

    /// SwiftUI's default File/Edit/View/Window/Help menus are noise for this
    /// player. Keep the app menu plus the custom 播放/歌词/整理 menus.
    private func trimMainMenu() {
        let unwanted: Set<String> = ["File", "Edit", "View", "Window", "Help"]
        NSApp.mainMenu?.items.removeAll { unwanted.contains($0.title) }
    }

    // MARK: - Main window tracking

    @objc private func windowDidBecomeMain(_ notification: Notification) {
        if let window = notification.object as? NSWindow, isMainWindow(window) {
            mainWindow = window
            // Returning from mini mode can restore the search field as first
            // responder; explicitly resign it so playback shortcuts keep working.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                window.makeFirstResponder(nil)
                self?.model.clearSearchFocus()
            }
        }
        // Any window becoming key (main or mini) can make SwiftUI rebuild its
        // default menus; trim after it settles. No menu observer here — that
        // caused a rebuild loop.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.trimMainMenu()
        }
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
