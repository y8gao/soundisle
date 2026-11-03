import AppKit
import SoundIsleCore
import SwiftUI

/// Settings shell. Cache/FFmpeg and tag-undo controls arrived in tasks 11-13;
/// task 14 fills the lyrics and appearance groups and shows missing/unreadable
/// files collected by the scanner.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    /// Undo/clear feedback stays visible inside this sheet instead of only in
    /// the track list behind it.
    @State private var notice: String?
    @State private var folderNotice: String?
    @State private var cacheNotice: String?
    /// Identifies the sheet window so clicks inside it (and in nested
    /// popovers) can be distinguished from a click on the window behind.
    @State private var sheetWindow: NSWindow?
    @State private var outsideClickMonitor: Any?
    @State private var lyricsEndpointText = ""
    @State private var lyricsEndpointNotice: String?

    private var settings: AppSettings { model.library.settings }

    private var palette: ThemePalette {
        ThemePalette.resolve(
            preset: settings.preset,
            mode: settings.mode,
            customAccentHex: settings.customAccentHex,
            systemIsDark: colorScheme == .dark
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("设置")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(palette.text)
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .frame(height: 52)

            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)

            ScrollView {
                VStack(spacing: 10) {
                    tagEditingSection
                    missingFilesSection
                    cacheSection
                    lyricsSection
                    appearanceSection
                }
                .padding(22)
            }
        }
        // Keep the sheet shorter than the 600pt minimum main window so a
        // minimized window can still present it; the content scrolls.
        .frame(width: 580, height: 560)
        .background(AppBackground())
        .background(SheetWindowConfigurator { sheetWindow = $0 })
        .soundIsleTheme(palette)
        .onAppear {
            model.refreshTranscodeCacheSize()
            lyricsEndpointText = settings.lyricsEndpoint ?? ""
            installOutsideClickMonitor()
            // Don't let the endpoint field take the initial focus just because
            // it is the first text field in the sheet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .onDisappear {
            saveLyricsEndpoint()
            removeOutsideClickMonitor()
        }
    }

    // MARK: - Tag editing

    private var tagEditingSection: some View {
        sectionCard(icon: Icons.settingsTags, title: "标签编辑") {
            Text("每次保存都会记录修改前后的标签，最多保留 50 条。")
                .font(.system(size: 11))
                .foregroundColor(palette.mutedText(0.5))
            HStack(spacing: 10) {
                Button("撤销最近一次标签编辑") {
                    notice = model.undoLastTagEdit()
                }
                .disabled(!model.canUndoTagEdit || model.fileWorkProgress != nil)

                Button("清空编辑撤销记录") {
                    if confirmClearUndo() {
                        notice = model.clearTagUndoHistory()
                    }
                }
                .disabled(model.tagUndoCount == 0 || model.fileWorkProgress != nil)

                Text("\(model.tagUndoCount) 条记录")
                    .font(.system(size: 10.5))
                    .foregroundColor(palette.mutedText(0.4))
            }
            if let notice {
                Text(notice)
                    .font(.system(size: 10.5))
                    .foregroundColor(palette.accentLight)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Missing and unreadable files

    /// Folder management lives in the sidebar; this card only surfaces files
    /// the scanner could not find or read, and hides itself when there are none.
    @ViewBuilder
    private var missingFilesSection: some View {
        let missing = model.library.missingTracks
        let unreadable = model.library.unreadableURLs
        if !missing.isEmpty || !unreadable.isEmpty || folderNotice != nil {
            sectionCard(icon: Icons.settingsFolders, title: "文件状态") {
                if !missing.isEmpty {
                    HStack(spacing: 8) {
                        Text("缺失文件 \(missing.count) 首")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(palette.warning)
                        Spacer(minLength: 8)
                        Button("移除缺失条目") {
                            folderNotice = model.removeMissingTracks()
                        }
                    }
                    ForEach(missing) { track in
                        HStack(spacing: 8) {
                            Text("\(track.title) — \(track.url.lastPathComponent)")
                                .font(.system(size: 10.5))
                                .foregroundColor(palette.mutedText(0.45))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(track.url.path)
                            Spacer(minLength: 6)
                            Button("重新定位…") {
                                relocate(track)
                            }
                            .help("选择这个文件的新位置")
                            if FileManager.default.fileExists(atPath: track.url.path) {
                                Button("在 Finder 中显示") {
                                    NSWorkspace.shared.activateFileViewerSelecting([track.url])
                                }
                            }
                            Button("移除") {
                                folderNotice = model.removeMissingTrack(track)
                            }
                        }
                        .font(.system(size: 10.5))
                    }
                }

                if !unreadable.isEmpty {
                    Divider().overlay(palette.hairline)
                    Text("无法读取 \(unreadable.count) 个文件")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(palette.warning)
                    ForEach(unreadable.prefix(3), id: \.self) { url in
                        Text(url.lastPathComponent)
                            .font(.system(size: 10.5))
                            .foregroundColor(palette.mutedText(0.45))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if unreadable.count > 3 {
                        Text("另有 \(unreadable.count - 3) 个…")
                            .font(.system(size: 10.5))
                            .foregroundColor(palette.mutedText(0.35))
                    }
                }

                if let folderNotice {
                    Text(folderNotice)
                        .font(.system(size: 10.5))
                        .foregroundColor(palette.accentLight)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Cache

    private var cacheSection: some View {
        sectionCard(icon: Icons.settingsCache, title: "缓存") {
            Text("不支持的格式会转换为 ALAC 后缓存在这里，清理不会删除原始文件。")
                .font(.system(size: 11))
                .foregroundColor(palette.mutedText(0.5))
            HStack(spacing: 10) {
                Button("清理缓存") {
                    cacheNotice = model.clearTranscodeCache()
                }
                .disabled(model.transcodeCacheBytes == 0)
                Text(model.transcodeCacheSizeText)
                    .font(.system(size: 10.5))
                    .foregroundColor(palette.mutedText(0.4))
            }
            HStack(spacing: 10) {
                Text("FFmpeg")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(palette.text.opacity(0.7))
                Text(model.ffmpegPathText)
                    .font(.system(size: 10.5))
                    .foregroundColor(
                        model.ffmpegPathText == "未找到"
                            ? palette.warning
                            : palette.mutedText(0.5)
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
                    .foregroundColor(palette.accentLight)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Lyrics

    private var lyricsSection: some View {
        sectionCard(icon: Icons.settingsLyrics, title: "歌词") {
            Text("桌面歌词窗与在线歌词来源。")
                .font(.system(size: 11))
                .foregroundColor(palette.mutedText(0.5))

            Toggle(
                "启用在线歌词匹配",
                isOn: Binding(
                    get: { settings.onlineLyricsEnabled },
                    set: { model.setOnlineLyricsEnabled($0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .foregroundColor(palette.text.opacity(0.82))

            HStack(spacing: 10) {
                Text("歌词源地址")
                    .font(.system(size: 11.5))
                    .foregroundColor(palette.text.opacity(0.75))
                    .frame(width: 92, alignment: .leading)
                TextField(
                    "https://lrclib.net/api/get",
                    text: $lyricsEndpointText,
                    onEditingChanged: { editing in
                        if !editing { saveLyricsEndpoint() }
                    }
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onSubmit { saveLyricsEndpoint() }
                Button("恢复默认") {
                    lyricsEndpointText = ""
                    lyricsEndpointNotice = nil
                    _ = model.setLyricsEndpoint(nil)
                }
                .disabled(
                    settings.lyricsEndpoint == nil
                        && lyricsEndpointText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            Text("兼容 LRCLIB 接口；也可填直接返回 LRC 文本的地址")
                .font(.system(size: 10.5))
                .foregroundColor(palette.mutedText(0.45))
            if let lyricsEndpointNotice {
                Text(lyricsEndpointNotice)
                    .font(.system(size: 10.5))
                    .foregroundColor(palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Text("悬停背景不透明度")
                    .font(.system(size: 11.5))
                    .foregroundColor(palette.text.opacity(0.75))
                    .frame(width: 120, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { settings.lyricsOpacity },
                        set: { model.setLyricsOpacity($0) }
                    ),
                    in: 0.05...0.9
                )
                Text("\(Int((settings.lyricsOpacity * 100).rounded()))%")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundColor(palette.mutedText(0.5))
                    .frame(width: 36, alignment: .trailing)
            }

            Toggle(
                "歌词文字描边",
                isOn: Binding(
                    get: { settings.lyricsOutline },
                    set: { model.setLyricsOutline($0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .foregroundColor(palette.text.opacity(0.82))

            HStack(spacing: 10) {
                Text("显示行数")
                    .font(.system(size: 11.5))
                    .foregroundColor(palette.text.opacity(0.75))
                    .frame(width: 92, alignment: .leading)
                Picker(
                    "",
                    selection: Binding(
                        get: { settings.lyricsLineMode },
                        set: { model.setLyricsLineMode($0) }
                    )
                ) {
                    Text("单行").tag("one")
                    Text("双行").tag("two")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        sectionCard(icon: Icons.settingsAppearance, title: "外观") {
            Text("主题皮肤")
                .font(.system(size: 11))
                .foregroundColor(palette.mutedText(0.55))

            HStack(spacing: 8) {
                ForEach(ThemePreset.allCases, id: \.self) { preset in
                    presetSwatch(preset)
                }
            }

            HStack(spacing: 10) {
                Text("明暗模式")
                    .font(.system(size: 11.5))
                    .foregroundColor(palette.text.opacity(0.75))
                    .frame(width: 92, alignment: .leading)
                Picker(
                    "",
                    selection: Binding(
                        get: { settings.mode },
                        set: { model.setThemeMode($0) }
                    )
                ) {
                    ForEach(ThemeMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }

            HStack(spacing: 10) {
                Text("自定义强调色")
                    .font(.system(size: 11.5))
                    .foregroundColor(palette.text.opacity(0.75))
                    .frame(width: 92, alignment: .leading)
                ColorPicker("", selection: accentColorBinding, supportsOpacity: false)
                    .labelsHidden()
                Text("Aa")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(palette.onAccent)
                    .frame(width: 28, height: 22)
                    .background(palette.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .help("使用强调色时的文字对比度")
                Button("恢复默认") {
                    model.setCustomAccent(hex: nil)
                }
                .disabled(settings.customAccentHex == nil)
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Text("列表行样式")
                    .font(.system(size: 11.5))
                    .foregroundColor(palette.text.opacity(0.75))
                    .frame(width: 92, alignment: .leading)
                Picker(
                    "",
                    selection: Binding(
                        get: { settings.usesCoverRowStyle },
                        set: { model.setRowStyle(cover: $0) }
                    )
                ) {
                    Text("序号").tag(false)
                    Text("封面").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
                Spacer(minLength: 0)
            }

            Divider().overlay(palette.hairline)

            Toggle(
                "在播放条底部显示频谱",
                isOn: Binding(
                    get: { settings.showMainSpectrum },
                    set: { model.setShowMainSpectrum($0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .foregroundColor(palette.text.opacity(0.82))

            Toggle(
                "在屏幕录制中隐藏窗口",
                isOn: Binding(
                    get: { settings.hideFromScreenCapture },
                    set: { model.setHideFromScreenCapture($0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .foregroundColor(palette.text.opacity(0.82))

            Toggle(
                "迷你窗始终置顶",
                isOn: Binding(
                    get: { settings.miniAlwaysOnTop },
                    set: { model.setMiniAlwaysOnTop($0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .foregroundColor(palette.text.opacity(0.82))

            Toggle(
                "关闭主窗口后继续运行",
                isOn: Binding(
                    get: { settings.keepRunningOnClose },
                    set: { model.setKeepRunningOnClose($0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .foregroundColor(palette.text.opacity(0.82))
        }
    }

    private func presetSwatch(_ preset: ThemePreset) -> some View {
        let selected = settings.preset == preset
        let preview = ThemePalette(
            preset: preset,
            tokens: ThemeCatalog.tokens(for: preset, isDark: palette.isDark)
        )
        return Button {
            model.setThemePreset(preset)
        } label: {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [preview.backgroundMiddle, preview.accent],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 26)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(
                                selected ? palette.accent : palette.hairline,
                                lineWidth: selected ? 2 : 1
                            )
                    )
                Text(preset.displayName)
                    .font(.system(size: 9.5, weight: selected ? .semibold : .regular))
                    .foregroundColor(palette.text.opacity(selected ? 1 : 0.55))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(preset.displayName)
    }

    private var accentColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: settings.customAccentHex ?? palette.tokens.accentHex) },
            set: { model.setCustomAccent(hex: $0.hexString) }
        )
    }

    // MARK: - Pieces

    private func sectionCard<Content: View>(
        icon: Image,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 13) {
            icon
                .foregroundColor(palette.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(palette.text)
                content()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassPanel(cornerRadius: 10)
    }

    /// A click on the main window behind the sheet dismisses it. Clicks inside
    /// the sheet, in a nested popover (ColorPicker), or on chrome with no
    /// window are left alone.
    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            guard let window = event.window else { return event }
            if let sheetWindow, window === sheetWindow { return event }
            // Popovers and menus are their own panel windows; a click there is
            // still "inside" the settings interaction.
            if window is NSPanel || window.isSheet { return event }
            if window.className.contains("Popover") || window.className.contains("Menu") {
                return event
            }
            guard window.canBecomeMain else { return event }
            dismiss()
            return event
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    /// Saves on submit/focus loss. An invalid non-empty value keeps the text
    /// in place so it can be corrected, shows a notice, and is not persisted.
    private func saveLyricsEndpoint() {
        let trimmed = lyricsEndpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = model.setLyricsEndpoint(trimmed.isEmpty ? nil : trimmed) {
            lyricsEndpointNotice = message
        } else {
            lyricsEndpointNotice = nil
            lyricsEndpointText = settings.lyricsEndpoint ?? ""
        }
    }

    private func relocate(_ track: Track) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "重新定位"
        panel.message = "选择《\(track.title)》的新位置"
        panel.nameFieldStringValue = track.url.lastPathComponent
        let response = panel.runModal()
        NSApp.keyWindow?.makeFirstResponder(nil)
        guard response == .OK, let url = panel.url else { return }
        folderNotice = model.relocateTrack(track, to: url)
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

// MARK: - Sheet window

/// A sheet is its own window; clearing it lets the `AppBackground` material
/// blur the main window instead of painting an opaque sheet.
private struct SheetWindowConfigurator: NSViewRepresentable {
    var onWindow: ((NSWindow) -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            onWindow?(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
