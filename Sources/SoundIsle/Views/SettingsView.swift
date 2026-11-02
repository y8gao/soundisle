import SwiftUI

/// Placeholder shell for the settings screen. Tasks 6-14 fill each section in.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Section {
        let title: String
        let subtitle: String
        let icon: Image
    }

    private let sections = [
        Section(title: "音乐文件夹", subtitle: "导入目录、重新扫描与缺失文件", icon: Icons.settingsFolders),
        Section(title: "缓存", subtitle: "封面、频谱与临时文件占用", icon: Icons.settingsCache),
        Section(title: "歌词", subtitle: "桌面歌词与在线歌词来源", icon: Icons.settingsLyrics),
        Section(title: "外观", subtitle: "主题皮肤、明暗模式与透明度", icon: Icons.settingsAppearance),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.text)
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .frame(height: 52)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(sections.indices, id: \.self) { index in
                        let section = sections[index]
                        HStack(spacing: 13) {
                            section.icon
                                .foregroundColor(Theme.accent)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Theme.text)
                                Text(section.subtitle)
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.text.opacity(0.5))
                            }
                            Spacer(minLength: 12)
                            Text("即将提供")
                                .font(.system(size: 10.5))
                                .foregroundColor(Theme.text.opacity(0.35))
                        }
                        .padding(14)
                        .glassPanel(cornerRadius: 10)
                    }
                }
                .padding(22)
            }
        }
        .frame(width: 520, height: 440)
        .background(AppBackground())
        .preferredColorScheme(.dark)
    }
}
