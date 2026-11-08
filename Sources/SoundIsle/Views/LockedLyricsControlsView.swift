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

    private func pillButton(
        _ symbol: String,
        size: CGFloat = 11,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Icons.symbol(symbol, size: size)
                .foregroundColor(palette.text.opacity(0.85))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var divider: some View {
        Rectangle()
            .fill(palette.hairline)
            .frame(width: 0.5, height: 14)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Lock sits first, in the same place as the unlocked bar. The
            // closed lock shows the current state; clicking unlocks.
            pillButton("lock.fill", size: 12, help: L("解锁歌词")) {
                model.setLyricsLocked(false)
            }

            divider

            // Playback stays reachable while the overlay is click-through.
            pillButton("backward.end", help: L("上一首")) { model.previous() }
            Button {
                model.togglePlayPause()
            } label: {
                Icons.symbol(model.isPlaying ? "pause.fill" : "play.fill", size: 11)
                    .foregroundColor(palette.onAccent)
                    .frame(width: 24, height: 24)
                    .background(palette.accent, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(model.isPlaying ? L("暂停") : L("播放"))
            .padding(.horizontal, 2)
            pillButton("forward.end", help: L("下一首")) { model.next() }

            PillHandle(
                cursor: .openHand,
                icon: "arrow.up.and.down.and.arrow.left.and.right",
                help: L("拖动歌词"),
                onDrag: onMove
            )
        }
        .padding(.horizontal, 3)
        .frame(width: 148, height: 30)
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

/// A pill-sized drag target. The same shape moves the window or resizes it,
/// so locked lyrics keep both affordances without the transparent area
/// catching clicks meant for the app behind.
private struct PillHandle: View {
    let cursor: NSCursor
    let icon: String
    let help: String
    let onDrag: (CGSize) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        PillHandleView(cursor: cursor, onDrag: onDrag)
            .frame(width: 28, height: 28)
            .overlay(
                Icons.symbol(icon, size: 10)
                    .foregroundColor(theme.text.opacity(0.7))
                    .allowsHitTesting(false)
            )
            .help(help)
    }
}

private struct PillHandleView: NSViewRepresentable {
    let cursor: NSCursor
    let onDrag: (CGSize) -> Void

    final class HandleView: NSView {
        var onMove: ((CGSize) -> Void)?
        var cursor: NSCursor = .openHand
        private var lastLocation: NSPoint?

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: cursor)
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
        view.onMove = onDrag
        view.cursor = cursor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? HandleView)?.onMove = onDrag
        (nsView as? HandleView)?.cursor = cursor
    }
}
