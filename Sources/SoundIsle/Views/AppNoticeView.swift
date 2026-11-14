import SwiftUI

/// The window-level notice: one line, at the bottom above the player bar, on
/// whatever page is showing. Transient by design — what it says has already
/// been recorded where it can be found again.
struct AppNoticeView: View {
    @Environment(\.theme) private var theme
    let notice: AppNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            leading

            Text(notice.text)
                .font(.system(size: 12))
                .foregroundColor(theme.text.opacity(0.9))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let title = notice.actionTitle, let action = notice.action {
                Button {
                    action()
                    onDismiss()
                } label: {
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(theme.onAccent)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(theme.accent, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            if notice.kind == .warning {
                Button(action: onDismiss) {
                    Icons.close
                        .foregroundColor(theme.mutedText(0.5))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("关闭"))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(minHeight: 36)
        .background(theme.panelTint, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.hairline.opacity(0.7), lineWidth: 0.5))
        // Same edge language as the menus: a solid surface and a tight
        // shadow, never a border plus a wide grey halo.
        .shadow(color: .black.opacity(theme.isDark ? 0.45 : 0.16), radius: 5, y: 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var leading: some View {
        switch notice.kind {
        case .busy:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)
        case .info:
            Icons.symbol(notice.symbol ?? "info.circle", size: 12)
                .foregroundColor(theme.accent)
        case .success:
            Icons.symbol(notice.symbol ?? "checkmark.circle", size: 12)
                .foregroundColor(theme.accent)
        case .warning:
            Icons.symbol("exclamationmark.triangle", size: 12)
                .foregroundColor(theme.warning)
        }
    }
}
