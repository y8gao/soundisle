import Foundation
import SoundIsleCore
import SwiftUI

struct TrackListView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header

            if let message = model.statusMessage {
                statusBanner(message)
            }

            if model.visibleTracks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(model.visibleTracks.enumerated()), id: \.element.id) { index, track in
                            TrackRow(
                                track: track,
                                index: index,
                                isCurrent: model.currentTrack?.id == track.id,
                                isPlaying: model.isPlaying,
                                onTap: { model.play(trackID: track.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                    .padding(.bottom, 14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Theme.text)
                .lineLimit(1)
            Text(meta)
                .font(.system(size: 11.5))
                .foregroundColor(Theme.text.opacity(0.5))
                .lineLimit(1)

            Spacer(minLength: 12)

            if model.isScanning {
                HStack(spacing: 3) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                        .frame(width: 12, height: 12)
                    Text("扫描中…")
                        .font(.system(size: 10.5))
                        .foregroundColor(Theme.text.opacity(0.5))
                }
            }

            Button {
                Task { await model.rescan() }
            } label: {
                Icons.refresh
                    .foregroundColor(Theme.text.opacity(model.folders.isEmpty ? 0.25 : 0.6))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isScanning || model.folders.isEmpty)
            .help("重新扫描音乐文件夹")
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 11)
    }

    private var title: String {
        model.selectedFolder?.lastPathComponent ?? "全部音乐"
    }

    private var meta: String {
        let tracks = model.visibleTracks
        let seconds = Int(tracks.reduce(0) { $0 + $1.duration })
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let duration = hours > 0 ? "\(hours) 小时 \(minutes) 分" : "\(minutes) 分钟"
        return "\(tracks.count) 首 · \(duration)"
    }

    private func statusBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Icons.warning
                .foregroundColor(Theme.warning)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundColor(Theme.text.opacity(0.82))
                .lineLimit(2)
            Spacer(minLength: 6)
            Button {
                model.dismissStatus()
            } label: {
                Icons.close
                    .foregroundColor(Theme.text.opacity(0.5))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 30)
        .background(
            Theme.warning.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.warning.opacity(0.3), lineWidth: 0.5)
        )
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            Icons.emptyLibrary
                .foregroundColor(Theme.text.opacity(0.28))
            Text(model.tracks.isEmpty ? "音乐库是空的" : "这个文件夹里没有歌曲")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.text.opacity(0.85))
            Text(
                model.tracks.isEmpty
                    ? "把音乐文件或文件夹拖到这里，或者选择一个文件夹。"
                    : "换一个文件夹，或回到「全部音乐」。"
            )
            .font(.system(size: 12))
            .foregroundColor(Theme.text.opacity(0.5))
            .multilineTextAlignment(.center)

            Button {
                if model.tracks.isEmpty {
                    model.importFolders(model.openFolders())
                } else {
                    model.selectedFolder = nil
                }
            } label: {
                Text(model.tracks.isEmpty ? "选择文件夹" : "查看全部音乐")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.accentLight)
                    .padding(.horizontal, 16)
                    .frame(height: 30)
                    .background(
                        Theme.accent.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 0.5)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isScanning)
            .opacity(model.isScanning ? 0.45 : 1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }
}

// MARK: - Row

private struct TrackRow: View {
    let track: Track
    let index: Int
    let isCurrent: Bool
    let isPlaying: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                leading
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(track.title)
                            .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                            .foregroundColor(titleColor)
                            .lineLimit(1)
                        if track.isMissing {
                            Text("文件缺失")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(Theme.warning)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Theme.warning.opacity(0.14), in: Capsule())
                        }
                    }
                    if !track.artist.isEmpty {
                        Text(track.artist)
                            .font(.system(size: 10.5))
                            .foregroundColor(Theme.text.opacity(0.5))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Text(TimeText.string(track.duration))
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundColor(Theme.text.opacity(0.45))
                    .frame(width: 46, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minHeight: 36)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var leading: some View {
        if isCurrent {
            PlayingIndicator(isPlaying: isPlaying)
        } else {
            Text("\(index + 1)")
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundColor(Theme.text.opacity(0.4))
        }
    }

    private var titleColor: Color {
        if track.isMissing { return Theme.text.opacity(0.45) }
        return isCurrent ? Theme.accentLight : Theme.text
    }

    private var rowBackground: Color {
        if isCurrent { return Theme.accent.opacity(0.13) }
        if isHovering { return Color.white.opacity(0.04) }
        return .clear
    }
}

// MARK: - Playing indicator

/// Three little bars marking the current track. Kept static: an animated
/// equalizer drove SwiftUI commits continuously and dominated idle playback
/// CPU on older Macs, while a static glyph already communicates "playing".
private struct PlayingIndicator: View {
    let isPlaying: Bool

    private let heights: [CGFloat] = [5, 11, 8]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { bar in
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 2.5, height: isPlaying ? heights[bar] : 3)
            }
        }
        .frame(width: 14, height: 12, alignment: .bottom)
    }
}
