import AppKit
import SoundIsleCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Theme

/// Deep-space blue, dark skin. Task 14 replaces this with real theme presets.
enum Theme {
    static let text = Color(red: 237 / 255, green: 240 / 255, blue: 250 / 255)
    static let accent = Color(red: 122 / 255, green: 162 / 255, blue: 255 / 255)
    static let accentLight = Color(red: 205 / 255, green: 221 / 255, blue: 255 / 255)
    static let warning = Color(red: 255 / 255, green: 183 / 255, blue: 102 / 255)
    static let panelTint = Color(red: 20 / 255, green: 24 / 255, blue: 36 / 255)
    static let playerTint = Color(red: 10 / 255, green: 13 / 255, blue: 22 / 255)

    static let accentGradient = LinearGradient(
        colors: [accent, Color(red: 181 / 255, green: 140 / 255, blue: 255 / 255)],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let coverGradient = LinearGradient(
        colors: [
            Color(red: 77 / 255, green: 107 / 255, blue: 216 / 255),
            Color(red: 143 / 255, green: 91 / 255, blue: 217 / 255),
            Color(red: 196 / 255, green: 91 / 255, blue: 142 / 255),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 18 / 255, green: 21 / 255, blue: 33 / 255),
                    Color(red: 27 / 255, green: 33 / 255, blue: 50 / 255),
                    Color(red: 22 / 255, green: 27 / 255, blue: 40 / 255),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color(red: 88 / 255, green: 122 / 255, blue: 255 / 255).opacity(0.42), .clear],
                center: UnitPoint(x: 0.12, y: 0.05),
                startRadius: 0,
                endRadius: 480
            )
            RadialGradient(
                colors: [Color(red: 214 / 255, green: 96 / 255, blue: 168 / 255).opacity(0.24), .clear],
                center: UnitPoint(x: 0.88, y: 0.22),
                startRadius: 0,
                endRadius: 420
            )
            RadialGradient(
                colors: [Color(red: 45 / 255, green: 190 / 255, blue: 160 / 255).opacity(0.20), .clear],
                center: UnitPoint(x: 0.55, y: 1.05),
                startRadius: 0,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Frosted panel: material blurs what is behind, a translucent tint gives
    /// the deep-blue cast, and a hairline border catches the light.
    func glassPanel(cornerRadius: CGFloat = 12) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(Theme.panelTint.opacity(0.55), in: shape)
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
    }
}

// MARK: - Main window

struct MainWindowView: View {
    @ObservedObject var model: AppModel

    @FocusState private var searchFocused: Bool
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 0) {
                SidebarView(model: model)
                    .frame(width: 190)
                TrackListView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            PlayerBarView(model: model)
                .frame(height: 76)
        }
        .background(AppBackground())
        .overlay(dropOverlay)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .preferredColorScheme(.dark)
        .background(WindowConfigurator(model: model))
        .onAppear { model.start() }
        .onChange(of: model.searchFocusRequest) { _ in
            searchFocused = true
        }
        .onChange(of: searchFocused) { focused in
            model.isSearchFocused = focused
        }
        .onChange(of: model.endSearchFocusRequest) { _ in
            searchFocused = false
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .onChange(of: model.isSettingsPresented) { presented in
            if !presented {
                searchFocused = false
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            model.savePlaybackState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.savePlaybackState()
        }
        .sheet(isPresented: $model.isSettingsPresented) {
            SettingsView()
        }
    }

    private var topBar: some View {
        ZStack {
            WindowDragArea()
            HStack(spacing: 12) {
                Text("声屿")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.text.opacity(0.8))

                Spacer(minLength: 12)

                HStack(spacing: 6) {
                    Icons.search
                        .foregroundColor(Theme.text.opacity(0.45))
                    TextField("搜索歌曲、歌手、专辑", text: $model.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.text)
                        .focused($searchFocused)
                }
                .padding(.horizontal, 9)
                .frame(width: 220, height: 26)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )

                Button {
                    model.isSettingsPresented = true
                } label: {
                    Icons.settings
                        .foregroundColor(Theme.text.opacity(0.7))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("设置")
            }
        }
        // Leave room for the traffic lights of the hidden title bar.
        .padding(.leading, 78)
        .padding(.trailing, 16)
        .frame(height: 46)
        .background(Color.white.opacity(0.015))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var dropOverlay: some View {
        if isDropTargeted {
            ZStack {
                Theme.playerTint.opacity(0.55).ignoresSafeArea()
                VStack(spacing: 10) {
                    Icons.dropImport
                        .foregroundColor(Theme.accent)
                    Text("松开以导入")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.text)
                    Text("文件夹会递归扫描，单个文件会导入所在文件夹")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.text.opacity(0.55))
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 24)
                .glassPanel(cornerRadius: 16)
            }
            .allowsHitTesting(false)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await provider.fileURLValue() {
                    urls.append(url)
                }
            }
            model.importFolders(urls)
        }
    }
}

extension NSItemProvider {
    /// Track rows drag their track ID as plain text; sidebar playlists and
    /// playlist rows accept it.
    func textValue() async -> String? {
        await withCheckedContinuation { continuation in
            loadItem(forTypeIdentifier: UTType.utf8PlainText.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let text = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: text)
                } else if let text = item as? String {
                    continuation.resume(returning: text)
                } else if let text = item as? NSString {
                    continuation.resume(returning: text as String)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func fileURLValue() async -> URL? {
        await withCheckedContinuation { continuation in
            loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let url = item as? NSURL {
                    continuation.resume(returning: url as URL)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - Window dragging

/// The frameless window is dragged from the top bar only, so track rows stay
/// free to begin playlist drag sessions. The mini player reuses it too.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Window configuration

/// Sets the 900x600 launch size, hides the title text, makes the top bar
/// draggable, and parks the window instead of destroying it when the user
/// closes it while "关闭后继续运行" is on.
private struct WindowConfigurator: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        let model: AppModel
        weak var originalDelegate: NSWindowDelegate?

        init(model: AppModel) {
            self.model = model
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard model.library.settings.keepRunningOnClose else { return true }
            sender.orderOut(nil)
            return false
        }

        /// Keep SwiftUI's own window delegate working for every other
        /// callback by forwarding what this coordinator does not implement.
        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (originalDelegate?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if let originalDelegate, originalDelegate.responds(to: aSelector) {
                return originalDelegate
            }
            return super.forwardingTarget(for: aSelector)
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // Rows must be able to start drag sessions; whole-window background
            // dragging swallowed those gestures. The top bar carries its own
            // drag area instead.
            window.isMovableByWindowBackground = false
            window.backgroundColor = NSColor(
                calibratedRed: 18 / 255,
                green: 21 / 255,
                blue: 33 / 255,
                alpha: 1
            )
            window.minSize = NSSize(width: 900, height: 600)
            window.setContentSize(NSSize(width: 900, height: 600))
            window.center()
            // Keep the search field from grabbing first responder at launch;
            // space and arrow keys belong to playback until search is clicked.
            window.initialFirstResponder = nil
            window.makeFirstResponder(nil)
            coordinator.originalDelegate = window.delegate
            window.delegate = coordinator
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
