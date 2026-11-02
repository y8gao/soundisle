import SwiftUI

struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sectionLabel("音乐库")
                    libraryRow(
                        title: "全部音乐",
                        icon: Icons.allMusic,
                        count: model.tracks.count,
                        isSelected: model.selectedFolder == nil
                    ) {
                        model.selectedFolder = nil
                    }

                    sectionLabel("导入文件夹").padding(.top, 12)
                    if model.folders.isEmpty {
                        Text("尚未导入文件夹")
                            .font(.system(size: 11.5))
                            .foregroundColor(Theme.text.opacity(0.35))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                    } else {
                        ForEach(model.folders, id: \.self) { folder in
                            libraryRow(
                                title: folder.lastPathComponent,
                                icon: Icons.folder,
                                count: model.trackCount(in: folder),
                                isSelected: isSelected(folder)
                            ) {
                                model.selectedFolder = folder
                            }
                            .help(folder.path)
                        }
                    }

                    sectionLabel("播放列表").padding(.top, 12)
                    HStack(spacing: 8) {
                        Icons.playlist
                            .foregroundColor(Theme.text.opacity(0.3))
                        Text("暂无播放列表")
                            .font(.system(size: 11.5))
                            .foregroundColor(Theme.text.opacity(0.35))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
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
                .foregroundColor(Theme.text.opacity(0.7))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
            .help("从磁盘选择音乐文件夹")
        }
        .frame(maxHeight: .infinity)
        .background(Color.white.opacity(0.02))
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 1)
        }
    }

    private func isSelected(_ folder: URL) -> Bool {
        guard let selected = model.selectedFolder else { return false }
        return selected.standardizedFileURL == folder.standardizedFileURL
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.1)
            .foregroundColor(Theme.text.opacity(0.42))
            .padding(.horizontal, 9)
            .padding(.top, 4)
            .padding(.bottom, 5)
    }

    private func libraryRow(
        title: String,
        icon: Image,
        count: Int,
        isSelected: Bool,
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
                    .foregroundColor(Theme.text.opacity(isSelected ? 0.7 : 0.4))
            }
            .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
            .foregroundColor(isSelected ? Theme.accentLight : Theme.text.opacity(0.64))
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(
                isSelected ? Theme.accent.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
