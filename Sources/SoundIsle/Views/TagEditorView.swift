import AppKit
import SoundIsleCore
import SwiftUI
import UniformTypeIdentifiers

/// Sheet for editing one track or a batch. Blank text fields mean "leave this
/// field alone"; a cover is only written when the user picks or removes one.
@MainActor
struct TagEditorView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: AppModel
    let tracks: [Track]

    @Environment(\.dismiss) private var dismiss

    private var palette: ThemePalette {
        let settings = model.library.settings
        return ThemePalette.resolve(
            preset: settings.preset,
            mode: settings.mode,
            customAccentHex: settings.customAccentHex,
            systemIsDark: colorScheme == .dark
        )
    }

    /// Combined once per presentation: WAV probing reads chunk headers from
    /// disk, so it must not run on every SwiftUI body evaluation.
    private let capabilities: TagFormatCapabilities

    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var albumArtist = ""
    @State private var year = ""
    @State private var trackNumber = ""
    @State private var genre = ""

    /// nil = keep the current cover, "" = remove it, otherwise new base64.
    @State private var artworkEdit: String?
    @State private var currentArtworkBase64: String?
    @State private var previewImage: NSImage?
    @State private var errorMessage: String?
    @State private var didLoad = false
    /// Single-track prefill, used to detect which fields the user actually
    /// touched so an emptied field can be cleared rather than ignored.
    @State private var initialFields: TagFields?

    init(model: AppModel, tracks: [Track]) {
        _model = ObservedObject(wrappedValue: model)
        self.tracks = tracks
        self.capabilities = TagFormatCapabilities.combined(for: tracks.map(\.url))
    }

    private var isBatch: Bool { tracks.count > 1 }

    private var canEditAlbumArtist: Bool {
        capabilities.canWrite && capabilities.canWriteAlbumArtist
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(palette.hairline)
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    if isBatch {
                        Text(Lf("正在批量编辑 %d 首歌曲。留空的字段不会被修改。", tracks.count))
                            .font(.system(size: 11.5))
                            .foregroundColor(palette.text.opacity(0.6))
                    }
                    if let limitation = capabilities.limitation {
                        limitationNote(limitation)
                    }

                    VStack(alignment: .leading, spacing: 11) {
                        TagTextFieldRow(
                            label: L("标题"),
                            text: $title,
                            disabled: !capabilities.canWrite,
                            placeholder: placeholder(L("标题"))
                        )
                        TagTextFieldRow(
                            label: L("歌手"),
                            text: $artist,
                            disabled: !capabilities.canWrite,
                            placeholder: placeholder(L("歌手"))
                        )
                        TagTextFieldRow(
                            label: L("专辑"),
                            text: $album,
                            disabled: !capabilities.canWrite,
                            placeholder: placeholder(L("专辑"))
                        )
                        TagTextFieldRow(
                            label: L("专辑歌手"),
                            text: $albumArtist,
                            disabled: !canEditAlbumArtist,
                            placeholder: placeholder(L("专辑歌手"))
                        )
                    }

                    VStack(alignment: .leading, spacing: 11) {
                        TagNumberFieldRow(
                            label: L("年份"),
                            text: $year,
                            disabled: !capabilities.canWrite,
                            placeholder: placeholder(L("年份"))
                        )
                        TagNumberFieldRow(
                            label: L("曲目号"),
                            text: $trackNumber,
                            disabled: !capabilities.canWrite,
                            placeholder: placeholder(L("曲目号"))
                        )
                        TagTextFieldRow(
                            label: L("流派"),
                            text: $genre,
                            disabled: !capabilities.canWrite,
                            placeholder: placeholder(L("流派"))
                        )
                    }

                    coverSection

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 11.5))
                            .foregroundColor(palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if isBatch {
                        Text(L("留空的文本字段不会被修改。"))
                            .font(.system(size: 10.5))
                            .foregroundColor(palette.mutedText(0.4))
                    }
                }
                .padding(22)
            }

            footer
        }
        .frame(width: 540, height: 590)
        .background(AppBackground())
        .soundIsleTheme(palette)
        .onAppear(perform: loadInitialValues)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(isBatch ? L("批量编辑标签") : L("编辑标签"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(palette.text)
            Text(isBatch ? Lf("%d 首", tracks.count) : tracks.first?.title ?? "")
                .font(.system(size: 11.5))
                .foregroundColor(palette.mutedText(0.5))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 22)
        .frame(height: 52)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let progress = model.fileWorkProgress {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
                Text(progress)
                    .font(.system(size: 10.5))
                    .foregroundColor(palette.text.opacity(0.6))
            }
            Spacer()
            Button(L("取消")) { dismiss() }
                .disabled(model.fileWorkProgress != nil)
            Button(L("保存")) { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!capabilities.canWrite || tracks.isEmpty || model.fileWorkProgress != nil)
        }
        .padding(.horizontal, 22)
        .frame(height: 54)
    }

    private func placeholder(_ label: String) -> String {
        isBatch ? L("留空不修改") : label
    }

    private func limitationNote(_ text: String) -> some View {
        HStack(spacing: 7) {
            Icons.warning
                .foregroundColor(palette.warning)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(palette.text.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            palette.warning.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
    }

    // MARK: - Cover

    @ViewBuilder
    private var coverSection: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(palette.coverGradient)
                if let image = displayedCover {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Icons.coverNote
                        .foregroundColor(Color.white.opacity(0.55))
                }
            }
            .frame(width: 68, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button(L("选择封面…")) { chooseCover() }
                    if artworkEdit != nil || currentArtworkBase64 != nil {
                        Button(L("移除封面")) {
                            artworkEdit = ""
                            previewImage = nil
                        }
                    }
                }
                .disabled(!capabilities.canWriteArtwork)
                Text(coverHint)
                    .font(.system(size: 10.5))
                    .foregroundColor(palette.mutedText(0.5))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private var displayedCover: NSImage? {
        if artworkEdit == "" { return nil }
        if let previewImage { return previewImage }
        if let base64 = currentArtworkBase64, let data = Data(base64Encoded: base64) {
            return NSImage(data: data)
        }
        return nil
    }

    private var coverHint: String {
        if !capabilities.canWriteArtwork {
            return capabilities.limitation ?? L("该格式不支持写入封面。")
        }
        if artworkEdit == "" { return L("保存后将移除封面。") }
        if artworkEdit != nil { return L("已选择新封面，保存后写入。") }
        if isBatch { return L("留空则不修改封面。") }
        return currentArtworkBase64 == nil ? L("无封面") : L("当前封面")
    }

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("选择")
        panel.message = L("选择封面图片")
        panel.allowedContentTypes = [.png, .jpeg, .gif, .bmp, .tiff]
        guard panel.runModal() == .OK,
              let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        artworkEdit = data.base64EncodedString()
        previewImage = NSImage(data: data)
    }

    // MARK: - Load / save

    private func loadInitialValues() {
        guard !didLoad else { return }
        didLoad = true
        guard tracks.count == 1,
              let fields = model.tagService.read(from: tracks[0].url) else { return }
        initialFields = fields
        title = fields.title ?? ""
        artist = fields.artist ?? ""
        album = fields.album ?? ""
        albumArtist = fields.albumArtist ?? ""
        year = fields.year.map(String.init) ?? ""
        trackNumber = fields.trackNumber.map(String.init) ?? ""
        genre = fields.genre ?? ""
        currentArtworkBase64 = fields.artworkBase64
    }

    private func save() {
        guard let edits = buildEdits() else { return }
        let tracks = tracks
        Task {
            if let error = await model.applyTagEdit(edits, to: tracks) {
                errorMessage = error
            } else {
                dismiss()
            }
        }
    }

    /// Batch mode: blank means "leave unchanged". Single mode: compare with
    /// the prefilled values so clearing a field sends "" (a real clear) and
    /// untouched fields stay nil. Unsupported fields are never sent.
    private func buildEdits() -> TagFields? {
        var edits = TagFields()
        var yearValue: Int?
        var trackValue: Int?

        if isBatch {
            if capabilities.canWrite {
                edits.title = trimmedOrNil(title)
                edits.artist = trimmedOrNil(artist)
                edits.album = trimmedOrNil(album)
                edits.genre = trimmedOrNil(genre)
                if let parsed = parseNumber(year, label: L("年份"), range: 1...9999) {
                    guard let value = parsed.value else {
                        errorMessage = parsed.error
                        return nil
                    }
                    yearValue = value
                }
                if let parsed = parseNumber(trackNumber, label: L("曲目号"), range: 1...65535) {
                    guard let value = parsed.value else {
                        errorMessage = parsed.error
                        return nil
                    }
                    trackValue = value
                }
            }
            if canEditAlbumArtist {
                edits.albumArtist = trimmedOrNil(albumArtist)
            }
        } else {
            let initial = initialFields ?? TagFields()
            if capabilities.canWrite {
                edits.title = changedText(title, initial.title)
                edits.artist = changedText(artist, initial.artist)
                edits.album = changedText(album, initial.album)
                edits.genre = changedText(genre, initial.genre)
                switch changedNumber(year, initial: initial.year, label: L("年份"), range: 1...9999) {
                case .unchanged: break
                case .value(let value): yearValue = value
                case .invalid(let message): errorMessage = message; return nil
                }
                switch changedNumber(
                    trackNumber,
                    initial: initial.trackNumber,
                    label: L("曲目号"),
                    range: 1...65535
                ) {
                case .unchanged: break
                case .value(let value): trackValue = value
                case .invalid(let message): errorMessage = message; return nil
                }
            }
            if canEditAlbumArtist {
                edits.albumArtist = changedText(albumArtist, initial.albumArtist)
            }
        }

        edits.year = yearValue
        edits.trackNumber = trackValue
        if capabilities.canWriteArtwork {
            edits.artworkBase64 = artworkEdit
        }
        return edits
    }

    private func trimmedOrNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// nil when unchanged, "" when the user cleared a value that existed.
    private func changedText(_ text: String, _ initial: String?) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialTrimmed = (initial ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == initialTrimmed ? nil : trimmed
    }

    private enum NumberEdit {
        case unchanged
        case value(Int)
        case invalid(String)
    }

    private func changedNumber(
        _ text: String,
        initial: Int?,
        label: String,
        range: ClosedRange<Int>
    ) -> NumberEdit {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // An emptied field clears an existing number, but a field that was
            // already blank stays untouched.
            return initial == nil ? .unchanged : .value(0)
        }
        guard let value = Int(trimmed), range.contains(value) else {
            return .invalid(Lf("%@必须是 %d–%d 之间的整数。", label, range.lowerBound, range.upperBound))
        }
        return value == initial ? .unchanged : .value(value)
    }

    /// Returns nil when the field is blank (leave unchanged), otherwise a
    /// result carrying either the parsed value or a Chinese validation error.
    private func parseNumber(
        _ text: String,
        label: String,
        range: ClosedRange<Int>
    ) -> (value: Int?, error: String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Int(trimmed), range.contains(value) else {
            return (nil, Lf("%@必须是 %d–%d 之间的整数。", label, range.lowerBound, range.upperBound))
        }
        return (value, nil)
    }
}

