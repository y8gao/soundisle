import AppKit
import SwiftUI

/// The borderless, always-on-top lyrics panel. It is a plain view of
/// `AppModel.isLyricsVisible` / `isLyricsLocked`: the menu bar, the main window
/// and the overlay's own controls all go through the model so nothing drifts.
@MainActor
final class LyricsOverlayWindowController {
    static let minSize = NSSize(width: 280, height: 70)
    static let maxSize = NSSize(width: 1200, height: 420)

    private static let defaultSize = NSSize(width: 560, height: 120)
    private static let frameDefaultsKey = "lyricsOverlayFrame"

    private let model: AppModel
    private let panel: NSPanel
    private(set) var isLocked = false

    init(model: AppModel) {
        self.model = model

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.panel = panel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = Self.minSize
        panel.maxSize = Self.maxSize

        let hosting = NSHostingView(rootView: LyricsOverlayView(model: model) { [weak self] delta in
            self?.resizeWidth(by: delta)
        })
        hosting.frame = NSRect(origin: .zero, size: Self.defaultSize)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        panel.setFrame(restoredFrame(), display: false)
        isLocked = model.isLyricsLocked
        panel.ignoresMouseEvents = isLocked

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(frameDidChange(_:)),
            name: NSWindow.didMoveNotification,
            object: panel
        )
        center.addObserver(
            self,
            selector: #selector(frameDidChange(_:)),
            name: NSWindow.didResizeNotification,
            object: panel
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Visibility and lock

    func show() {
        guard !panel.isVisible else {
            panel.orderFront(nil)
            return
        }
        applySettings()
        ensureOnScreen()
        panel.orderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    func setVisible(_ visible: Bool) {
        if visible {
            show()
        } else {
            hide()
        }
    }

    func setLocked(_ locked: Bool) {
        isLocked = locked
        panel.ignoresMouseEvents = locked
    }

    // MARK: - Frame

    /// A−/A+ change the window width; the font always derives from it.
    func resizeWidth(by delta: CGFloat) {
        var frame = panel.frame
        let width = min(max(frame.width + delta, Self.minSize.width), Self.maxSize.width)
        guard width != frame.width else { return }
        frame.origin.x -= (width - frame.width) / 2
        frame.size.width = width
        panel.setFrame(frame, display: true)
        saveFrame()
    }

    func applySettings() {
        let settings = model.library.settings
        panel.level = .floating
        panel.sharingType = settings.hideFromScreenCapture ? .none : .readOnly
        panel.ignoresMouseEvents = model.isLyricsLocked
        isLocked = model.isLyricsLocked
    }

    private func restoredFrame() -> NSRect {
        guard let saved = UserDefaults.standard.string(forKey: Self.frameDefaultsKey) else {
            return defaultFrame()
        }
        var frame = NSRectFromString(saved)
        guard frame.width >= Self.minSize.width,
              frame.height >= Self.minSize.height,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else {
            return defaultFrame()
        }
        frame.size.width = min(frame.width, Self.maxSize.width)
        frame.size.height = min(frame.height, Self.maxSize.height)
        return frame
    }

    private func defaultFrame() -> NSRect {
        guard let visible = NSScreen.main?.visibleFrame else {
            return NSRect(origin: .zero, size: Self.defaultSize)
        }
        return NSRect(
            x: visible.midX - Self.defaultSize.width / 2,
            y: visible.minY + 90,
            width: Self.defaultSize.width,
            height: Self.defaultSize.height
        )
    }

    private func ensureOnScreen() {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(panel.frame) })
            ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.size.width = min(max(frame.width, Self.minSize.width), min(Self.maxSize.width, visible.width))
        frame.size.height = min(max(frame.height, Self.minSize.height), min(Self.maxSize.height, visible.height))
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        panel.setFrame(frame, display: false)
    }

    @objc private func frameDidChange(_ notification: Notification) {
        guard panel.isVisible else { return }
        saveFrame()
    }

    private func saveFrame() {
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameDefaultsKey)
    }
}
