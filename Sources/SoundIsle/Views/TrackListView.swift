import AppKit
import Foundation
import SoundIsleCore
import SwiftUI
import UniformTypeIdentifiers

struct TrackListView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            columnHeader

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
                                isSelected: model.selectedTrackIDs.contains(track.id),
                                isPlaying: model.isPlaying,
                                rowStyle: model.library.settings.rowStyle,
                                artworkURL: model.library.artworkURL(for: track),
                                onTap: { model.handleTrackClick(track.id) }
                            )
                            .onDrag {
                                NSItemProvider(object: track.id.uuidString as NSString)
                            }
                            .onDrop(of: [UTType.utf8PlainText], isTargeted: nil) { providers in
                                handleReorder(providers, onto: track)
                            }
                            .contextMenu {
                                Button("编辑标签…") {
                                    model.beginTagEdit(
                                        trackIDs: model.contextTrackIDs(for: track.id)
                                    )
                                }
                                Divider()
                                if case .playlist(let playlistID) = model.selection {
                                    Button("从播放列表移除") {
                                        for id in model.contextTrackIDs(for: track.id) {
                                            model.removeFromPlaylist(playlistID, trackID: id)
                                        }
                                    }
                                }
                                if !model.playlists.playlists.isEmpty {
                                    Menu("添加到播放列表") {
                                        ForEach(model.playlists.playlists) { playlist in
                                            Button(playlist.name) {
                                                model.addToPlaylist(
                                                    playlist.id,
                                                    trackIDs: model.contextTrackIDs(for: track.id)
                                                )
                                            }
                                        }
                                    }
                                }
                            }
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
        .padding(.bottom, 8)
    }

    private var columnHeader: some View {
        HStack(spacing: 2) {
            sortButton("标题", .title)
            sortButton("歌手", .artist)
            sortButton("专辑", .album)
            Spacer(minLength: 8)
            sortButton("时长", .duration)
            sortButton("添加时间", .dateAdded)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
    }

    private func sortButton(_ title: String, _ candidate: TrackSort) -> some View {
        let active = model.sortsColumns && model.sort == candidate
        return Button {
            model.toggleSort(candidate)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if active {
                    Icons.sortArrow(ascending: model.sortAscending)
                }
            }
            .font(.system(size: 10.5, weight: active ? .semibold : .regular))
            .foregroundColor(active ? Theme.accentLight : Theme.text.opacity(0.45))
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(
                active ? Theme.accent.opacity(0.14) : Color.clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("按\(title)排序")
    }

    private var title: String {
        switch model.selection {
        case .allMusic:
            return "全部音乐"
        case .recentlyAdded:
            return "最近添加"
        case .folder(let folder):
            return folder.lastPathComponent
        case .playlist(let id):
            return model.playlists.playlists.first(where: { $0.id == id })?.name ?? "播放列表"
        }
    }

    private var meta: String {
        let tracks = model.visibleTracks
        let seconds = Int(tracks.reduce(0) { $0 + $1.duration })
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let duration = hours > 0 ? "\(hours) 小时 \(minutes) 分" : "\(minutes) 分钟"
        return "\(tracks.count) 首 · \(duration)"
    }

    private func handleReorder(_ providers: [NSItemProvider], onto target: Track) -> Bool {
        guard model.canReorderPlaylist else { return false }
        Task { @MainActor in
            for provider in providers {
                guard let text = await provider.textValue(),
                      let id = UUID(uuidString: text) else { continue }
                model.moveTrack(id, onto: target.id)
            }
        }
        return true
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
        let searching = !model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let playlistEmpty = model.isPlaylistSelection

        return VStack(spacing: 12) {
            Spacer(minLength: 0)
            Icons.emptyLibrary
                .foregroundColor(Theme.text.opacity(0.28))
            Text(emptyTitle(searching: searching, playlistEmpty: playlistEmpty))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.text.opacity(0.85))
            Text(emptyHint(searching: searching, playlistEmpty: playlistEmpty))
                .font(.system(size: 12))
                .foregroundColor(Theme.text.opacity(0.5))
                .multilineTextAlignment(.center)

            Button {
                if searching {
                    model.searchText = ""
                } else if model.tracks.isEmpty {
                    model.importFolders(model.openFolders())
                } else {
                    model.select(.allMusic)
                }
            } label: {
                Text(searching ? "清空搜索" : (model.tracks.isEmpty ? "选择文件夹" : "查看全部音乐"))
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

    private func emptyTitle(searching: Bool, playlistEmpty: Bool) -> String {
        if searching { return "没有匹配的歌曲" }
        if model.tracks.isEmpty { return "音乐库是空的" }
        if playlistEmpty { return "这个播放列表还是空的" }
        return "这个文件夹里没有歌曲"
    }

    private func emptyHint(searching: Bool, playlistEmpty: Bool) -> String {
        if searching { return "换个关键词，或清空搜索框。" }
        if model.tracks.isEmpty { return "把音乐文件或文件夹拖到这里，或者选择一个文件夹。" }
        if playlistEmpty { return "回到「全部音乐」，把歌曲拖进侧栏的播放列表。" }
        return "换一个文件夹，或回到「全部音乐」。"
    }
}

// MARK: - Row

private struct TrackRow: View {
    let track: Track
    let index: Int
    let isCurrent: Bool
    let isSelected: Bool
    let isPlaying: Bool
    let rowStyle: String
    let artworkURL: URL?
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        // A plain row instead of a `Button`: a Button swallows the drag
        // gesture, and dragging rows into playlists is required.
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
        .onTapGesture(perform: onTap)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var leading: some View {
        if isCurrent {
            PlayingIndicator(isPlaying: isPlaying)
        } else if rowStyle == "cover" {
            ArtworkThumbnail(url: artworkURL)
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
        if isSelected { return Theme.accent.opacity(0.09) }
        if isHovering { return Color.white.opacity(0.04) }
        return .clear
    }
}

// MARK: - Cover thumbnail

private struct ArtworkThumbnail: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Theme.coverGradient)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Icons.coverNote
                    .foregroundColor(Color.white.opacity(0.55))
            }
        }
        .frame(width: 24, height: 24)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .onAppear(perform: load)
        .onChange(of: url) { _ in load() }
    }

    private func load() {
        image = url.flatMap { NSImage(contentsOf: $0) }
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
