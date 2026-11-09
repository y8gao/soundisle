import SoundIsleCore
import SwiftUI

/// Main-window now-playing page. The player-bar cover toggles between this and
/// `TrackListView`; the sidebar and top bar stay put. Left is the artwork and
/// lyrics actions, right is a synced, auto-scrolling lyric list.
struct NowPlayingLyricsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.theme) private var theme

    private var track: Track? { model.currentTrack }

    private var artworkURL: URL? {
        track.flatMap { model.library.artworkURL(for: $0) }
    }

    private var subtitle: String {
        guard let track else { return L("选择一首歌曲") }
        let parts = [track.artist, track.album].filter { !$0.isEmpty }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    private var originLabel: String? {
        switch model.lyricsOrigin {
        case .sidecar: return L("本地歌词")
        case .online: return L("在线歌词")
        case .override: return L("覆盖歌词")
        case .none: return nil
        }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                background
                VStack(spacing: 0) {
                    header
                    HStack(alignment: .top, spacing: 30) {
                        leftColumn
                            .frame(width: 250)
                        rightColumn
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    // Pin the two scroll columns to the page height. Their
                    // content is tall; letting them keep their ideal height
                    // pushed the header (and the window chrome) out of frame.
                    .frame(height: max(0, proxy.size.height - 42 - 12))
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            if let artworkURL {
                AsyncImage(
                    url: artworkURL,
                    transaction: Transaction(animation: .easeOut(duration: 0.2))
                ) { phase in
                    if let image = phase.image {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .blur(radius: 60)
                .scaleEffect(1.18)
                .opacity(theme.isDark ? 0.34 : 0.22)
            }

            LinearGradient(
                colors: [
                    theme.backgroundTop.opacity(theme.isDark ? 0.58 : 0.68),
                    theme.backgroundMiddle.opacity(theme.isDark ? 0.50 : 0.60),
                    theme.backgroundBottom.opacity(theme.isDark ? 0.62 : 0.72),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [theme.accent.opacity(theme.isDark ? 0.24 : 0.16), .clear],
                center: UnitPoint(x: 0.2, y: 0.1),
                startRadius: 0,
                endRadius: 420
            )
        }
        .background(.ultraThinMaterial)
        .allowsHitTesting(false)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button {
                model.toggleLyricsPage()
            } label: {
                HStack(spacing: 5) {
                    Icons.symbol("chevron.left", size: 10, weight: .semibold)
                    Text(L("返回列表"))
                        .font(.system(size: 11.5, weight: .medium))
                }
                .foregroundColor(theme.accent.opacity(0.9))
                .padding(.horizontal, 11)
                .frame(height: 27)
                .background(theme.raisedFill, in: Capsule())
                .overlay(Capsule().strokeBorder(theme.hairline, lineWidth: 0.5))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(L("返回歌曲列表"))
            .accessibilityLabel(L("返回列表"))

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 22)
        .frame(height: 42)
    }

    // MARK: - Left column

    private var leftColumn: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 9) {
                Button {
                    model.toggleLyricsPage()
                } label: {
                    TrackCoverView(
                        url: artworkURL,
                        size: 210,
                        cornerRadius: 20
                    )
                }
                .buttonStyle(.plain)
                .help(L("返回歌曲列表"))
                .accessibilityLabel(L("专辑封面，点击返回歌曲列表"))

                VStack(spacing: 4) {
                    Text(track?.title ?? L("未在播放"))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(theme.accent)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundColor(theme.accent.opacity(theme.isDark ? 0.6 : 0.72))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity)

                if let originLabel {
                    HStack(spacing: 4) {
                        Icons.symbol("waveform", size: 9)
                        Text(originLabel)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.accentLight)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(theme.accent.opacity(0.16), in: Capsule())
                    .overlay(Capsule().strokeBorder(theme.accent.opacity(0.28), lineWidth: 0.5))
                    .accessibilityLabel(Lf("歌词来源：%@", originLabel))
                }

                actionButtons
                    .padding(.top, 2)
            }
            .padding(.bottom, 4)
        }
        .frame(width: 250)
    }

    private var actionButtons: some View {
        VStack(spacing: 6) {
            lyricAction(
                model.lyrics == nil ? L("导入歌词…") : L("更换歌词…"),
                symbol: "square.and.arrow.down",
                help: L("选择 .lrc 或 .txt 文件"),
                isPrimary: true,
                isDisabled: model.currentTrack == nil
            ) {
                model.promptImportLyrics()
            }

            lyricAction(
                L("重试匹配"),
                symbol: "arrow.clockwise",
                help: L("重新查找同名歌词或在线匹配"),
                isDisabled: model.currentTrack == nil || model.isResolvingLyrics
            ) {
                model.retryLyrics()
            }

            if model.hasLyricsOverride {
                lyricAction(
                    L("恢复自动匹配"),
                    symbol: "arrow.uturn.backward",
                    help: L("删除手动导入的歌词，恢复自动匹配"),
                    isDisabled: false
                ) {
                    model.restoreAutomaticLyrics()
                }
            }
        }
    }

    private func lyricAction(
        _ title: String,
        symbol: String,
        help: String,
        isPrimary: Bool = false,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Icons.symbol(symbol, size: 10)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundColor(isPrimary ? theme.onAccent : theme.accent.opacity(0.9))
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(
                isPrimary ? theme.accent : theme.raisedFill,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isPrimary ? Color.clear : theme.accent.opacity(0.3), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .help(help)
        .accessibilityLabel(title)
    }

    // MARK: - Right column

    @ViewBuilder
    private var rightColumn: some View {
        if let lyrics = model.lyrics, !lyrics.lines.isEmpty {
            lyricsList(lyrics)
        } else {
            emptyState
        }
    }

    private func lyricsList(_ lyrics: Lyrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        LyricLineRow(
                            text: line.text,
                            isCurrent: isCurrentLine(index, lyrics: lyrics),
                            isSynced: lyrics.isSynced,
                            canSeek: lyrics.isSynced && !line.text.trimmingCharacters(in: .whitespaces).isEmpty,
                            onSeek: { model.seek(to: line.time) }
                        )
                        .id(index)
                    }
                }
                .padding(.vertical, 150)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                scrollToCurrent(proxy, lyrics: lyrics, animated: false)
            }
            .onChange(of: model.currentLyricLineIndex) { _ in
                scrollToCurrent(proxy, lyrics: lyrics, animated: true)
            }
            .onChange(of: model.currentTrack?.id) { _ in
                scrollToCurrent(proxy, lyrics: lyrics, animated: false)
            }
        }
    }

    private func isCurrentLine(_ index: Int, lyrics: Lyrics) -> Bool {
        guard lyrics.isSynced, !lyrics.lines.isEmpty else { return false }
        let current = min(model.currentLyricLineIndex ?? 0, lyrics.lines.count - 1)
        return current == index
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy, lyrics: Lyrics, animated: Bool) {
        guard let index = effectiveIndex(lyrics) else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeInOut(duration: 0.32)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            } else {
                proxy.scrollTo(index, anchor: .center)
            }
        }
    }

    private func effectiveIndex(_ lyrics: Lyrics) -> Int? {
        guard lyrics.isSynced, !lyrics.lines.isEmpty else { return nil }
        return min(model.currentLyricLineIndex ?? 0, lyrics.lines.count - 1)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            Icons.symbol("text.alignleft", size: 34, weight: .light)
                .foregroundColor(theme.mutedText(0.3))
            Text(model.isResolvingLyrics ? L("正在匹配歌词…") : L("暂无歌词"))
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(theme.text.opacity(0.85))
            Text(model.isResolvingLyrics ? L("正在查找同名歌词与在线来源") : L("可以重试匹配，或导入本地歌词文件"))
                .font(.system(size: 11.5))
                .foregroundColor(theme.mutedText(0.5))

            HStack(spacing: 8) {
                Button {
                    model.retryLyrics()
                } label: {
                    Text(L("重试匹配"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(theme.accentLight)
                        .padding(.horizontal, 13)
                        .frame(height: 28)
                        .background(theme.accent.opacity(0.16), in: Capsule())
                        .overlay(Capsule().strokeBorder(theme.accent.opacity(0.3), lineWidth: 0.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.currentTrack == nil || model.isResolvingLyrics)
                .opacity(model.currentTrack == nil || model.isResolvingLyrics ? 0.45 : 1)
                .help(L("重新查找同名歌词或在线匹配"))
                .accessibilityLabel(L("重试匹配"))

                Button {
                    model.promptImportLyrics()
                } label: {
                    Text(L("导入歌词…"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(theme.accentLight)
                        .padding(.horizontal, 13)
                        .frame(height: 28)
                        .background(theme.raisedFill, in: Capsule())
                        .overlay(Capsule().strokeBorder(theme.hairline, lineWidth: 0.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.currentTrack == nil)
                .opacity(model.currentTrack == nil ? 0.45 : 1)
                .help(L("选择 .lrc 或 .txt 文件"))
                .accessibilityLabel(L("导入歌词"))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
    }
}

/// One line in the lyrics page. Synced lines are buttons: clicking seeks the
/// player to that line's timestamp, the same gesture users expect from a
/// karaoke player.
private struct LyricLineRow: View {
    let text: String
    let isCurrent: Bool
    let isSynced: Bool
    let canSeek: Bool
    let onSeek: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: onSeek) {
            HStack(alignment: .center, spacing: 8) {
                label
                // Hovering a synced line shows a play triangle at the trailing
                // edge; the reserved slot keeps the text from shifting.
                playIndicator
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            // A shared minimum height makes every single-line row the same
            // size, so the hover band does not grow or shrink with the type
            // size. Wrapped lines are still allowed to be taller.
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(rowBackground)
            )
            .contentShape(Rectangle())
            // Animate only colour and band, never layout: the type size is
            // shared by every line, so moving the highlight cannot reflow the
            // list or make glyphs jump between sizes.
            .animation(.easeInOut(duration: 0.22), value: isCurrent)
        }
        .buttonStyle(.plain)
        .disabled(!canSeek)
        .onHover { isHovering = $0 }
        .accessibilityLabel(canSeek ? Lf("跳转到这一句：%@", text) : text)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    /// The current line is carried by weight and colour alone; a background
    /// band here would add a second, permanent highlight to the list. Only the
    /// transient hover affordance needs a fill.
    private var rowBackground: Color {
        isHovering && canSeek ? theme.accent.opacity(0.07) : .clear
    }

    @ViewBuilder
    private var playIndicator: some View {
        if canSeek {
            Icons.symbol("play.fill", size: 12)
                // Keep the affordance present without out-shouting the
                // lyric colour: it should read as part of the text row.
                .foregroundColor(theme.accent.opacity(isCurrent ? 0.55 : 0.40))
                .frame(width: 16, height: 18)
                .opacity(isHovering ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: isHovering)
        } else {
            Color.clear.frame(width: 16, height: 18)
        }
    }

    private var label: some View {
        // One type size for every line: the current row is marked by weight,
        // colour and the accent band instead of growing, which is what made
        // the line change flash and reflow.
        Text(text.isEmpty ? " " : text)
            .font(.system(size: 16, weight: isCurrent ? .semibold : .regular))
            .foregroundColor(
                isCurrent
                    ? theme.accent
                    : theme.accent.opacity(isSynced ? 0.55 : 0.78)
            )
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
