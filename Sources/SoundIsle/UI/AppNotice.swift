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
    /// Overrides the kind's icon, for a message that is more specific than its
    /// tone — a download arrow for a new version, say.
    var symbol: String?
    var action: (() -> Void)?

    /// How long it stays on screen. A failure is not something to miss while
    /// looking away, so it waits for the user to close it; background chatter
    /// gets a few seconds.
    var duration: TimeInterval {
        switch kind {
        case .busy, .warning: return 0
        case .success: return 3
        case .info: return 6
        }
    }
}
