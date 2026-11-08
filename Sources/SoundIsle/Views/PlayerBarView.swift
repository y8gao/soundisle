import AppKit
import Foundation
import SoundIsleCore
import SwiftUI

// MARK: - Time formatting

enum TimeText {
    static func string(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remaining = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remaining)
        }
        return String(format: "%d:%02d", minutes, remaining)
    }
}

// MARK: - Player bar

/// One 84pt glass strip: cover/title on the left, transport centred in the
/// window, utilities on the right. The only progress affordance is a 3pt line
/// hugging the top edge; elapsed/total time sit in the bottom corners so the
/// bar reads as one layer instead of stacked rows.
struct PlayerBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            if model.library.settings.showMainSpectrum {
                MainSpectrumView(engine: model.engine)
                    .frame(height: 16)
                    .padding(.horizontal, 18)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
            }

            HStack(spacing: 0) {
                trackInfo
                    .frame(width: 220, alignment: .leading)
                Spacer(minLength: 12)
                rightControls
                    .frame(width: 210, alignment: .trailing)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Centred in the window, nudged below the top-edge progress strip.
            transport
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 6)
        }
        .frame(height: 84)
        .background(theme.backgroundBottom.opacity(theme.isDark ? 0.42 : 0.50))
        // Only the top 14pt takes hover/drag; the transport below stays free.
        .overlay(alignment: .top) {
            PlayerProgressLine(model: model, engine: model.engine)
        }
        .overlay(alignment: .bottom) {
            PlayerBarTimes(model: model, engine: model.engine)
        }
    }

    // MARK: Left

    private var trackInfo: some View {
        HStack(spacing: 13) {
            Button {
                model.toggleLyricsPage()
            } label: {
                TrackCoverView(
                    url: model.currentTrack.flatMap { model.library.artworkURL(for: $0) },
                    size: 42,
                    cornerRadius: 8
                )
            }
            .buttonStyle(.plain)
            .help(model.showsLyricsPage ? L("返回歌曲列表") : L("查看当前歌曲歌词"))
            .accessibilityLabel(model.showsLyricsPage ? L("封面，返回歌曲列表") : L("封面，打开歌词页"))

            VStack(alignment: .leading, spacing: 2) {
                Text(model.currentTrack?.title ?? L("未在播放"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(theme.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.mutedText(0.55))
                    .lineLimit(1)
            }
        }
    }

    private var subtitle: String {
        guard let track = model.currentTrack else { return L("选择一首歌曲") }
        if track.isMissing { return L("文件缺失") }
        let parts = [track.artist, track.album].filter { !$0.isEmpty }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    // MARK: Playback modes

    /// One button instead of four: click cycles repeat-all → repeat-one →
    /// shuffle, and the glyph/help always show the current mode. A legacy
    /// `.sequential` queue (old settings) jumps straight to repeat-all.
    private var modeIcon: Image {
        switch model.queue.mode {
        case .sequential: return Icons.sequential
        case .repeatAll: return Icons.repeatAll
        case .repeatOne: return Icons.repeatOne
        case .shuffle: return Icons.shuffle
        }
    }

    private var modeHelp: String {
        switch model.queue.mode {
        case .sequential: return L("顺序播放")
        case .repeatAll: return L("列表循环")
        case .repeatOne: return L("单曲循环")
        case .shuffle: return L("随机播放")
        }
    }

    private func cyclePlaybackMode() {
        let order: [PlaybackMode] = [.repeatAll, .repeatOne, .shuffle]
        guard let index = order.firstIndex(of: model.queue.mode) else {
            model.setPlaybackMode(.repeatAll)
            return
        }
        model.setPlaybackMode(order[(index + 1) % order.count])
    }

    // MARK: Center

    private var transport: some View {
        HStack(spacing: 20) {
            PlayerIconButton(icon: Icons.previous, size: 34) {
                model.previous()
            }
            .help(L("上一首"))
            .accessibilityLabel(L("上一首"))

            Button {
                model.togglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(theme.accent)
                        .shadow(color: theme.accent.opacity(0.35), radius: 8, y: 3)
                        .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
                    (model.isPlaying ? Icons.pause : Icons.play)
                        .foregroundColor(theme.onAccent)
                }
                .frame(width: 38, height: 38)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(model.isPlaying ? L("暂停") : L("播放"))
            .accessibilityLabel(model.isPlaying ? L("暂停") : L("播放"))

            PlayerIconButton(icon: Icons.next, size: 34) {
                model.next()
            }
            .help(L("下一首"))
            .accessibilityLabel(L("下一首"))
        }
    }

    // MARK: Right

    private var rightControls: some View {
        HStack(spacing: 8) {
            PlayerIconButton(icon: modeIcon, size: 32) {
                cyclePlaybackMode()
            }
            .help(modeHelp)
            .accessibilityLabel(modeHelp)

            VolumeButton(volume: $model.volume)

            PlayerIconButton(icon: Icons.lyrics(), size: 30, isActive: model.isLyricsVisible) {
                model.toggleLyricsVisibility()
            }
            .help(model.isLyricsVisible ? L("隐藏歌词") : L("显示歌词"))
            .accessibilityLabel(model.isLyricsVisible ? L("隐藏歌词") : L("显示歌词"))
            .accessibilityAddTraits(model.isLyricsVisible ? .isSelected : [])

            PlayerIconButton(icon: Icons.symbol("rectangle.compress.vertical", size: 16), size: 30) {
                model.showMiniPlayer()
            }
            .help(L("切换到迷你窗口"))
            .accessibilityLabel(L("切换到迷你窗口"))
        }
    }
}

// MARK: - Cover

/// Cached tag artwork with the original gradient as the placeholder/fallback.
/// `AsyncImage` loads and decodes off the main thread, so a large cover never
/// stalls the player bar or the mini player.
struct TrackCoverView: View {
    @Environment(\.theme) private var theme
    let url: URL?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(theme.coverGradient)
            NoteIcon(size: 17, color: Color.white.opacity(0.7))
            if let url {
                AsyncImage(
                    url: url,
                    transaction: Transaction(animation: .easeOut(duration: 0.15))
                ) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RadialGradient(
                colors: [Color.white.opacity(0.22), .clear],
                center: UnitPoint(x: 0.3, y: 0.25),
                startRadius: 0,
                endRadius: size * 0.72
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
    }
}

// MARK: - Top-edge progress

/// Full-width 3pt line at the very top of the bar. Hovering (or dragging)
/// grows it to 6pt and enlarges the frosted, accent-glowing position dot.
/// The whole control is only 14pt tall, so it never covers the transport.
private struct PlayerProgressLine: View {
    @ObservedObject var model: AppModel
    let engine: PlayerEngine
    @Environment(\.theme) private var theme
    @State private var position: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var isHovering = false
    @State private var dragValue: Double?

    private var shownPosition: TimeInterval {
        engine.duration > 0 ? position : model.displayPosition
    }

    private var shownDuration: TimeInterval {
        engine.duration > 0 ? duration : model.displayDuration
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let shown = dragValue ?? shownPosition
            let progress = shownDuration > 0
                ? min(max(shown / shownDuration, 0), 1)
                : 0
            let active = isHovering || dragValue != nil
            let band: CGFloat = 6
            let lineHeight: CGFloat = active ? 6 : 3
            let knob: CGFloat = active ? 12 : 9
            let knobX = min(
                max(width * CGFloat(progress), knob / 2),
                max(width - knob / 2, knob / 2)
            )

            ZStack(alignment: .topLeading) {
                // The line lives in a 6pt band and grows around its centre,
                // so hover expands 1.5pt up and 1.5pt down instead of
                // pushing the whole strip down from the top edge.
                Rectangle()
                    .fill(theme.sliderTrack)
                    .frame(height: lineHeight)
                    .offset(y: (band - lineHeight) / 2)

                Rectangle()
                    .fill(theme.accentGradient)
                    .frame(width: width * CGFloat(progress), height: lineHeight)
                    .offset(y: (band - lineHeight) / 2)

                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().fill(Color.white.opacity(0.55)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1))
                    .frame(width: knob, height: knob)
                    .shadow(color: theme.accent.opacity(0.85), radius: knob * 0.7)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .position(x: knobX, y: band / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(.easeOut(duration: 0.16), value: active)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard shownDuration > 0 else { return }
                        dragValue = min(max(Double(gesture.location.x / width), 0), 1)
                            * shownDuration
                    }
                    .onEnded { gesture in
                        guard shownDuration > 0 else {
                            dragValue = nil
                            return
                        }
                        let target = min(max(Double(gesture.location.x / width), 0), 1)
                            * shownDuration
                        dragValue = nil
                        model.seek(to: target)
                    }
            )
        }
        .frame(height: 14)
        .accessibilityElement()
        .accessibilityLabel(L("播放进度"))
        .accessibilityValue(
            "\(TimeText.string(dragValue ?? shownPosition)) / \(TimeText.string(shownDuration))"
        )
        .onReceive(engine.$position) { position = $0 }
        .onReceive(engine.$duration) { duration = $0 }
        .onAppear {
            position = engine.position
            duration = engine.duration
        }
    }
}

// MARK: - Corner times

/// Elapsed and total time in the bar's bottom corners. Observing only the
/// engine's position/duration keeps audio-rate updates inside this strip.
private struct PlayerBarTimes: View {
    @ObservedObject var model: AppModel
    let engine: PlayerEngine
    @Environment(\.theme) private var theme
    @State private var position: TimeInterval = 0
    @State private var duration: TimeInterval = 0

    var body: some View {
        HStack(spacing: 0) {
            Text(TimeText.string(engine.duration > 0 ? position : model.displayPosition))
            Spacer(minLength: 0)
            Text(TimeText.string(engine.duration > 0 ? duration : model.displayDuration))
        }
        .font(.system(size: 9.5))
        .monospacedDigit()
        .foregroundColor(theme.mutedText(0.55))
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("播放时间"))
        .onReceive(engine.$position) { position = $0 }
        .onReceive(engine.$duration) { duration = $0 }
        .onAppear {
            position = engine.position
            duration = engine.duration
        }
    }
}

