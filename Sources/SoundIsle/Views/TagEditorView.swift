import AppKit
import SoundIsleCore
import SwiftUI
import UniformTypeIdentifiers

/// Sheet for editing one track or a batch. Blank text fields mean "leave this
/// field alone"; a cover is only written when the user picks or removes one.
@MainActor
struct TagEditorView: View {
    let model: AppModel
    let tracks: [Track]

    @Environment(\.dismiss) private var dismiss

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

    init(model: AppModel, tracks: [Track]) {
        self.model = model
        self.tracks = tracks
        self.capabilities = tracks.reduce(TagFormatCapabilities()) { partial, track in
            let next = TagFormatCapabilities.capabilities(for: track.url)
            return TagFormatCapabilities(
                canWrite: partial.canWrite && next.canWrite,
                canWriteAlbumArtist: partial.canWriteAlbumArtist && next.canWriteAlbumArtist,
                canWriteArtwork: partial.canWriteArtwork && next.canWriteArtwork,
                limitation: partial.limitation ?? next.limitation
            )
        }
    }

    private var isBatch: Bool { tracks.count > 1 }

    private var canEditAlbumArtist: Bool {
        capabilities.canWrite && capabilities.canWriteAlbumArtist
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    if isBatch {
                        Text("正在批量编辑 \(tracks.count) 首歌曲。留空的字段不会被修改。")
                            .font(.system(size: 11.5))
                            .foregroundColor(Theme.text.opacity(0.6))
                    }
                    if let limitation = capabilities.limitation {
                        limitationNote(limitation)
                    }

                    VStack(alignment: .leading, spacing: 11) {
                        TagTextFieldRow(
                            label: "标题",
                            text: $title,
                            disabled: !capabilities.canWrite,
                            placeholder: placeholder("标题")
                        )
                        TagTextFieldRow(
                            label: "歌手",
                            text: $artist,
                            disabled: !capabilities.canWrite,
                            placeholder: placeholder("歌手")
                        )
                        TagTextFieldRow(
                            label: "专辑",
                            text: $album,
                            disabled: !capabilities.canWrite,
                            placeholder: placeholder("专辑")
                        )
                        TagTextFieldRow(
                            label: "专辑歌手",
                            text: $albumArtist,
                            disabled: !canEditAlbumArtist,
                            placeholder: placeholder("专辑歌手")
                        )
                    }

                    VStack(alignment: .leading, spacing: 11) {
                        TagNumberFieldRow(
                            label: "年份",
                            text: $year,
                            disabled: !capabilities.canWrite,
                            placeholder: placeholder("年份")
                        )
                        TagNumberFieldRow(
                            label: "曲目号",
                            text: $trackNumber,
                            disabled: !capabilities.canWrite,
                            placeholder: placeholder("曲目号")
                        )
                        TagTextFieldRow(
                            label: "流派",
                            text: $genre,
                            disabled: !capabilities.canWrite,
                            placeholder: placeholder("流派")
                        )
                    }

                    coverSection

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 11.5))
                            .foregroundColor(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("留空的文本字段不会被修改。")
                        .font(.system(size: 10.5))
                        .foregroundColor(Theme.text.opacity(0.4))
                }
                .padding(22)
            }

            footer
        }
        .frame(width: 540, height: 590)
        .background(AppBackground())
        .preferredColorScheme(.dark)
        .onAppear(perform: loadInitialValues)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(isBatch ? "批量编辑标签" : "编辑标签")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Theme.text)
            Text(isBatch ? "\(tracks.count) 首" : tracks.first?.title ?? "")
                .font(.system(size: 11.5))
                .foregroundColor(Theme.text.opacity(0.5))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 22)
        .frame(height: 52)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("取消") { dismiss() }
            Button("保存") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!capabilities.canWrite || tracks.isEmpty)
        }
        .padding(.horizontal, 22)
        .frame(height: 54)
    }

    private func placeholder(_ label: String) -> String {
        isBatch ? "留空不修改" : label
    }

    private func limitationNote(_ text: String) -> some View {
        HStack(spacing: 7) {
            Icons.warning
                .foregroundColor(Theme.warning)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(Theme.text.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Theme.warning.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
    }

    // MARK: - Cover

    @ViewBuilder
    private var coverSection: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.coverGradient)
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
                    Button("选择封面…") { chooseCover() }
                    if artworkEdit != nil || currentArtworkBase64 != nil {
                        Button("移除封面") {
                            artworkEdit = ""
                            previewImage = nil
                        }
                    }
                }
                .disabled(!capabilities.canWriteArtwork)
                Text(coverHint)
                    .font(.system(size: 10.5))
                    .foregroundColor(Theme.text.opacity(0.5))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private var displayedCover: NSImage? {
        if let previewImage { return previewImage }
        if let base64 = currentArtworkBase64, let data = Data(base64Encoded: base64) {
            return NSImage(data: data)
        }
        return nil
    }

    private var coverHint: String {
        if !capabilities.canWriteArtwork {
            return capabilities.limitation ?? "该格式不支持写入封面。"
        }
        if artworkEdit == "" { return "保存后将移除封面。" }
        if artworkEdit != nil { return "已选择新封面，保存后写入。" }
        if isBatch { return "留空则不修改封面。" }
        return currentArtworkBase64 == nil ? "无封面" : "当前封面"
    }

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择封面图片"
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
        var edits = TagFields()
        edits.title = trimmedOrNil(title)
        edits.artist = trimmedOrNil(artist)
        edits.album = trimmedOrNil(album)
        edits.albumArtist = trimmedOrNil(albumArtist)
        edits.genre = trimmedOrNil(genre)

        if let parsed = parseNumber(year, label: "年份", range: 1...9999) {
            guard let value = parsed.value else {
                errorMessage = parsed.error
                return
            }
            edits.year = value
        }
        if let parsed = parseNumber(trackNumber, label: "曲目号", range: 1...65535) {
            guard let value = parsed.value else {
                errorMessage = parsed.error
                return
            }
            edits.trackNumber = value
        }
        edits.artworkBase64 = artworkEdit

        if let error = model.applyTagEdit(edits, to: tracks) {
            errorMessage = error
        } else {
            dismiss()
        }
    }

    private func trimmedOrNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
            return (nil, "\(label)必须是 \(range.lowerBound)–\(range.upperBound) 之间的整数。")
        }
        return (value, nil)
    }
}

