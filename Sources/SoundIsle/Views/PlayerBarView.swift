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
    @ObservedObject var engine: PlayerEngine

    var body: some View {
        HStack(spacing: 0) {
            trackInfo
                .frame(width: 220, alignment: .leading)

            Spacer(minLength: 0)

            centerColumn
                .frame(width: 360)

            Spacer(minLength: 0)

            rightControls
                .frame(width: 176, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(height: 76)
        .background(Theme.playerTint.opacity(0.42))
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.09))
                .frame(height: 1)
        }
    }

    // MARK: Left

    private var trackInfo: some View {
        HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.coverGradient)
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
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundColor(Theme.text.opacity(0.55))
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

    // MARK: Center

    private var centerColumn: some View {
        VStack(spacing: 7) {
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
                            .fill(Theme.text)
                            .shadow(color: .black.opacity(0.28), radius: 6, y: 3)
                        (engine.isPlaying ? Icons.pause : Icons.play)
                            .foregroundColor(Color(red: 20 / 255, green: 24 / 255, blue: 38 / 255))
                    }
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(engine.isPlaying ? "暂停" : "播放")

                PlayerIconButton(icon: Icons.next, size: 34) {
                    model.next()
                }
                .help("下一首")
            }

            HStack(spacing: 9) {
                Text(TimeText.string(model.displayPosition))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundColor(Theme.text.opacity(0.72))
                    .frame(width: 38, alignment: .trailing)

                ProgressSlider(
                    value: model.displayPosition,
                    duration: model.displayDuration,
                    onSeek: { model.seek(to: $0) }
                )
                .frame(height: 14)

                Text(TimeText.string(model.displayDuration))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundColor(Theme.text.opacity(0.72))
                    .frame(width: 38, alignment: .leading)
            }
            .frame(width: 360)
        }
    }

    // MARK: Right

    private var rightControls: some View {
        HStack(spacing: 10) {
            Icons.volume()
                .foregroundColor(Theme.text.opacity(0.75))

            VolumeSlider(value: $model.volume)
                .frame(width: 46, height: 14)

            PlayerIconButton(icon: Icons.lyrics(), size: 30) {
                model.statusMessage = "歌词功能将在后续版本提供。"
            }
            .help("歌词")
        }
        .opacity(0.8)
    }
}

// MARK: - Buttons

private struct PlayerIconButton: View {
    let icon: Image
    let size: CGFloat
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            icon
                .foregroundColor(Theme.text.opacity(isHovering ? 1 : 0.86))
                .frame(width: size, height: size)
                .background(
                    isHovering ? Color.white.opacity(0.08) : Color.clear,
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
                    .fill(Color.white.opacity(0.14))
                    .frame(height: 4)
                Capsule()
                    .fill(Theme.accentGradient)
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
    @Binding var value: Double

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let progress = min(max(value, 0), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(height: 3)
                Capsule()
                    .fill(Theme.text.opacity(0.65))
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
