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
    private static let controlsSize = NSSize(width: 148, height: 30)

    private let model: AppModel
    private let panel: NSPanel
    /// The locked overlay is fully click-through, so its hover affordance
    /// lives in a separate, deliberately tiny panel. Only that pill takes
    /// mouse events; the translucent area behind the lyrics stays transparent
    /// to clicks, drags and right-clicks meant for the app underneath.
    private let controlsPanel: NSPanel
    private(set) var isLocked = false
    private var hoverMonitors: [Any] = []

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
        // Text-only transparent windows can leave a stale window-shadow ghost
        // of the previous line when the lyric changes quickly. The glass
        // draws its own soft shadow, so the window shadow is not needed.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = Self.minSize
        panel.maxSize = Self.maxSize

        let controlsPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.controlsSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.controlsPanel = controlsPanel
        controlsPanel.isOpaque = false
        controlsPanel.backgroundColor = .clear
        controlsPanel.hasShadow = true
        controlsPanel.hidesOnDeactivate = false
        controlsPanel.level = .floating
        controlsPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        controlsPanel.isReleasedWhenClosed = false
        controlsPanel.animationBehavior = .none
        controlsPanel.becomesKeyOnlyIfNeeded = true
        controlsPanel.isMovableByWindowBackground = false

        let hosting = NSHostingView(rootView: LyricsOverlayView(model: model))
        hosting.frame = NSRect(origin: .zero, size: Self.defaultSize)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        let controlsHosting = NSHostingView(rootView: LockedLyricsControlsView(
            model: model,
            onMove: { [weak self] delta in self?.moveLyrics(by: delta) }
        ))
        controlsHosting.frame = NSRect(origin: .zero, size: Self.controlsSize)
        controlsPanel.contentView = controlsHosting

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
            refreshHoverMonitors()
            updateLockedControls()
            return
        }
        applySettings()
        ensureOnScreen()
        panel.orderFront(nil)
        refreshHoverMonitors()
        updateLockedControls()
    }

    func hide() {
        panel.orderOut(nil)
        setLockedControlsVisible(false)
        refreshHoverMonitors()
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
        // The lyrics window itself never takes clicks while locked; the pill
        // is the only interactive surface.
        panel.ignoresMouseEvents = locked
        refreshHoverMonitors()
        if locked {
            updateLockedControls()
        } else {
            setLockedControlsVisible(false)
        }
    }

    /// A locked overlay is click-through, so the view cannot see the pointer
    /// on its own. Both monitors are needed: local covers moves delivered to
    /// our windows, global covers moves over every other app. Hovering the
    /// lyrics reveals the tiny unlock/drag pill; nothing else is intercepted.
    private func refreshHoverMonitors() {
        let needed = isLocked && panel.isVisible
        if needed, hoverMonitors.isEmpty {
            let handler: (NSEvent) -> Void = { [weak self] _ in
                DispatchQueue.main.async { self?.updateLockedControls() }
            }
            if let local = NSEvent.addLocalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseUp],
                handler: { event in
                    handler(event)
                    return event
                }
            ) {
                hoverMonitors.append(local)
            }
            if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: handler) {
                hoverMonitors.append(global)
            }
        } else if !needed, !hoverMonitors.isEmpty {
            hoverMonitors.forEach(NSEvent.removeMonitor)
            hoverMonitors.removeAll()
        }
    }

    private func updateLockedControls() {
        guard isLocked, panel.isVisible else {
            setLockedControlsVisible(false)
            return
        }
        let margin: CGFloat = 4
        let inside = panel.frame.insetBy(dx: -margin, dy: -margin).contains(NSEvent.mouseLocation)
        if inside {
            setLockedControlsVisible(true)
        } else if NSEvent.pressedMouseButtons == 0 {
            // Keep the pill under a drag that briefly leaves the lyrics frame.
            setLockedControlsVisible(false)
        }
    }

    private func setLockedControlsVisible(_ visible: Bool) {
        guard visible, isLocked, panel.isVisible else {
            if controlsPanel.isVisible {
                controlsPanel.orderOut(nil)
            }
            model.setLyricsLockedBarVisible(false)
            return
        }
        model.setLyricsLockedBarVisible(true)
        layoutLockedControls()
        if !controlsPanel.isVisible {
            controlsPanel.orderFrontRegardless()
        }
    }

    private func layoutLockedControls() {
        guard panel.isVisible else { return }
        let size = Self.controlsSize
        // Match the unlocked bar: bottom-centre, 8pt above the window edge,
        // so locking swaps the full bar for this pill in the same spot.
        let x = min(
            max(panel.frame.midX - size.width / 2, panel.frame.minX + 6),
            panel.frame.maxX - size.width - 6
        )
        let y = panel.frame.minY + 8
        controlsPanel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func moveLyrics(by delta: CGSize) {
        guard delta != .zero else { return }
        var frame = panel.frame
        frame.origin.x += delta.width
        frame.origin.y += delta.height
        panel.setFrame(frame, display: true)
        layoutLockedControls()
    }

    // MARK: - Frame

    func applySettings() {
        let settings = model.library.settings
        panel.level = .floating
        panel.sharingType = settings.hideFromScreenCapture ? .none : .readOnly
        controlsPanel.sharingType = settings.hideFromScreenCapture ? .none : .readOnly
        isLocked = model.isLyricsLocked
        panel.ignoresMouseEvents = isLocked
        refreshHoverMonitors()
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
        guard panel.isVisible else {
            setLockedControlsVisible(false)
            return
        }
        saveFrame()
        layoutLockedControls()
    }

    private func saveFrame() {
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameDefaultsKey)
    }
}
