import AppKit
import SwiftUI

/// The single note glyph used by the app icon, menu-bar item, default cover
/// and window title. The PNG is extracted from the app icon so every surface
/// shows exactly the same note; the image is always drawn as a template with
/// no background.
enum NoteGlyph {
    static func sourceImage() -> NSImage? {
        NSImage(named: "NoteGlyph")
    }

    static func templateImage(size: CGFloat) -> NSImage? {
        guard let source = sourceImage() else { return nil }
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let aspect = source.size.width / max(source.size.height, 1)
        let drawWidth = size * aspect
        let rect = NSRect(x: (size - drawWidth) / 2, y: 0, width: drawWidth, height: size)
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

struct NoteIcon: View {
    var size: CGFloat = 16
    var color: Color = .primary

    var body: some View {
        if let image = NoteGlyph.sourceImage() {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundColor(color)
                .accessibilityHidden(true)
        } else {
            Icons.symbol("music.note", size: size, weight: .semibold)
                .foregroundColor(color)
                .accessibilityHidden(true)
        }
    }
}
