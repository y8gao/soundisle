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

                    sectionLabel("导入文件夹").padding(.top, 12)
                    if model.folders.isEmpty {
                        emptyRow("尚未导入文件夹")
                    } else {
                        ForEach(model.folders, id: \.self) { folder in
                            libraryRow(
                                title: folder.lastPathComponent,
                                icon: Icons.folder,
                                count: model.trackCount(in: folder),
                                isSelected: selection == .folder(folder)
                            ) {
                                model.select(.folder(folder))
                            }
                            .help(folder.path)
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

            Spacer(minLength: 0)

            Button {
                model.importFolders(model.openFolders())
            } label: {
                HStack(spacing: 7) {
                    Icons.addFolder
                    Text("添加文件夹")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12))
                .foregroundColor(theme.text.opacity(0.7))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isScanning)
            .opacity(model.isScanning ? 0.45 : 1)
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
            .help("从磁盘选择音乐文件夹")
        }
        .frame(maxHeight: .infinity)
        .background(theme.raisedFill.opacity(0.35))
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.hairline)
                .frame(width: 1)
        }
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
