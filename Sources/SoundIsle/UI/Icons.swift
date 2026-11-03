import AppKit
import SwiftUI

/// Single entry point for every icon in the app. SF Symbols carry the 1.75pt
/// rounded stroke look at the regular weight; play/pause use the filled
/// variants as the spec requires. Sizes vary by role (20pt controls, 18pt
/// player-bar utilities, 12-13pt sidebar glyphs).
enum Icons {
    static let pointSize: CGFloat = 20

    static func symbol(
        _ name: String,
        size: CGFloat = pointSize,
        weight: NSFont.Weight = .regular
    ) -> Image {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            return Image(systemName: name)
        }
        return Image(nsImage: image).renderingMode(.template)
    }

    // Playback
    static var play: Image { symbol("play.fill") }
    static var pause: Image { symbol("pause.fill") }
    static var previous: Image { symbol("backward.end") }
    static var next: Image { symbol("forward.end") }
    static var sequential: Image { symbol("arrow.right", size: 18) }
    static var repeatAll: Image { symbol("repeat", size: 18) }
    static var repeatOne: Image { symbol("repeat.1", size: 18) }
    static var shuffle: Image { symbol("shuffle", size: 18) }

    // Player bar
    static func volume(muted: Bool = false, low: Bool = false, size: CGFloat = 18) -> Image {
        let name = muted ? "speaker.slash" : (low ? "speaker.wave.1" : "speaker.wave.3")
        return symbol(name, size: size)
    }
    static func lyrics(size: CGFloat = 18) -> Image { symbol("text.alignleft", size: size) }
    static var coverNote: Image { symbol("music.note", size: 17) }

    // Sidebar
    static var allMusic: Image { symbol("music.note", size: 12) }
    static var folder: Image { symbol("folder", size: 12) }
    static var playlist: Image { symbol("music.note.list", size: 12) }
    static var recent: Image { symbol("clock", size: 12) }
    static var plus: Image { symbol("plus", size: 11, weight: .semibold) }

    // Chrome
    static var search: Image { symbol("magnifyingglass", size: 12) }
    static var settings: Image { symbol("gearshape", size: 16) }
    static var refresh: Image { symbol("arrow.clockwise", size: 13) }
    static func sortArrow(ascending: Bool) -> Image {
        symbol(ascending ? "chevron.up" : "chevron.down", size: 7, weight: .semibold)
    }
    static var close: Image { symbol("xmark", size: 10, weight: .semibold) }
    static var warning: Image { symbol("exclamationmark.triangle.fill", size: 11) }
    static var emptyLibrary: Image { symbol("music.note.list", size: 42, weight: .light) }
    static var dropImport: Image { symbol("folder.badge.plus", size: 32, weight: .light) }

    // Settings sections
    static var settingsFolders: Image { symbol("folder", size: 18) }
    static var settingsCache: Image { symbol("internaldrive", size: 18) }
    static var settingsLyrics: Image { symbol("text.alignleft", size: 18) }
    static var settingsAppearance: Image { symbol("paintpalette", size: 18) }
    static var settingsTags: Image { symbol("tag", size: 18) }
}
