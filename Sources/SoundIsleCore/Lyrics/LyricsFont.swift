import CoreGraphics

/// The overlay has one type size control: the window width. Everything else
/// (A−/A+) resizes the window, so the text never looks tiny in a huge frame.
public enum LyricsFont {
    public static let minWidth: CGFloat = 320
    public static let maxWidth: CGFloat = 900
    public static let minSize: CGFloat = 18
    public static let maxSize: CGFloat = 36

    public static func size(forWidth width: CGFloat) -> CGFloat {
        guard !width.isNaN else { return minSize }
        let clamped = min(max(width, minWidth), maxWidth)
        let ratio = (clamped - minWidth) / (maxWidth - minWidth)
        return minSize + ratio * (maxSize - minSize)
    }
}
