import AppKit
import SoundIsleCore
import SwiftUI

/// Preview sheet for 整理文件…: pick a template, a destination root and
/// move/copy, then review every source → destination pair before anything
/// touches the disk.
@MainActor
struct OrganizerPreviewView: View {
    let model: AppModel
    let tracks: [Track]

    @Environment(\.dismiss) private var dismiss

    @State private var template: String
    @State private var destinationRoot: URL
    @State private var copy = false
    @State private var errorMessage: String?

    private struct Preset: Identifiable, Hashable {
        let name: String
        let template: String
        var id: String { template }
    }

    private static let presets = [
        Preset(name: "歌手/专辑/曲目 歌名", template: "{artist}/{album}/{track} {title}"),
        Preset(name: "歌手 - 歌名", template: "{artist} - {title}"),
    ]

    init(model: AppModel, tracks: [Track]) {
        self.model = model
        self.tracks = tracks
        let root = tracks.first?.url.deletingLastPathComponent()
            ?? model.folders.first
            ?? FileManager.default.homeDirectoryForCurrentUser
        _template = State(initialValue: Self.presets[0].template)
        _destinationRoot = State(initialValue: root)
    }

    private var items: [OrganizePlanItem] {
        model.organizer.plan(tracks, template: template, root: destinationRoot, copy: copy)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            divider

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    options
                    summary
                    previewTable
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 11.5))
                            .foregroundColor(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }

            divider
            footer
        }
        .frame(width: 760, height: 620)
        .background(AppBackground())
        .preferredColorScheme(.dark)
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("整理文件")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Theme.text)
            Text("\(tracks.count) 首 · 预览后才会执行")
                .font(.system(size: 11.5))
                .foregroundColor(Theme.text.opacity(0.5))
            Spacer()
        }
        .padding(.horizontal, 22)
        .frame(height: 52)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(copy ? "原文件保留，只新增副本。" : "原文件夹中的文件会移到新路径。")
                .font(.system(size: 10.5))
                .foregroundColor(Theme.text.opacity(0.45))
            Spacer()
            Button("取消") { dismiss() }
            Button("开始整理") { confirm() }
                .keyboardShortcut(.defaultAction)
                .disabled(items.isEmpty)
        }
        .padding(.horizontal, 22)
        .frame(height: 56)
    }

    // MARK: - Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                optionLabel("模板")
                Picker("模板", selection: $template) {
                    ForEach(Self.presets) { preset in
                        Text(preset.name).tag(preset.template)
                    }
                }
                .labelsHidden()
                .frame(width: 240)
                Text(template)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(Theme.text.opacity(0.4))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                optionLabel("目标文件夹")
                Text(destinationRoot.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.text.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .help(destinationRoot.path)
                Button("选择…") { chooseRoot() }
            }

            HStack(spacing: 10) {
                optionLabel("方式")
                Picker("方式", selection: $copy) {
                    Text("移动").tag(false)
                    Text("复制").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
                Text("不会覆盖目标位置已有的同名文件。")
                    .font(.system(size: 10.5))
                    .foregroundColor(Theme.text.opacity(0.45))
                Spacer(minLength: 0)
            }
        }
    }

    private func optionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundColor(Theme.text.opacity(0.7))
            .frame(width: 66, alignment: .trailing)
    }

    private var summary: some View {
        let conflicts = items.filter(\.conflictResolved).count
        return HStack(spacing: 8) {
            Text("共 \(items.count) 个文件")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(Theme.text.opacity(0.75))
            if conflicts > 0 {
                Text("\(conflicts) 个同名冲突已自动编号，不会覆盖")
                    .font(.system(size: 10.5))
                    .foregroundColor(Theme.warning)
            }
            Spacer()
        }
    }

    // MARK: - Preview table

    private var previewTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("原路径")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("新路径")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(Theme.text.opacity(0.5))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Color.white.opacity(0.05))

            if items.isEmpty {
                Text("没有需要整理的文件，可能已经在目标位置。")
                    .font(.system(size: 11.5))
                    .foregroundColor(Theme.text.opacity(0.45))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                ForEach(items, id: \.destination) { item in
                    previewRow(item)
                    Rectangle()
                        .fill(Color.white.opacity(0.05))
                        .frame(height: 1)
                }
            }
        }
        .background(
            Color.white.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func previewRow(_ item: OrganizePlanItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(item.source.path)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(Theme.text.opacity(0.6))
            HStack(alignment: .top, spacing: 5) {
                Text("→")
                    .foregroundColor(Theme.accentLight.opacity(0.7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.destination.path)
                        .foregroundColor(Theme.text.opacity(0.9))
                    if item.conflictResolved {
                        Text("同名已避让")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundColor(Theme.warning)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.warning.opacity(0.14), in: Capsule())
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .lineLimit(2)
        .truncationMode(.middle)
        .help("\(item.source.path)\n→ \(item.destination.path)")
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
    }

    // MARK: - Actions

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择整理后的目标文件夹"
        let response = panel.runModal()
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard response == .OK, let url = panel.url else { return }
        destinationRoot = url
    }

    private func confirm() {
        let plan = items
        guard !plan.isEmpty else {
            errorMessage = "没有需要整理的文件。"
            return
        }

        if !copy {
            let crossesVolumes = plan.contains {
                FileOrganizer.crossesVolumes(source: $0.source, destination: $0.destination)
            }
            if crossesVolumes, !confirmCrossVolumeDelete() {
                return
            }
        }

        if let error = model.performOrganize(plan, copy: copy) {
            errorMessage = error
        } else {
            dismiss()
        }
    }

    /// Cross-volume moves are copy-then-delete in the core; get the user's
    /// explicit consent before the source copy is removed.
    private func confirmCrossVolumeDelete() -> Bool {
        let alert = NSAlert()
        alert.messageText = "目标位置在另一个磁盘"
        alert.informativeText = "会先把文件复制到目标位置，复制完成后再删除源文件。是否继续？"
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        NSApp.keyWindow?.makeFirstResponder(nil)
        return response == .alertFirstButtonReturn
    }
}
