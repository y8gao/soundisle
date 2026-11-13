import AppKit
import SwiftUI

// MARK: - Themed menu

/// The app's own context menu. macOS draws a system menu in the system
/// appearance with the system accent colour, and gives an app no say in
/// either, so a native menu next to the track list's themed one looked like
/// two different programs. The window builds every menu from these pieces
/// instead: one panel, one accent hover, both following the app's theme and
/// light/dark setting.
struct ThemedMenuPanel<Content: View>: View {
    @Environment(\.theme) private var theme
    var width: CGFloat = 240
    let content: Content

    init(width: CGFloat = 240, @ViewBuilder content: () -> Content) {
        self.width = width
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 1) {
            content
        }
        .padding(5)
        .frame(width: width)
        // One panel, one edge. Three things were stacking up here: a frosted
        // material, a hairline border, and a 16pt shadow offset 6pt down —
        // and the wide offset shadow drew a second, grey rounded rectangle
        // outside the border, so the menu looked like two menus. The surface
        // is opaque now and the shadow only just clears the edge.
        .background(theme.panelTint, in: shape)
        .overlay(shape.strokeBorder(theme.hairline.opacity(0.7), lineWidth: 0.5))
        .shadow(color: .black.opacity(theme.isDark ? 0.45 : 0.16), radius: 5, y: 2)
    }
}

/// One row. The pointer both highlights it in the accent colour and is the
/// only thing that does, so the panel stays quiet until it is used.
struct ThemedMenuAction: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let symbol: String
    let title: String
    var isEnabled = true
    let run: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            // Close first: several of these open a sheet or a dialog, and a
            // menu still on screen swallows it. `dismiss` covers the one
            // panel that is still a popover (the lyrics source badge).
            ThemedMenuCenter.shared.dismiss()
            dismiss()
            run()
        } label: {
            HStack(spacing: 8) {
                Icons.symbol(symbol, size: 11)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundColor(theme.text.opacity(isEnabled ? 0.9 : 0.35))
            .padding(.horizontal, 8)
            .frame(height: 27)
            .background(
                isHovering && isEnabled ? theme.accent.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
    }
}

struct ThemedMenuSeparator: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.hairline)
            .frame(height: 1)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
    }
}

struct ThemedMenuHeader: View {
    @Environment(\.theme) private var theme
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundColor(theme.mutedText(0.42))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
    }
}

// MARK: - Presentation

/// Holds the one menu that is open. It has to be drawn above the list: a menu
/// inside the row it belongs to is clipped by the scroll view, and a popover
/// cannot be placed at the pointer at all — a popover anchors to the layout
/// frame of a view, and neither `position` nor `offset` moves that frame, so
/// the menu opened at the top of the column instead of under the click.
final class ThemedMenuCenter: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        /// Window content coordinates, top-left origin.
        let anchor: CGPoint
        let width: CGFloat
        let content: AnyView
    }

    static let shared = ThemedMenuCenter()

    @Published var request: Request?

    func dismiss() {
        request = nil
    }
}

extension View {
    /// Right-click menu at the pointer. See `ThemedMenuHost`.
    func themedContextMenu<MenuContent: View>(
        width: CGFloat = 240,
        @ViewBuilder content: @escaping () -> MenuContent
    ) -> some View {
        modifier(ThemedContextMenu(width: width, content: content))
    }
}

private struct ThemedContextMenu<MenuContent: View>: ViewModifier {
    let width: CGFloat
    let content: () -> MenuContent

    func body(content base: Content) -> some View {
        base.overlay {
            RightClickCatcher { point, origin, _ in
                // Only the content: the host wraps it in the panel. Wrapping
                // here as well drew two panels, one inset inside the other —
                // the "grey edge that looks like a second menu".
                ThemedMenuCenter.shared.request = ThemedMenuCenter.Request(
                    anchor: CGPoint(x: origin.x + point.x, y: origin.y + point.y),
                    width: width,
                    content: AnyView(content())
                )
            }
        }
    }
}

/// Draws the open menu for the whole window: the panel at the pointer, a
/// shield that takes the click-away, and Esc. Put it on the window's root.
struct ThemedMenuHost: View {
    @ObservedObject var center = ThemedMenuCenter.shared

