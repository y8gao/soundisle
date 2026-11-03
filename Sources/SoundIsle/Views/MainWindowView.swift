import AppKit
import SoundIsleCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Main window

struct MainWindowView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    @FocusState private var searchFocused: Bool
    @State private var isDropTargeted = false

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
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 0) {
                SidebarView(model: model)
                    .frame(width: 190)
                ZStack {
                    if model.showsLyricsPage {
                        NowPlayingLyricsView(model: model)
                            .transition(.asymmetric(
                                insertion: .move(edge: .bottom).combined(with: .opacity),
                                removal: .opacity
                            ))
                    } else {
                        TrackListView(model: model)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
            PlayerBarView(model: model)
                .frame(height: 84)
        }
        .background(AppBackground())
        .soundIsleTheme(palette)
        .overlay(dropOverlay)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
            return true
        }
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
            SettingsView(model: model)
        }
        .sheet(item: $model.tagEditorRequest) { request in
            TagEditorView(model: model, tracks: request.tracks)
        }
        .sheet(item: $model.organizerRequest) { request in
            OrganizerPreviewView(model: model, tracks: request.tracks)
        }
    }

    private var topBar: some View {
        ZStack {
            WindowDragArea()
            HStack(spacing: 12) {
                Text("声屿")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(palette.text.opacity(0.8))

                Spacer(minLength: 12)

                HStack(spacing: 6) {
                    Icons.search
                        .foregroundColor(palette.mutedText(0.45))
                    TextField("搜索歌曲、歌手、专辑", text: $model.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundColor(palette.text)
                        .focused($searchFocused)
                }
                .padding(.horizontal, 9)
                .frame(width: 220, height: 26)
                .background(palette.raisedFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(palette.hairline, lineWidth: 0.5)
                )

                Button {
                    model.isSettingsPresented = true
                } label: {
                    Icons.settings
                        .foregroundColor(palette.text.opacity(0.7))
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
        .background(palette.raisedFill.opacity(0.24))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var dropOverlay: some View {
        if isDropTargeted {
            ZStack {
                palette.playerTint.opacity(0.55).ignoresSafeArea()
                VStack(spacing: 10) {
                    Icons.dropImport
                        .foregroundColor(palette.accent)
                    Text("松开以导入")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(palette.text)
                    Text("文件夹会递归扫描，单个文件会导入所在文件夹")
                        .font(.system(size: 11))
                        .foregroundColor(palette.mutedText(0.55))
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
            // Clear so `AppBackground`'s under-window material shows the
            // desktop through the glass. Text contrast comes from its tint.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
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
