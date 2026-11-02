import AppKit
import SwiftUI

/// Settings shell. Tasks 12-14 fill the remaining sections in; tag editing
/// already exposes its undo controls here.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Undo/clear feedback stays visible inside this sheet instead of only in
    /// the track list behind it.
    @State private var notice: String?
    @State private var cacheNotice: String?

    private struct Section {
        let title: String
        let subtitle: String
        let icon: Image
    }

    private let sections = [
        Section(title: "音乐文件夹", subtitle: "导入目录、重新扫描与缺失文件", icon: Icons.settingsFolders),
        Section(title: "缓存", subtitle: "转码缓存占用与 FFmpeg 路径", icon: Icons.settingsCache),
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
                    tagEditingSection

                    ForEach(sections.indices, id: \.self) { index in
                        let section = sections[index]
                        if section.title == "缓存" {
                            cacheSection
                        } else {
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
                }
                .padding(22)
            }
        }
        .frame(width: 520, height: 440)
        .background(AppBackground())
        .preferredColorScheme(.dark)
        .onAppear { model.refreshTranscodeCacheSize() }
    }

    private var tagEditingSection: some View {
        HStack(alignment: .top, spacing: 13) {
            Icons.settingsTags
                .foregroundColor(Theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 7) {
                Text("标签编辑")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.text)
                Text("每次保存都会记录修改前后的标签，最多保留 50 条。")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.text.opacity(0.5))
                HStack(spacing: 10) {
                    Button("撤销最近一次标签编辑") {
                        notice = model.undoLastTagEdit()
                    }
                    .disabled(!model.canUndoTagEdit)

                    Button("清空编辑撤销记录") {
                        if confirmClearUndo() {
                            notice = model.clearTagUndoHistory()
                        }
                    }
                    .disabled(model.tagUndoCount == 0)

                    Text("\(model.tagUndoCount) 条记录")
                        .font(.system(size: 10.5))
                        .foregroundColor(Theme.text.opacity(0.4))
                }
                if let notice {
                    Text(notice)
                        .font(.system(size: 10.5))
                        .foregroundColor(Theme.accentLight)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassPanel(cornerRadius: 10)
    }

    private var cacheSection: some View {
        HStack(alignment: .top, spacing: 13) {
            Icons.settingsCache
                .foregroundColor(Theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 8) {
                Text("缓存")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.text)
                Text("不支持的格式会转换为 ALAC 后缓存在这里，清理不会删除原始文件。")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.text.opacity(0.5))
                HStack(spacing: 10) {
                    Button("清理缓存") {
                        cacheNotice = model.clearTranscodeCache()
                    }
                    .disabled(model.transcodeCacheBytes == 0)
                    Text(model.transcodeCacheSizeText)
                        .font(.system(size: 10.5))
                        .foregroundColor(Theme.text.opacity(0.4))
                }
                HStack(spacing: 10) {
                    Text("FFmpeg")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.text.opacity(0.7))
                    Text(model.ffmpegPathText)
                        .font(.system(size: 10.5))
                        .foregroundColor(
                            model.ffmpegPathText == "未找到"
                                ? Theme.warning
                                : Theme.text.opacity(0.5)
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Button("重新检测") {
                        cacheNotice = model.redetectFFmpeg()
                    }
                    Button("选择文件…") {
                        if let message = model.chooseFFmpegPath() {
                            cacheNotice = message
                        }
                    }
                }
                if let cacheNotice {
                    Text(cacheNotice)
                        .font(.system(size: 10.5))
                        .foregroundColor(Theme.accentLight)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassPanel(cornerRadius: 10)
    }

    private func confirmClearUndo() -> Bool {
        let alert = NSAlert()
        alert.messageText = "清空编辑撤销记录？"
        alert.informativeText = "清空后无法再撤销之前保存的标签修改，音频文件本身不受影响。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        NSApp.keyWindow?.makeFirstResponder(nil)
        return response == .alertFirstButtonReturn
    }
}