    @State private var panelSize = CGSize.zero
    @State private var keyMonitor: Any?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let request = center.request {
                    // The panel is an ordinary view, so something has to take
                    // the click that dismisses it — and a right-click counts
                    // as much as a left one. Without this a right-click
                    // elsewhere did nothing at all: neither closing this menu
                    // nor opening the one under the pointer.
                    Rectangle()
                        .fill(Color.black.opacity(0.001))
                        .onTapGesture { center.dismiss() }
                        .overlay {
                            RightClickCatcher(isShield: true) { _, _, _ in
                                center.dismiss()
                            }
                        }

                    ThemedMenuPanel(width: request.width) { request.content }
                        .background(sizeReader)
                        .offset(x: origin(of: request, in: proxy.size).x,
                                y: origin(of: request, in: proxy.size).y)
                        .zIndex(1)
                }
            }
        }
        .onChange(of: center.request?.id) { _ in
            keyMonitor.map(NSEvent.removeMonitor)
            keyMonitor = center.request == nil
                ? nil
                : NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.keyCode == 53 else { return event }   // Esc
                    center.dismiss()
                    return nil
                }
        }
    }

    private var sizeReader: some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear { panelSize = geometry.size }
                .onChange(of: geometry.size) { panelSize = $0 }
        }
    }

    /// At the pointer, pulled back inside the window when the panel would
    /// otherwise hang off the right edge or the bottom.
    private func origin(of request: ThemedMenuCenter.Request, in window: CGSize) -> CGPoint {
        var x = request.anchor.x
        var y = request.anchor.y
        if x + panelSize.width > window.width - 4 {
            x = request.anchor.x - panelSize.width
        }
        if y + panelSize.height > window.height - 4 {
            y = request.anchor.y - panelSize.height
        }
        return CGPoint(x: max(4, x), y: max(4, y))
    }
}

// MARK: - Right-click plumbing

/// Claims right-clicks without stealing anything else. AppKit asks `hitTest`
/// while dispatching an event, so returning nil for every non-right-mouse
/// event leaves SwiftUI's tap, hover and drag gestures untouched. It reports
/// the click in this view's coordinates plus where this view sits in the
/// window, so the host can place the panel in window space.
struct RightClickCatcher: NSViewRepresentable {
    /// The open menu's full-window shield: what it reports it also passes on
    /// to the catcher underneath, which is what makes a single right-click
    /// close this menu and open the one under the pointer, the way Finder
    /// behaves. Every other catcher just reports.
    var isShield = false
    let onRightClick: (CGPoint, CGPoint, CGSize) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CatcherView()
        view.isShield = isShield
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onRightClick = onRightClick
    }

    private final class CatcherView: NSView {
        var isShield = false
        var onRightClick: ((CGPoint, CGPoint, CGSize) -> Void)?

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return super.hitTest(point)
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            guard isShield else {
                open(with: event)
                return
            }
            open(with: event)
            forward(event)
        }

        func open(with event: NSEvent) {
            guard let window, let content = window.contentView else { return }
            let local = convert(event.locationInWindow, from: nil)
            let inContent = convert(bounds, to: content)
            // SwiftUI's root sits in the window's content *layout*, below the
            // title bar, so the origin has to be measured from there: from
            // the content view's top every menu landed one title bar too low.
            let layout = content.convert(window.contentLayoutRect, from: nil)
            let size = layout.size
            let origin = content.isFlipped
                ? CGPoint(x: inContent.minX - layout.minX, y: inContent.minY - layout.minY)
                : CGPoint(x: inContent.minX - layout.minX, y: layout.maxY - inContent.maxY)
            onRightClick?(local, origin, size)
        }

        /// Front-most catcher under the pointer, ignoring this shield.
        private func forward(_ event: NSEvent) {
            guard let root = window?.contentView else { return }
            for view in Self.catchers(in: root) where view !== self && !view.isShield {
                if view.bounds.contains(view.convert(event.locationInWindow, from: nil)) {
                    view.open(with: event)
                    return
                }
            }
        }

        private static func catchers(in view: NSView) -> [CatcherView] {
            var found: [CatcherView] = []
            for sub in view.subviews.reversed() {
                if let catcher = sub as? CatcherView { found.append(catcher) }
                found.append(contentsOf: catchers(in: sub))
            }
            return found
        }
    }
}
