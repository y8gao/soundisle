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
                .frame(width: 200, alignment: .leading)

            modeControls
                .padding(.leading, 10)

            Spacer(minLength: 0)

            centerColumn
                .frame(width: 360)

            Spacer(minLength: 0)

            rightControls
                .frame(width: 176, alignment: .trailing)
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
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.coverGradient)
                .frame(width: 42, height: 42)
                .overlay {
                    Icons.coverNote
                        .foregroundColor(Color.white.opacity(0.55))
                }
                .overlay {
                    RadialGradient(
                        colors: [Color.white.opacity(0.35), .clear],
                        center: UnitPoint(x: 0.3, y: 0.25),
                        startRadius: 0,
                        endRadius: 30
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.currentTrack?.title ?? "未在播放")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(theme.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.text.opacity(0.55))
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

    private var modeControls: some View {
        HStack(spacing: 2) {
            modeButton(.sequential, icon: Icons.sequential, help: "顺序播放")
            modeButton(.repeatAll, icon: Icons.repeatAll, help: "列表循环")
            modeButton(.repeatOne, icon: Icons.repeatOne, help: "单曲循环")
            modeButton(.shuffle, icon: Icons.shuffle, help: "随机播放")
        }
    }

    private func modeButton(_ mode: PlaybackMode, icon: Image, help: String) -> some View {
        PlaybackModeButton(
            icon: icon,
            help: help,
            isSelected: model.queue.mode == mode
        ) {
            model.setPlaybackMode(mode)
        }
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

            // Isolated: engine position updates re-render only this row. The
            // spectrum lives in its own view so audio-rate updates never touch
            // the rest of the player bar.
            PlayerProgressView(model: model, engine: model.engine)
        }
    }

    // MARK: Right

    private var rightControls: some View {
        HStack(spacing: 10) {
            Icons.volume()
                .foregroundColor(theme.text.opacity(0.75))

            VolumeSlider(value: $model.volume)
                .frame(width: 46, height: 14)

            PlayerIconButton(icon: Icons.lyrics(), size: 30) {
                model.toggleLyricsVisibility()
            }
            .help(model.isLyricsVisible ? "隐藏歌词" : "显示歌词")

            PlayerIconButton(icon: Icons.lyricsLock(locked: model.isLyricsLocked, size: 12), size: 26) {
                model.toggleLyricsLock()
            }
            .help(model.isLyricsLocked ? "解锁歌词" : "锁定歌词")
        }
        .opacity(0.8)
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
            .frame(width: 360, height: 14)

            HStack(spacing: 0) {
                Text(TimeText.string(shownPosition))
                Spacer(minLength: 0)
                Text(TimeText.string(shownDuration))
            }
            .font(.system(size: 9.5))
            .monospacedDigit()
            .foregroundColor(theme.text.opacity(0.72))
            .frame(width: 360)
        }
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

private struct PlaybackModeButton: View {
    @Environment(\.theme) private var theme
    let icon: Image
    let help: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            icon
                .foregroundColor(
                    isSelected ? theme.accentLight : theme.text.opacity(isHovering ? 0.9 : 0.45)
                )
                .frame(width: 24, height: 24)
                .background(
                    isSelected ? theme.accent.opacity(0.18) : (isHovering ? theme.raisedFill : Color.clear),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

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

private struct VolumeSlider: View {
    @Environment(\.theme) private var theme
    @Binding var value: Double

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let progress = min(max(value, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.sliderTrack)
                    .frame(height: 3)
                Capsule()
                    .fill(theme.text.opacity(0.65))
                    .frame(width: width * progress, height: 3)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        value = min(max(gesture.location.x / width, 0), 1)
                    }
            )
        }
        .frame(width: 46, height: 14)
    }
}
