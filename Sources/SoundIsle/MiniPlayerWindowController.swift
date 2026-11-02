import AppKit
import SwiftUI

/// The 520x66 floating capsule. It lives on every Space and never activates
/// the app, so it can sit in a corner while another app has focus.
@MainActor
final class MiniPlayerWindowController {
    static let size = NSSize(width: 520, height: 66)

    private static let originXKey = "miniPlayerOriginX"
    private static let originYKey = "miniPlayerOriginY"

    private let model: AppModel
    private let panel: NSPanel
    /// Called by the expand button after the mini window hides.
    var onExpand: (() -> Void)?

    var isVisible: Bool { panel.isVisible }

    init(model: AppModel) {
        self.model = model

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: MiniPlayerView(model: model) { [weak self] in
            self?.expand()
        })
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidMove(_:)),
            name: NSWindow.didMoveNotification,
            object: panel
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Visibility

    func show() {
        guard !panel.isVisible else {
            panel.orderFront(nil)
            return
        }
        applySettings()
        panel.setFrameOrigin(restoredOrigin())
        updateSpectrum()
        panel.orderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
        updateSpectrum()
    }

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func expand() {
        hide()
        updateSpectrum()
        onExpand?()
    }

    // MARK: - Settings

    private func applySettings() {
        let settings = model.library.settings
        panel.level = settings.miniAlwaysOnTop ? .floating : .normal
        panel.sharingType = settings.hideFromScreenCapture ? .none : .readOnly
    }

    private func updateSpectrum() {
        // The tap is opt-in; keep it on if the main window's spectrum is also
        // enabled (Task 14), otherwise it follows the mini window.
        model.engine.isSpectrumEnabled = panel.isVisible || model.library.settings.showMainSpectrum
    }

    // MARK: - Position

    private func restoredOrigin() -> NSPoint {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.originXKey) != nil else {
            return defaultOrigin()
        }
        let saved = NSPoint(
            x: defaults.double(forKey: Self.originXKey),
            y: defaults.double(forKey: Self.originYKey)
        )
        guard let frame = screen(containing: saved)?.visibleFrame else { return saved }
        return NSPoint(
            x: min(max(saved.x, frame.minX), frame.maxX - Self.size.width),
            y: min(max(saved.y, frame.minY), frame.maxY - Self.size.height)
        )
    }

    private func defaultOrigin() -> NSPoint {
        guard let frame = NSScreen.main?.visibleFrame else { return .zero }
        return NSPoint(
            x: frame.maxX - Self.size.width - 20,
            y: frame.maxY - Self.size.height - 20
        )
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.visibleFrame.contains(point) } ?? NSScreen.main
    }

    @objc private func panelDidMove(_ notification: Notification) {
        guard panel.isVisible else { return }
        let origin = panel.frame.origin
        let defaults = UserDefaults.standard
        defaults.set(origin.x, forKey: Self.originXKey)
        defaults.set(origin.y, forKey: Self.originYKey)
    }
}
