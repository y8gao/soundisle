import SoundIsleCore
import SwiftUI

/// 520x66 glass capsule: cover, title/artist, live spectrum, position time,
/// transport buttons, expand, and a 2pt progress line along the bottom.
struct MiniPlayerView: View {
    @ObservedObject var model: AppModel
    /// Deliberately not `@ObservedObject`: the parent must not re-render at
    /// spectrum rate. Only the small spectrum/position subviews observe the
    /// engine, so the glass capsule and transport controls stay static.
    let engine: PlayerEngine
    @Environment(\.colorScheme) private var colorScheme
    let onExpand: () -> Void

    init(model: AppModel, onExpand: @escaping () -> Void) {
        self.model = model
        self.engine = model.engine
        self.onExpand = onExpand
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

    private var capsule: RoundedRectangle {
        RoundedRectangle(cornerRadius: 32, style: .continuous)
    }

    var body: some View {
        content
            .frame(width: MiniPlayerWindowController.size.width, height: MiniPlayerWindowController.size.height)
            .background(WindowDragArea())
            .background(palette.playerTint.opacity(palette.isDark ? 0.34 : 0.62), in: capsule)
            .background(.ultraThinMaterial, in: capsule)
            .background {
                RadialGradient(
                    colors: [palette.accent.opacity(palette.isDark ? 0.22 : 0.14), .clear],
                    center: UnitPoint(x: 0.16, y: 0.1),
                    startRadius: 0,
                    endRadius: 220
                )
                .clipShape(capsule)
            }
            .overlay(
                capsule.strokeBorder(
                    LinearGradient(
                        colors: [
                            palette.accent.opacity(0.55),
                            palette.hairline,
                            palette.accentSecondary.opacity(0.38),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            )
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [Color.white.opacity(palette.isDark ? 0.16 : 0.4), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 1)
                .padding(.horizontal, 28)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) { progressLine }
            .clipShape(capsule)
            .soundIsleTheme(palette)
    }

    private var content: some View {
        HStack(spacing: 0) {
            cover
                .padding(.leading, 11)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.currentTrack?.title ?? L("未在播放"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(palette.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundColor(palette.mutedText(0.55))
                    .lineLimit(1)
            }
            .frame(width: 126, alignment: .leading)
            .padding(.leading, 13)
            .allowsHitTesting(false)

            MiniSpectrumView(engine: engine)
                .padding(.leading, 2)
                .padding(.trailing, 4)
                .allowsHitTesting(false)

            Spacer(minLength: 6)

            MiniPositionView(model: model, engine: engine)
                .padding(.trailing, 8)
                .allowsHitTesting(false)

            HStack(spacing: 4) {
                MiniButton(icon: Icons.symbol("backward.end", size: 13), size: 26, help: L("上一首")) {
                    model.previous()
                }
                MiniButton(
                    icon: Icons.symbol(model.isPlaying ? "pause.fill" : "play.fill", size: 14),
                    size: 34,
                    help: model.isPlaying ? L("暂停") : L("播放"),
                    isPrimary: true
                ) {
                    model.togglePlayPause()
                }
                MiniButton(icon: Icons.symbol("forward.end", size: 13), size: 26, help: L("下一首")) {
                    model.next()
                }
                MiniButton(
                    icon: Icons.symbol("rectangle.expand.vertical", size: 14),
                    size: 28,
                    help: L("展开主窗口")
                ) {
                    onExpand()
                }
            }
            .padding(.trailing, 14)
        }
    }

    // MARK: - Pieces

    private var cover: some View {
        TrackCoverView(
            url: model.currentTrack.flatMap { model.library.artworkURL(for: $0) },
            size: 44,
            cornerRadius: 11
        )
    }

    private var subtitle: String {
        guard let track = model.currentTrack else { return L("选择一首歌曲") }
        if track.isMissing { return L("文件缺失") }
        if let lyric = model.currentLyricText?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !lyric.isEmpty {
            return lyric
        }
        return track.artist.isEmpty ? L("未知歌手") : track.artist
    }

    private var progressLine: some View {
        MiniProgressLineView(model: model, engine: engine)
    }
}

// MARK: - Live pieces

/// 24 bars drawn by an AppKit view that subscribes to the engine itself, so
/// SwiftUI stays out of the audio-rate update path.
private struct MiniSpectrumView: View {
    let engine: PlayerEngine
    @Environment(\.theme) private var theme

    var body: some View {
        SpectrumBarsView(
            engine: engine,
            bottomColor: theme.accent,
            topColor: theme.accentSecondary,
            gap: 1.5,
            minBarHeight: 3,
            cornerRadius: 1.25
        )
        .frame(width: 94.5, height: 26)
    }
}

private struct MiniPositionView: View {
    @ObservedObject var model: AppModel
    let engine: PlayerEngine
    @Environment(\.theme) private var theme
    @State private var position: TimeInterval = 0

    var body: some View {
        Text(TimeText.string(engine.duration > 0 ? position : model.displayPosition))
            .font(.system(size: 10))
            .monospacedDigit()
            .foregroundColor(theme.mutedText(0.5))
            .onReceive(engine.$position) { position = $0 }
            .onAppear { position = engine.position }
    }
}

private struct MiniProgressLineView: View {
    @ObservedObject var model: AppModel
    let engine: PlayerEngine
    @Environment(\.theme) private var theme
    @State private var position: TimeInterval = 0
    @State private var duration: TimeInterval = 0

    var body: some View {
        GeometryReader { geometry in
            let shownDuration = engine.duration > 0 ? duration : model.displayDuration
            let shownPosition = engine.duration > 0 ? position : model.displayPosition
            let progress = shownDuration > 0
                ? min(max(shownPosition / shownDuration, 0), 1)
                : 0
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(theme.sliderTrack)
                Rectangle()
                    .fill(theme.accentGradient)
                    .frame(width: geometry.size.width * progress)
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
        .onReceive(engine.$position) { position = $0 }
        .onReceive(engine.$duration) { duration = $0 }
    }
}

// MARK: - Button

private struct MiniButton: View {
    @Environment(\.theme) private var theme
    let icon: Image
    let size: CGFloat
    let help: String
    var isPrimary = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if isPrimary {
                    Circle()
                        .fill(theme.accent)
                        .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
                    icon
                        .foregroundColor(theme.onAccent)
                } else {
                    icon
                        .foregroundColor(theme.text.opacity(isHovering ? 1 : 0.82))
                        .background(
                            isHovering ? theme.raisedFill : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}