// MARK: - Field rows

private struct TagTextFieldRow: View {
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
                Button("修复乱码") {
                    if let fixed = MojibakeRepair.repaired(text) {
                        preview = fixed
                        message = nil
                    } else {
                        preview = nil
                        message = "未检测到乱码"
                    }
                }
                .disabled(disabled || text.isEmpty)
                .help("按 UTF-8 或 GB18030 还原被错误解码的中文")
            }
            if let preview {
                HStack(spacing: 8) {
                    Text("修复预览：\(preview)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.accentLight)
                        .lineLimit(1)
                    Button("应用") {
                        text = preview
                        self.preview = nil
                        message = nil
                    }
                    Button("取消") { self.preview = nil }
                }
                .padding(.leading, 80)
            } else if let message {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundColor(Theme.text.opacity(0.45))
                    .padding(.leading, 80)
            }
        }
    }

    private var labelText: some View {
        Text(label)
            .font(.system(size: 11.5))
            .foregroundColor(Theme.text.opacity(disabled ? 0.35 : 0.7))
            .frame(width: 72, alignment: .trailing)
    }
}

private struct TagNumberFieldRow: View {
    let label: String
    @Binding var text: String
    var disabled = false
    var placeholder = ""

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundColor(Theme.text.opacity(disabled ? 0.35 : 0.7))
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
