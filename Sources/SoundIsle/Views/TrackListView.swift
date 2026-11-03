import AppKit
import Foundation
import SoundIsleCore
import SwiftUI
import UniformTypeIdentifiers

/// One source of truth for the list's five columns. Header buttons and every
/// row use the same widths, so labels stay over their data at any window
/// width. The compact target is 900pt: 190 sidebar + 36 outer padding leaves
/// room for title to flex next to these fixed columns.
enum TrackColumns {
    static let leading: CGFloat = 24
    static let spacing: CGFloat = 10
    static let rowPadding: CGFloat = 8
    static let artist: CGFloat = 110
    static let album: CGFloat = 130
    static let duration: CGFloat = 50
    static let added: CGFloat = 82
    static let rowHeight: CGFloat = 34
}

struct TrackListView: View {
    @ObservedObject var model: AppModel
    @Environment(\.theme) private var theme
    @State private var contextMenuTrackID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            columnHeader

            if let progress = model.fileWorkProgress {
                progressBanner(progress)
            }

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
                                onTap: { model.handleTrackClick(track.id) },
                                onContextMenu: { contextMenuTrackID = track.id }
                            )
                            .onDrag {
                                NSItemProvider(object: track.id.uuidString as NSString)
                            }
                            .onDrop(of: [UTType.utf8PlainText], isTargeted: nil) { providers in
                                handleReorder(providers, onto: track)
                            }
                            .popover(
                                isPresented: Binding(
                                    get: { contextMenuTrackID == track.id },
                                    set: { presented in
                                        if !presented, contextMenuTrackID == track.id {
                                            contextMenuTrackID = nil
                                        }
                                    }
                                ),
                                arrowEdge: .bottom
                            ) {
                                TrackContextMenu(
                                    model: model,
                                    trackID: track.id
                                ) {
                                    contextMenuTrackID = nil
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
                .foregroundColor(theme.text)
                .lineLimit(1)
            Text(meta)
                .font(.system(size: 11.5))
                .foregroundColor(theme.mutedText(0.5))
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
                        .foregroundColor(theme.mutedText(0.5))
                }
            }

            Button {
                Task { await model.rescan() }
            } label: {
                Icons.refresh
                    .foregroundColor(theme.text.opacity(model.folders.isEmpty ? 0.25 : 0.6))
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
        HStack(spacing: TrackColumns.spacing) {
            Color.clear
                .frame(width: TrackColumns.leading, height: 1)
            sortButton("标题", .title, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortButton("歌手", .artist, alignment: .leading)
                .frame(width: TrackColumns.artist, alignment: .leading)
            sortButton("专辑", .album, alignment: .leading)
                .frame(width: TrackColumns.album, alignment: .leading)
            sortButton("时长", .duration, alignment: .trailing)
                .frame(width: TrackColumns.duration, alignment: .trailing)
            sortButton("添加时间", .dateAdded, alignment: .trailing)
                .frame(width: TrackColumns.added, alignment: .trailing)
        }
        .padding(.horizontal, TrackColumns.rowPadding)
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
    }

    private func sortButton(
        _ title: String,
        _ candidate: TrackSort,
        alignment: Alignment
    ) -> some View {
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
            .foregroundColor(active ? theme.accentLight : theme.mutedText(0.45))
            .frame(height: 22)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(theme.accent.opacity(0.14))
                        .padding(.horizontal, -6)
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
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

    private func progressBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.65)
                .frame(width: 12, height: 12)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundColor(theme.text.opacity(0.82))
            Spacer(minLength: 6)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(theme.accent.opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 1)
        }
    }

    private func statusBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Icons.warning
                    .foregroundColor(theme.warning)
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundColor(theme.text.opacity(0.82))
                    .lineLimit(2)
                Spacer(minLength: 6)
                Button {
                    model.dismissStatus()
                } label: {
                    Icons.close
                        .foregroundColor(theme.mutedText(0.5))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            if model.showsFFmpegInstallPrompt {
                HStack(spacing: 12) {
                    Button("复制 brew install ffmpeg") {
                        model.copyFFmpegInstallCommand()
                    }
                    Button("重新检测") {
                        model.redetectFFmpeg()
                    }
                    Button("选择 FFmpeg…") {
                        model.chooseFFmpegPath()
                    }
                    Text("原生格式仍可正常播放")
                        .foregroundColor(theme.mutedText(0.45))
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10.5))
                .buttonStyle(.plain)
                .foregroundColor(theme.accentLight)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(
            theme.warning.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.warning.opacity(0.3), lineWidth: 0.5)
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
                .foregroundColor(theme.mutedText(0.28))
            Text(emptyTitle(searching: searching, playlistEmpty: playlistEmpty))
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(theme.text.opacity(0.85))
            Text(emptyHint(searching: searching, playlistEmpty: playlistEmpty))
                .font(.system(size: 12))
                .foregroundColor(theme.mutedText(0.5))
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
                    .foregroundColor(theme.accentLight)
                    .padding(.horizontal, 16)
                    .frame(height: 30)
                    .background(
                        theme.accent.opacity(0.16),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.accent.opacity(0.35), lineWidth: 0.5)
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
    @Environment(\.theme) private var theme
    let track: Track
    let index: Int
    let isCurrent: Bool
    let isSelected: Bool
    let isPlaying: Bool
    let rowStyle: String
    let artworkURL: URL?
    let onTap: () -> Void
    let onContextMenu: () -> Void

    @State private var isHovering = false

    private static let addedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    var body: some View {
        // A plain row instead of a `Button`: a Button swallows the drag
        // gesture, and dragging rows into playlists is required.
        HStack(spacing: TrackColumns.spacing) {
            leading
                .frame(width: TrackColumns.leading)

            HStack(spacing: 6) {
                Text(track.title)
                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                    .foregroundColor(titleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                if track.isMissing {
                    Text("文件缺失")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(theme.warning)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(theme.warning.opacity(0.14), in: Capsule())
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(track.artist)
                .font(.system(size: 10.5))
                .foregroundColor(theme.mutedText(0.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: TrackColumns.artist, alignment: .leading)

            Text(track.album)
                .font(.system(size: 10.5))
                .foregroundColor(theme.mutedText(0.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: TrackColumns.album, alignment: .leading)

            Text(TimeText.string(track.duration))
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundColor(theme.mutedText(0.45))
                .frame(width: TrackColumns.duration, alignment: .trailing)

            Text(Self.addedFormatter.string(from: track.modifiedAt))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundColor(theme.mutedText(0.4))
                .frame(width: TrackColumns.added, alignment: .trailing)
        }
        .padding(.horizontal, TrackColumns.rowPadding)
        .frame(height: TrackColumns.rowHeight)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { isHovering = $0 }
        // Overlay rather than background: the catcher claims only right-click
        // events, so left-click play, drag and multi-select keep working.
        .overlay {
            RightClickCatcher(onRightClick: onContextMenu)
        }
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
                .foregroundColor(theme.mutedText(0.4))
        }
    }

    private var titleColor: Color {
        if track.isMissing { return theme.mutedText(0.45) }
        return isCurrent ? theme.accentLight : theme.text
    }

    private var rowBackground: Color {
        if isCurrent { return theme.accent.opacity(0.13) }
        if isSelected { return theme.accent.opacity(0.09) }
        if isHovering { return theme.raisedFill }
        return .clear
    }
}

// MARK: - Right-click catcher

/// Claims right-clicks without stealing anything else. AppKit asks `hitTest`
/// while dispatching an event, so returning nil for every non-right-mouse
/// event leaves SwiftUI's tap and drag gestures untouched.
private struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CatcherView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onRightClick = onRightClick
    }

    private final class CatcherView: NSView {
        var onRightClick: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return super.hitTest(point)
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick?()
        }
    }
}

// MARK: - Track context menu

/// Themed replacement for the system context menu. The popover owns dismissal
/// (click-away and Esc); `onClose` also lets each action close it before
/// opening a sheet or mutating the queue.
private struct TrackContextMenu: View {
    @ObservedObject var model: AppModel
    let trackID: UUID
    let onClose: () -> Void

    @Environment(\.theme) private var theme
    @State private var hoveredID: String?

    private var targetIDs: [UUID] { model.contextTrackIDs(for: trackID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            action("pencil", "编辑标签…") {
                model.beginTagEdit(trackIDs: targetIDs)
            }
            action("wand.and.stars", "修复乱码标签…") {
                model.promptRepairMojibake(trackIDs: targetIDs)
            }
            action("folder", "整理文件…") {
                model.beginOrganize(trackIDs: targetIDs)
            }
            action("trash", "从音乐库移除") {
                model.removeTracksFromLibrary(targetIDs)
            }

            separator

            if case .playlist(let playlistID) = model.selection {
                action("minus.circle", "从播放列表移除") {
                    for id in targetIDs {
                        model.removeFromPlaylist(playlistID, trackID: id)
                    }
                }
                separator
            }

            playlistSection
        }
        .padding(5)
        .frame(width: 240)
        .glassPanel(cornerRadius: 10)
        .shadow(
            color: .black.opacity(theme.isDark ? 0.5 : 0.18),
            radius: 16,
            y: 6
        )
        .onExitCommand(perform: onClose)
    }

    private var playlistSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("添加到播放列表")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(theme.mutedText(0.42))
                .padding(.horizontal, 8)
                .padding(.top, 3)
                .padding(.bottom, 3)

            if model.playlists.playlists.isEmpty {
                Text("暂无播放列表")
                    .font(.system(size: 11))
                    .foregroundColor(theme.mutedText(0.35))
                    .padding(.horizontal, 8)
                    .frame(height: 26)
            } else {
                ScrollView(showsIndicators: true) {
                    VStack(spacing: 1) {
                        ForEach(model.playlists.playlists) { playlist in
                            action("music.note.list", playlist.name) {
                                model.addToPlaylist(playlist.id, trackIDs: targetIDs)
                            }
                        }
                    }
                }
                .frame(maxHeight: min(CGFloat(model.playlists.playlists.count) * 28, 168))
            }
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(theme.hairline)
            .frame(height: 1)
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
    }

    private func action(
        _ symbol: String,
        _ title: String,
        run: @escaping () -> Void
    ) -> some View {
        let key = "\(symbol)-\(title)"
        return Button {
            onClose()
            run()
        } label: {
            HStack(spacing: 8) {
                Icons.symbol(symbol, size: 11)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundColor(theme.text.opacity(0.9))
            .padding(.horizontal, 8)
            .frame(height: 27)
            .background(
                hoveredID == key ? theme.accent.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hoveredID = key
            } else if hoveredID == key {
                hoveredID = nil
            }
        }
    }
}

// MARK: - Cover thumbnail

private struct ArtworkThumbnail: View {
    @Environment(\.theme) private var theme
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(theme.coverGradient)
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
    @Environment(\.theme) private var theme
    let isPlaying: Bool

    private let heights: [CGFloat] = [5, 11, 8]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { bar in
                Capsule()
                    .fill(theme.accent)
                    .frame(width: 2.5, height: isPlaying ? heights[bar] : 3)
            }
        }
        .frame(width: 14, height: 12, alignment: .bottom)
    }
}
