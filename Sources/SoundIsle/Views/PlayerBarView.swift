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

struct PlayerBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            trackInfo
                .frame(width: 220, alignment: .leading)

            centerColumn
                .frame(minWidth: 280, maxWidth: 460, alignment: .leading)
                .layoutPriority(1)
                .padding(.leading, 16)

            Spacer(minLength: 12)

            rightControls
                .frame(width: 210, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(height: 76)
        // Behind the controls, in front of the bar's material.
        .background(alignment: .bottom) {
            if model.library.settings.showMainSpectrum {
                MainSpectrumView(engine: model.engine)
                    .frame(height: 18)
                    .padding(.horizontal, 18)
                    .allowsHitTesting(false)
            }
        }
        .background(theme.playerTint.opacity(theme.isDark ? 0.42 : 0.72))
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 1)
        }
        .clipped()
    }

    // MARK: Left

    private var trackInfo: some View {
        HStack(spacing: 13) {
            TrackCoverView(
                url: model.currentTrack.flatMap { model.library.artworkURL(for: $0) },
                size: 42,
                cornerRadius: 8
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(model.currentTrack?.title ?? "未在播放")
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
        guard let track = model.currentTrack else { return "选择一首歌曲" }
        if track.isMissing { return "文件缺失" }
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
        case .sequential: return "顺序播放"
        case .repeatAll: return "列表循环"
        case .repeatOne: return "单曲循环"
        case .shuffle: return "随机播放"
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

    private var centerColumn: some View {
        VStack(spacing: 5) {
            HStack(spacing: 20) {
                PlayerIconButton(icon: Icons.previous, size: 34) {
                    model.previous()
                }
                .help("上一首")

                Button {
                    model.togglePlayPause()
                } label: {
                    ZStack {
                        Circle()
                            .fill(theme.accent)
                            .shadow(color: .black.opacity(0.28), radius: 6, y: 3)
                        (model.isPlaying ? Icons.pause : Icons.play)
                            .foregroundColor(theme.onAccent)
                    }
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(model.isPlaying ? "暂停" : "播放")

                PlayerIconButton(icon: Icons.next, size: 34) {
                    model.next()
                }
                .help("下一首")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 6)

            // Isolated: engine position updates re-render only this row. The
            // spectrum lives in its own view so audio-rate updates never touch
            // the rest of the player bar.
            PlayerProgressView(model: model, engine: model.engine)
        }
    }

    // MARK: Right

    private var rightControls: some View {
        HStack(spacing: 8) {
            PlayerIconButton(icon: modeIcon, size: 28) {
                cyclePlaybackMode()
            }
            .help(modeHelp)
            .accessibilityLabel(modeHelp)

            VolumeButton(volume: $model.volume)

            PlayerIconButton(icon: Icons.lyrics(), size: 30) {
                model.toggleLyricsVisibility()
            }
            .help(model.isLyricsVisible ? "隐藏歌词" : "显示歌词")
        }
        .opacity(0.85)
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
            Icons.coverNote
                .foregroundColor(Color.white.opacity(0.55))
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

// MARK: - Progress

private struct PlayerProgressView: View {
    @ObservedObject var model: AppModel
    let engine: PlayerEngine
    @Environment(\.theme) private var theme
    @State private var position: TimeInterval = 0
    @State private var duration: TimeInterval = 0

    private var shownPosition: TimeInterval {
        engine.duration > 0 ? position : model.displayPosition
    }

    private var shownDuration: TimeInterval {
        engine.duration > 0 ? duration : model.displayDuration
    }

    var body: some View {
        VStack(spacing: 2) {
            ProgressSlider(
                value: shownPosition,
                duration: shownDuration,
                onSeek: { model.seek(to: $0) }
            )
            .frame(maxWidth: .infinity)
            .frame(height: 14)

            HStack(spacing: 0) {
                Text(TimeText.string(shownPosition))
                Spacer(minLength: 0)
                Text(TimeText.string(shownDuration))
            }
            .font(.system(size: 9.5))
            .monospacedDigit()
            .foregroundColor(theme.text.opacity(0.72))
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        // Only position/duration drive this row. Observing the whole engine
        // would re-render it at the spectrum's ~20 fps.
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
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            icon
                .foregroundColor(theme.text.opacity(isHovering ? 1 : 0.86))
                .frame(width: size, height: size)
                .background(
                    isHovering ? theme.raisedFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Sliders

private struct ProgressSlider: View {
    @Environment(\.theme) private var theme
    let value: Double
    let duration: Double
    let onSeek: (Double) -> Void

    @State private var dragValue: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let shown = dragValue ?? value
            let progress = duration > 0 ? min(max(shown / duration, 0), 1) : 0
            let knobX = min(max(width * progress - 4.5, 0), max(width - 9, 0))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.sliderTrack)
                    .frame(height: 4)
                Capsule()
                    .fill(theme.accentGradient)
                    .frame(width: width * progress, height: 4)
                Circle()
                    .fill(Color.white)
                    .frame(width: 9, height: 9)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .offset(x: knobX)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard duration > 0 else { return }
                        dragValue = min(max(gesture.location.x / width, 0), 1) * duration
                    }
                    .onEnded { gesture in
                        guard duration > 0 else {
                            dragValue = nil
                            return
                        }
                        let target = min(max(gesture.location.x / width, 0), 1) * duration
                        dragValue = nil
                        onSeek(target)
                    }
            )
        }
        .frame(height: 14)
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
                .foregroundColor(theme.text.opacity(isHovering ? 1 : 0.86))
                .frame(width: 28, height: 28)
                .background(
                    isHovering || isPresented ? theme.raisedFill : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isMuted ? "取消静音" : "音量")
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
            .help(isMuted ? "取消静音" : "静音")

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
