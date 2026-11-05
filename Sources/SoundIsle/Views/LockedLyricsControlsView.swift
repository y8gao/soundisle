import AppKit
import SoundIsleCore
import SwiftUI

/// The only interactive surface while desktop lyrics are locked. It floats in
/// its own tiny panel so the lyrics window can stay completely click-through:
/// hovering the lyrics reveals this pill, but clicks on the transparent area
/// still reach whatever is behind the lyrics.
struct LockedLyricsControlsView: View {
    @ObservedObject var model: AppModel
    let onMove: (CGSize) -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ThemePalette {
        let settings = model.library.settings
        return ThemePalette.resolve(
            preset: settings.preset,
            mode: settings.mode,
            customAccentHex: settings.customAccentHex,
            systemIsDark: colorScheme == .dark
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                model.setLyricsLocked(false)
            } label: {
                Icons.symbol("lock.open", size: 12)
                    .foregroundColor(palette.text.opacity(0.85))
                    .frame(width: 30, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("解锁歌词"))

            PillDragHandle(onMove: onMove)
                .frame(width: 30, height: 28)
                .overlay(
                    Icons.symbol("arrow.up.and.down.and.arrow.left.and.right", size: 10)
                        .foregroundColor(palette.text.opacity(0.7))
                        .allowsHitTesting(false)
                )
                .help(L("拖动歌词"))
        }
        .padding(.horizontal, 2)
        .frame(width: 64, height: 30)
        .background {
            // A blurred, half-transparent capsule keeps the icons legible on
            // black, white and busy backgrounds without becoming a solid bar.
            ZStack {
                MaterialBackdrop(material: palette.isDark ? .hudWindow : .popover)
                palette.panelTint.opacity(0.58)
            }
            .clipShape(Capsule(style: .continuous))
        }
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(palette.hairline, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
        .soundIsleTheme(palette)
    }
}

/// Drags the lyrics window itself while the pointer is on the pill. The pill
/// then follows through the controller, so both move as one unit.
private struct PillDragHandle: NSViewRepresentable {
    let onMove: (CGSize) -> Void

    final class HandleView: NSView {
        var onMove: ((CGSize) -> Void)?
        private var lastLocation: NSPoint?

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            lastLocation = NSEvent.mouseLocation
        }

        override func mouseDragged(with event: NSEvent) {
            let current = NSEvent.mouseLocation
            guard let previous = lastLocation else {
                lastLocation = current
                return
            }
            lastLocation = current
            onMove?(CGSize(width: current.x - previous.x, height: current.y - previous.y))
        }

        override func mouseUp(with event: NSEvent) {
            lastLocation = nil
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = HandleView()
        view.onMove = onMove
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? HandleView)?.onMove = onMove
    }
}
