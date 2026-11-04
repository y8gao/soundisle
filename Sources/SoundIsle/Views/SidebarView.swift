import AppKit
import SoundIsleCore
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.theme) private var theme
    @State private var dropTargetID: UUID?

    private var selection: LibrarySelection { model.selection }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sectionLabel("音乐库")
                    libraryRow(
                        title: "全部音乐",
                        icon: Icons.allMusic,
                        count: model.tracks.count,
                        isSelected: selection == .allMusic
                    ) {
                        model.select(.allMusic)
                    }
                    libraryRow(
                        title: "最近添加",
                        icon: Icons.recent,
                        count: model.tracks.count,
                        isSelected: selection == .recentlyAdded
                    ) {
                        model.select(.recentlyAdded)
                    }

                    foldersHeader
                    if model.folders.isEmpty {
                        emptyRow("尚未导入文件夹")
                    } else {
                        ForEach(model.folders, id: \.self) { folder in
                            FolderRow(
                                title: folder.lastPathComponent,
                                count: model.trackCount(in: folder),
                                isSelected: selection == .folder(folder),
                                path: folder.path,
                                onSelect: { model.select(.folder(folder)) },
                                onRefresh: {
                                    Task { await model.rescanFolder(folder) }
                                },
                                onRemove: { confirmRemoveFolder(folder) }
                            )
                            .contextMenu {
                                Button("重命名文件夹…") { promptRenameFolder(folder) }
                            }
                        }
                    }

                    playlistsHeader
                    if model.playlists.playlists.isEmpty {
                        emptyRow("暂无播放列表")
                    } else {
                        ForEach(model.playlists.playlists) { playlist in
                            playlistRow(playlist)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
            }
        }
        .frame(maxHeight: .infinity)
        // Fixed theme gradient instead of a system material: NSVisualEffectView
        // changes with window activity, which made the sidebar flip black or
        // white when another app became active.
        // A tonal scrim over the window's single gradient: same palette,
        // just enough separation for the sidebar. No system material, so it
        // stays identical when the window is inactive.
        .background(theme.backgroundTop.opacity(theme.isDark ? 0.28 : 0.34))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.hairline)
                .frame(width: 1)
        }
    }

    private var foldersHeader: some View {
        HStack(spacing: 0) {
            sectionLabel("导入文件夹")
            Spacer(minLength: 4)
            Button {
                model.importFolders(model.openFolders())
            } label: {
                Icons.plus
                    .foregroundColor(theme.mutedText(0.55))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isScanning)
            .opacity(model.isScanning ? 0.45 : 1)
            .help("导入文件夹")
            .padding(.trailing, 4)
        }
        .padding(.top, 12)
    }

    private var playlistsHeader: some View {
        HStack(spacing: 0) {
            sectionLabel("播放列表")
            Spacer(minLength: 4)
            Button {
                model.promptCreatePlaylist()
            } label: {
                Icons.plus
                    .foregroundColor(theme.mutedText(0.55))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("新建播放列表")
            .padding(.trailing, 4)
        }
        .padding(.top, 12)
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        libraryRow(
            title: playlist.name,
            icon: Icons.playlist,
            count: model.resolvableTrackCount(in: playlist),
            isSelected: selection == .playlist(playlist.id),
            isDropTarget: dropTargetID == playlist.id
        ) {
            model.select(.playlist(playlist.id))
        }
        .contextMenu {
            Button("重命名") { model.promptRenamePlaylist(id: playlist.id) }
            Button("删除") { model.confirmDeletePlaylist(id: playlist.id) }
        }
        .onDrop(
            of: [UTType.utf8PlainText],
            isTargeted: Binding(
                get: { dropTargetID == playlist.id },
                set: { targeted in
                    if targeted {
                        dropTargetID = playlist.id
                    } else if dropTargetID == playlist.id {
                        dropTargetID = nil
                    }
                }
            )
        ) { providers in
            guard handleTrackDrop(providers, into: playlist.id) else { return false }
            dropTargetID = nil
            return true
        }
    }

    private func handleTrackDrop(_ providers: [NSItemProvider], into playlistID: UUID) -> Bool {
        Task { @MainActor in
            var trackIDs: [UUID] = []
            for provider in providers {
                if let text = await provider.textValue(),
                   let id = UUID(uuidString: text) {
                    trackIDs.append(id)
                }
            }
            model.addToPlaylist(playlistID, trackIDs: trackIDs)
        }
        return true
    }

    private func emptyRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Icons.playlist
                .foregroundColor(theme.mutedText(0.3))
            Text(text)
                .font(.system(size: 11.5))
                .foregroundColor(theme.mutedText(0.35))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
    }

    /// Neutral copy: the folder and its rows leave the library, the audio
    /// files stay exactly where they are on disk.
    private func confirmRemoveFolder(_ folder: URL) {
        let alert = NSAlert()
        alert.messageText = "从曲库移除「\(folder.lastPathComponent)」？"
        alert.informativeText = "只会从曲库移除这个文件夹和其中的歌曲，磁盘上的音频文件不会被删除。"
        alert.addButton(withTitle: "移除")
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard response == .alertFirstButtonReturn else { return }
        model.removeFolder(folder)
    }

    /// Renames the directory on disk; the core validates the name and refuses
    /// to overwrite an existing folder. Failures surface in the status banner.
    private func promptRenameFolder(_ folder: URL) {
        let alert = NSAlert()
        alert.messageText = "重命名文件夹"
        alert.informativeText = "输入新的文件夹名称，磁盘上的音频文件不会被删除。"
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = folder.lastPathComponent
        field.placeholderString = "文件夹名称"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard response == .alertFirstButtonReturn else { return }
        model.renameFolder(folder, to: field.stringValue)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.1)
            .foregroundColor(theme.mutedText(0.42))
            .padding(.horizontal, 9)
            .padding(.top, 4)
            .padding(.bottom, 5)
    }

    private func libraryRow(
        title: String,
        icon: Image,
        count: Int,
        isSelected: Bool,
        isDropTarget: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon
                    .frame(width: 16)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundColor(theme.mutedText(isSelected ? 0.7 : 0.4))
            }
            .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
            .foregroundColor(isSelected ? theme.accentLight : theme.text.opacity(0.64))
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(
                isDropTarget
                    ? theme.accent.opacity(0.28)
                    : (isSelected ? theme.accent.opacity(0.16) : Color.clear),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(theme.accent.opacity(isDropTarget ? 0.6 : 0), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Folder row

/// Imported-folder row with hover actions. A plain tap row (instead of a
/// Button label) keeps the refresh/trash buttons independently clickable.
private struct FolderRow: View {
    @Environment(\.theme) private var theme
    let title: String
    let count: Int
    let isSelected: Bool
    let path: String
    let onSelect: () -> Void
    let onRefresh: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Icons.folder
                .frame(width: 16)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)

            if isHovering {
                iconButton(Icons.refresh, help: "重新扫描此文件夹", action: onRefresh)
                iconButton(Icons.symbol("trash", size: 11), help: "移除文件夹（不删除文件）", action: onRemove)
            } else {
                Text("\(count)")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundColor(theme.mutedText(isSelected ? 0.7 : 0.4))
            }
        }
        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
        .foregroundColor(isSelected ? theme.accentLight : theme.text.opacity(0.64))
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(
            isSelected ? theme.accent.opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .help(path)
    }

    private func iconButton(
        _ icon: Image,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            icon
                .foregroundColor(theme.mutedText(0.6))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
