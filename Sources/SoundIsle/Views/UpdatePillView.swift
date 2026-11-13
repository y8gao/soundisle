import SwiftUI

/// The update marker in the top bar. A periodic check runs while the user is
/// somewhere else entirely, so its result cannot live in a three-second
/// notice: this stays until the update is installed or deliberately ignored.
struct UpdatePillView: View {
    @ObservedObject var model: AppModel
    @Environment(\.theme) private var theme
    @State private var isShowingMenu = false

    var body: some View {
        if let pill = UpdatePresentation.pill(for: model.updates.state) {
            content(for: pill)
        }
    }

    @ViewBuilder
    private func content(for pill: UpdatePresentation.Pill) -> some View {
        switch pill.kind {
        case .available:
            Button {
                isShowingMenu.toggle()
            } label: {
                capsule(Lf("%@ 可用", pill.version), symbol: "arrow.down.circle", filled: false)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isShowingMenu, arrowEdge: .bottom) {
                ThemedMenuPanel(width: 200) {
                    ThemedMenuAction(symbol: "arrow.down.circle", title: L("下载并安装")) {
                        Task { await model.updates.installAvailable() }
                    }
                    if let release = model.updates.availableRelease {
                        ThemedMenuAction(symbol: "arrow.up.right.square", title: L("查看更新说明")) {
                            model.updates.openReleasePage(release)
                        }
                        ThemedMenuSeparator()
                        ThemedMenuAction(symbol: "xmark", title: L("忽略此版本")) {
                            model.updates.skip(release)
                        }
                    }
                }
            }
            .help(Lf("新版本 %@ 可用", pill.version))

        case .downloading:
            capsule(Lf("%@ 下载中", pill.version), symbol: "arrow.down.circle", filled: false)
                .help(L("正在下载更新…"))

        case .ready:
            Button {
                isShowingMenu.toggle()
            } label: {
                capsule(Lf("重启以更新 %@", pill.version), symbol: "arrow.clockwise", filled: true)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isShowingMenu, arrowEdge: .bottom) {
                ThemedMenuPanel(width: 200) {
                    ThemedMenuAction(symbol: "arrow.clockwise", title: L("现在重启")) {
                        model.updates.restartToApply()
                    }
                    Text(L("退出声屿时会自动更新"))
                        .font(.system(size: 10.5))
                        .foregroundColor(theme.mutedText(0.5))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
            }
            .help(L("更新已下载，重启后生效"))
        }
    }

    private func capsule(_ text: String, symbol: String, filled: Bool) -> some View {
        HStack(spacing: 4) {
            Icons.symbol(symbol, size: 10)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(filled ? theme.onAccent : theme.accentLight)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(filled ? theme.accent : theme.accent.opacity(0.16), in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                theme.accent.opacity(filled ? 0 : 0.28),
                lineWidth: 0.5
            )
        )
        .contentShape(Capsule())
    }
}
