import SwiftUI

/// A window-level notice: the app telling you what just happened, on whatever
/// page you happen to be. Library operations keep their own banner inside the
/// list — that one belongs to the content being shown. These do not.
struct AppNotice: Identifiable {
    enum Kind {
        case busy
        case info
        case success
        case warning
    }

    let id = UUID()
    let kind: Kind
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    /// How long it stays on screen. Failures linger; background chatter does
    /// not.
    var duration: TimeInterval {
        switch kind {
        case .busy: return 0
        case .success: return 3
        case .info: return 6
        case .warning: return 7
        }
    }
}
