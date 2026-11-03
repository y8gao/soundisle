import AppKit
import SoundIsleCore
import SwiftUI

/// The lyric glass. Font size comes only from the window width, so dragging an
/// edge scales the text; the overlay never stores its own font size.
struct LyricsOverlayView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    let onResize: (CGFloat) -> Void

    @State private var isHovering = false
    @State private var opacity: Double
    @State private var outline: Bool
    @State private var lineMode: String

    init(model: AppModel, onResize: @escaping (CGFloat) -> Void) {
        self.model = model
        self.onResize = onResize
        let settings = model.library.settings
        _opacity = State(initialValue: settings.lyricsOpacity)
        _outline = State(initialValue: settings.lyricsOutline)
        _lineMode = State(initialValue: settings.lyricsLineMode)
    }

    private var palette: ThemePalette {
        let settings = model.library.settings
        return ThemePalette.resolve(
            preset: settings.preset,
            mode: settings.mode,
            customAccentHex: settings.customAccentHex,
            systemIsDark: colorScheme == .dark
        )
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    /// The desktop overlay is text-only until the user hovers it. Locking
    /// makes the panel click-through, so the glass must never appear then.
    private var showsHoverChrome: Bool {
        isHovering && !model.isLyricsLocked
    }

    private var hoverBackground: some View {
        ZStack {
            MaterialBackdrop(material: palette.isDark ? .hudWindow : .popover)
            palette.playerTint.opacity(max(0.28, opacity))
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(palette.hairline, lineWidth: 1))
    }

    var body: some View {
        GeometryReader { proxy in
            let fontSize = LyricsFont.size(forWidth: proxy.size.width)
            ZStack {
                hoverBackground
                    .opacity(showsHoverChrome ? 1 : 0)
                    .allowsHitTesting(false)
                WindowDragArea()
                content(fontSize: fontSize)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)

                if !model.isLyricsLocked {
                    controls
                    resizeGrip
                }
            }
            .clipShape(shape)
            .contentShape(shape)
            .contextMenu { lyricsMenu }
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.18), value: showsHoverChrome)
        }
        .soundIsleTheme(palette)
        .onChange(of: model.library.settings.lyricsOpacity) { opacity = $0 }
        .onChange(of: model.library.settings.lyricsOutline) { outline = $0 }
        .onChange(of: model.library.settings.lyricsLineMode) { lineMode = $0 }
    }

    // MARK: - Lyrics

    @ViewBuilder
    private func content(fontSize: CGFloat) -> some View {
        if let lyrics = model.lyrics, !lyrics.lines.isEmpty {
            if lyrics.isSynced {
                VStack(spacing: fontSize * 0.30) {
                    lyricText(
                        model.currentLyricText ?? "",
                        size: fontSize,
                        weight: .semibold
                    )
                    .lineLimit(2)

                    if lineMode == "two",
                       let next = model.nextLyricText,
                       !next.isEmpty {
                        lyricText(
                            next,
                            size: fontSize * 0.55,
                            weight: .regular,
                            emphasis: 0.72
                        )
                        .lineLimit(1)
                    }
                }
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: fontSize * 0.25) {
                        ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { _, line in
                            lyricText(
                                line.text,
                                size: fontSize * 0.7,
                                weight: .regular,
                                emphasis: 0.72
                            )
                        }
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                }
                // Plain (unsynced) lyrics are long: let the user scroll this
                // text while still dragging the rest of the window. Synced
                // lyrics and the locked overlay stay click-through.
                .allowsHitTesting(!model.isLyricsLocked)
            }
        } else {
            VStack(spacing: 7) {
                Text(model.isResolvingLyrics ? "正在匹配歌词…" : "暂无歌词")
                    .font(.system(size: max(13, fontSize * 0.6), weight: .medium))
                    .foregroundColor(palette.text.opacity(0.8))
                HStack(spacing: 10) {
                    Button("导入歌词…") {
                        model.promptImportLyrics()
                    }
                    .disabled(model.currentTrack == nil)
                    .help("选择 .lrc 或 .txt 文件")

                    Button("重试匹配") {
                        model.retryLyrics()
                    }
                    .disabled(model.currentTrack == nil || model.isResolvingLyrics)
                    .help("重新查找同名歌词或在线匹配")
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(palette.text.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Right-click menu for the lyrics window. The same entries also live in
    /// the app menu and the menu bar.
    @ViewBuilder
    private var lyricsMenu: some View {
        Button("更换歌词…") {
            model.promptImportLyrics()
        }
        .disabled(model.currentTrack == nil)

        Button("恢复自动匹配") {
            model.restoreAutomaticLyrics()
        }
        .disabled(!model.hasLyricsOverride)

        Button("重试匹配") {
            model.retryLyrics()
        }
        .disabled(model.currentTrack == nil || model.isResolvingLyrics)
    }

    /// The fill follows the app theme's resolved accent. The optional
    /// 「歌词描边」 halo comes from the **system** appearance (dark halo on a
    /// dark system, light on a light one) so the line survives busy
    /// wallpapers. macOS 12 has no native text stroke, so the halo is drawn
    /// as a soft blurred copy plus offset copies.
    private var lyricFill: Color {
        colorScheme == .dark ? palette.accentLight : palette.accent
    }

    private var lyricHalo: Color {
        colorScheme == .dark ? .black : .white
    }

    @ViewBuilder
    private func lyricText(
        _ text: String,
        size: CGFloat,
        weight: Font.Weight,
        emphasis: Double = 1
    ) -> some View {
        let base = Text(text).font(.system(size: size, weight: weight))
        if outline {
            // Opt-in outline for busy wallpapers: a soft halo plus offset
            // copies in the contrast colour, not the old hard white ring.
            let halo = lyricHalo.opacity(0.62)
            ZStack {
                base.foregroundColor(halo).blur(radius: 2.6)
                ForEach(Array(Self.outlineOffsets.enumerated()), id: \.offset) { _, offset in
                    base
                        .foregroundColor(halo.opacity(0.75))
                        .offset(x: offset.width, y: offset.height)
                }
                base.foregroundColor(lyricFill.opacity(emphasis))
            }
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        } else {
            // Default: no ring. Accent text with a soft, understated shadow.
            base
                .foregroundColor(lyricFill.opacity(emphasis))
                .shadow(color: .black.opacity(0.26), radius: 2.5, y: 1)
        }
    }

    private static let outlineOffsets: [CGSize] = {
        let steps: [CGFloat] = [-1.2, 0, 1.2]
        return steps.flatMap { x in steps.map { CGSize(width: x, height: $0) } }
            .filter { $0 != .zero }
    }()

    // MARK: - Hover controls

    private var controls: some View {
        VStack {
            Spacer()
            HStack(spacing: 5) {
                controlButton("lock.open", help: "锁定歌词") {
                    model.setLyricsLocked(true)
                }
                controlButton("textformat.size.smaller", help: "缩小") {
                    onResize(-40)
                }
                controlButton("textformat.size.larger", help: "放大") {
                    onResize(40)
                }
                Slider(value: $opacity, in: 0.05...0.9, onEditingChanged: { editing in
                    if !editing { model.setLyricsOpacity(opacity) }
                })
                .frame(width: 62)
                .help("悬停背景不透明度")

                textButton(lineMode == "two" ? "双行" : "单行", help: "切换单行 / 双行") {
                    lineMode = lineMode == "two" ? "one" : "two"
                    model.setLyricsLineMode(lineMode)
                }
                textButton("描边", help: "文字描边", isOn: outline) {
                    outline.toggle()
                    model.setLyricsOutline(outline)
                }
                controlButton("rectangle.compress.vertical", help: "切换到迷你窗口") {
                    model.showMiniPlayer()
                }
                controlButton("xmark", help: "关闭歌词") {
                    model.setLyricsVisible(false)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(palette.panelTint.opacity(0.82), in: Capsule())
            .overlay(Capsule().strokeBorder(palette.hairline, lineWidth: 0.5))
            .padding(.bottom, 8)
        }
        .opacity(showsHoverChrome ? 1 : 0)
        .allowsHitTesting(showsHoverChrome)
        .animation(.easeOut(duration: 0.15), value: showsHoverChrome)
    }

    private var resizeGrip: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                WindowResizeGrip()
                    .frame(width: 16, height: 16)
                    .padding(6)
            }
        }
        .opacity(showsHoverChrome ? 0.55 : 0)
        .allowsHitTesting(showsHoverChrome)
    }

    private func controlButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Icons.symbol(symbol, size: 11)
                .foregroundColor(palette.text.opacity(0.85))
                .frame(width: 22, height: 22)
                .background(palette.raisedFill, in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func textButton(
        _ title: String,
        help: String,
        isOn: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(palette.text.opacity(isOn ? 1 : 0.8))
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(
                    isOn ? palette.accent.opacity(0.24) : palette.raisedFill,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Window pieces

/// Bottom-right grip. Native borderless resizing is available too, but the
/// grip is an explicit, discoverable target.
private struct WindowResizeGrip: NSViewRepresentable {
    final class GripView: NSView {
        private var startFrame = NSRect.zero
        private var startMouse = NSPoint.zero

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .crosshair)
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            startFrame = window.frame
            startMouse = NSEvent.mouseLocation
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            let current = NSEvent.mouseLocation
            var frame = startFrame
            frame.size.width = min(
                max(startFrame.width + current.x - startMouse.x, LyricsOverlayWindowController.minSize.width),
                LyricsOverlayWindowController.maxSize.width
            )
            frame.size.height = min(
                max(startFrame.height - (current.y - startMouse.y), LyricsOverlayWindowController.minSize.height),
                LyricsOverlayWindowController.maxSize.height
            )
            // Keep the top-left corner anchored while the bottom-right moves.
            frame.origin.y = startFrame.maxY - frame.height
            window.setFrame(frame, display: true)
        }
    }

    func makeNSView(context: Context) -> NSView { GripView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