// MARK: - Main spectrum

/// Faint 24-bar spectrum along the player bar. The AppKit view subscribes to
/// the engine, so audio-rate updates redraw only this strip.
private struct MainSpectrumView: View {
    let engine: PlayerEngine
    @Environment(\.theme) private var theme

    var body: some View {
        SpectrumBarsView(
            engine: engine,
            bottomColor: theme.accent.opacity(0.16),
            topColor: theme.accent.opacity(0.34),
            gap: 2,
            minBarHeight: 1,
            cornerRadius: 1
        )
        .accessibilityHidden(true)
    }
}

// MARK: - Buttons

private struct PlayerIconButton: View {
    @Environment(\.theme) private var theme
    let icon: Image
    let size: CGFloat
    var isActive = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            icon
                .foregroundColor(
                    isActive ? theme.accent : (isHovering ? theme.accent : theme.accent.opacity(0.82))
                )
                .frame(width: size, height: size)
                .background {
                    if isActive {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(theme.accent.opacity(0.18))
                    } else if isHovering {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(theme.raisedFill)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Volume

/// Speaker button with a popover holding the vertical slider and mute toggle.
/// `lastVolume` makes mute reversible without a second persisted field.
private struct VolumeButton: View {
    @Environment(\.theme) private var theme
    @Binding var volume: Double

    @State private var isPresented = false
    @State private var isHovering = false
    @State private var lastVolume: Double = 0.8

    private var isMuted: Bool { volume <= 0.0001 }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Icons.volume(muted: isMuted, low: volume < 0.34)
                .foregroundColor(isHovering || isPresented ? theme.accent : theme.accent.opacity(0.82))
                .frame(width: 30, height: 30)
                .background(
                    isHovering || isPresented ? theme.raisedFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isMuted ? L("取消静音") : L("音量"))
        .accessibilityLabel(isMuted ? L("取消静音") : L("音量"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VolumePopover(
                volume: $volume,
                isMuted: isMuted,
                onToggleMute: toggleMute
            )
        }
    }

    private func toggleMute() {
        if isMuted {
            volume = lastVolume > 0.0001 ? lastVolume : 0.8
        } else {
            lastVolume = volume
            volume = 0
        }
    }
}

private struct VolumePopover: View {
    @Environment(\.theme) private var theme
    @Binding var volume: Double
    let isMuted: Bool
    let onToggleMute: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            VerticalVolumeSlider(value: $volume)
                .frame(width: 18, height: 108)

            Button(action: onToggleMute) {
                Icons.volume(muted: isMuted, low: false, size: 14)
                    .foregroundColor(theme.text.opacity(0.82))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isMuted ? L("取消静音") : L("静音"))
            .accessibilityLabel(isMuted ? L("取消静音") : L("静音"))

            Text("\(Int((volume * 100).rounded()))%")
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundColor(theme.mutedText(0.5))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 58)
        .glassPanel(cornerRadius: 10)
    }
}

private struct VerticalVolumeSlider: View {
    @Environment(\.theme) private var theme
    @Binding var value: Double

    var body: some View {
        GeometryReader { geometry in
            let height = max(geometry.size.height, 1)
            let progress = min(max(value, 0), 1)

            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(theme.sliderTrack)
                    .frame(width: 4, height: height)
                Capsule()
                    .fill(theme.text.opacity(0.65))
                    .frame(width: 4, height: height * progress)
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(y: -(height - 10) * progress)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let position = Double(1 - gesture.location.y / height)
                        value = min(max(position, 0), 1)
                    }
            )
        }
    }
}
