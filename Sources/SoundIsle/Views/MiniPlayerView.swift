import SoundIsleCore
import SwiftUI

/// 520x66 glass capsule: cover, title/artist, live spectrum, position time,
/// transport buttons, expand, and a 2pt progress line along the bottom.
struct MiniPlayerView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var engine: PlayerEngine
    let onExpand: () -> Void

    private let barCount = 11

    init(model: AppModel, onExpand: @escaping () -> Void) {
        self.model = model
        _engine = ObservedObject(wrappedValue: model.engine)
        self.onExpand = onExpand
    }

    private var capsule: RoundedRectangle {
        RoundedRectangle(cornerRadius: 32, style: .continuous)
    }

    var body: some View {
        content
            .frame(width: MiniPlayerWindowController.size.width, height: MiniPlayerWindowController.size.height)
            .background(WindowDragArea())
            .background(Theme.panelTint.opacity(0.55), in: capsule)
            .background(.ultraThinMaterial, in: capsule)
            .overlay(capsule.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .overlay(alignment: .bottom) { progressLine }
            .clipShape(capsule)
            .preferredColorScheme(.dark)
    }

    private var content: some View {
        HStack(spacing: 0) {
            cover
                .padding(.leading, 11)
                .allowsHitTesting(false)

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
            .frame(width: 126, alignment: .leading)
            .padding(.leading, 13)
            .allowsHitTesting(false)

            spectrum
                .padding(.leading, 2)
                .padding(.trailing, 4)
                .allowsHitTesting(false)

            Spacer(minLength: 6)

            Text(TimeText.string(model.displayPosition))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundColor(Theme.text.opacity(0.5))
                .padding(.trailing, 8)
                .allowsHitTesting(false)

            HStack(spacing: 4) {
                MiniButton(icon: Icons.symbol("backward.end", size: 13), size: 26, help: "上一首") {
                    model.previous()
                }
                MiniButton(
                    icon: Icons.symbol(model.isPlaying ? "pause.fill" : "play.fill", size: 14),
                    size: 34,
                    help: model.isPlaying ? "暂停" : "播放",
                    isPrimary: true
                ) {
                    model.togglePlayPause()
                }
                MiniButton(icon: Icons.symbol("forward.end", size: 13), size: 26, help: "下一首") {
                    model.next()
                }
                MiniButton(
                    icon: Icons.symbol("arrow.up.left.and.arrow.down.right", size: 12),
                    size: 28,
                    help: "展开主窗口"
                ) {
                    onExpand()
                }
            }
            .padding(.trailing, 14)
        }
    }

    // MARK: - Pieces

    private var cover: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Theme.coverGradient)
            .frame(width: 44, height: 44)
            .overlay {
                Icons.coverNote
                    .foregroundColor(Color.white.opacity(0.55))
            }
            .overlay {
                RadialGradient(
                    colors: [Color.white.opacity(0.35), .clear],
                    center: UnitPoint(x: 0.3, y: 0.25),
                    startRadius: 0,
                    endRadius: 32
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
    }

    private var subtitle: String {
        guard let track = model.currentTrack else { return "选择一首歌曲" }
        if track.isMissing { return "文件缺失" }
        return track.artist.isEmpty ? "未知歌手" : track.artist
    }

    private var spectrum: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Theme.accent, Color(red: 197 / 255, green: 140 / 255, blue: 255 / 255)],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 3, height: barHeight(index))
            }
        }
        .frame(height: 26, alignment: .bottom)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let bands = engine.spectrum
        guard !bands.isEmpty else { return 3 }
        let band = bands[min(bands.count - 1, index * bands.count / barCount)]
        return max(3, CGFloat(min(max(band, 0), 1)) * 26)
    }

    private var progressLine: some View {
        GeometryReader { geometry in
            let duration = model.displayDuration
            let progress = duration > 0 ? min(max(model.displayPosition / duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.white.opacity(0.10))
                Rectangle()
                    .fill(Theme.accentGradient)
                    .frame(width: geometry.size.width * progress)
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}

// MARK: - Button

private struct MiniButton: View {
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
                        .fill(Theme.text)
                        .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
                    icon
                        .foregroundColor(Color(red: 20 / 255, green: 24 / 255, blue: 38 / 255))
                } else {
                    icon
                        .foregroundColor(Theme.text.opacity(isHovering ? 1 : 0.82))
                        .background(
                            isHovering ? Color.white.opacity(0.08) : Color.clear,
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