// MARK: - Field rows

private struct TagTextFieldRow: View {
    @Environment(\.theme) private var theme
    let label: String
    @Binding var text: String
    var disabled = false
    var placeholder = ""

    @State private var preview: String?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                labelText
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .disabled(disabled)
                Button(L("修复乱码")) {
                    if let fixed = MojibakeRepair.repaired(text) {
                        preview = fixed
                        message = nil
                    } else {
                        preview = nil
                        message = L("未检测到乱码")
                    }
                }
                .disabled(disabled || text.isEmpty)
                .help(L("按 UTF-8 或 GB18030 还原被错误解码的中文"))
            }
            if let preview {
                HStack(spacing: 8) {
                    Text(Lf("修复预览：%@", preview))
                        .font(.system(size: 11))
                        .foregroundColor(theme.accentLight)
                        .lineLimit(1)
                    Button(L("应用")) {
                        text = preview
                        self.preview = nil
                        message = nil
                    }
                    Button(L("取消")) { self.preview = nil }
                }
                .padding(.leading, 80)
            } else if let message {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundColor(theme.mutedText(0.45))
                    .padding(.leading, 80)
            }
        }
    }

    private var labelText: some View {
        Text(label)
            .font(.system(size: 11.5))
            .foregroundColor(theme.text.opacity(disabled ? 0.35 : 0.7))
            .frame(width: 72, alignment: .trailing)
    }
}

private struct TagNumberFieldRow: View {
    @Environment(\.theme) private var theme
    let label: String
    @Binding var text: String
    var disabled = false
    var placeholder = ""

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundColor(theme.text.opacity(disabled ? 0.35 : 0.7))
                .frame(width: 72, alignment: .trailing)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 120)
                .disabled(disabled)
            Spacer(minLength: 0)
        }
    }
}
