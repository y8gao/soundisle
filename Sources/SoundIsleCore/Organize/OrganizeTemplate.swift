import Foundation

/// Renders a user template into a destination URL for one track.
///
/// Templates are split on `/` *before* substitution so a tag containing a
/// slash can never create an extra folder level, and every component is
/// sanitized for the filesystem. `{ext}` is appended automatically when the
/// template does not mention it, so the built-in presets keep their extension.
public enum OrganizeTemplate {
    public static let unknownArtist = "未知歌手"
    public static let unknownAlbum = "未知专辑"
    public static let unknownTitle = "未知歌曲"
    public static let fallbackComponent = "未命名"

    public static func render(template: String, track: Track, root: URL) -> URL {
        var template = template
        if !template.contains("{ext}") {
            template += ".{ext}"
        }

        let components = template
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { sanitize(substitute(String($0), track: track)) }
            .filter { !$0.isEmpty }

        var url = root
        for component in components.isEmpty ? [fallbackComponent] : components {
            url.appendPathComponent(component)
        }
        return url
    }

    /// Replaces every known variable in one path component. Unknown values use
    /// the Chinese fallbacks the UI promises instead of producing empty names.
    private static func substitute(_ component: String, track: Track) -> String {
        let artist = cleaned(track.artist) ?? unknownArtist
        let album = cleaned(track.album) ?? unknownAlbum
        let albumArtist = cleaned(track.albumArtist) ?? cleaned(track.artist) ?? unknownArtist
        let stem = (track.url.lastPathComponent as NSString).deletingPathExtension
        let title = cleaned(track.title) ?? cleaned(stem) ?? unknownTitle

        var value = component
        let replacements: [(String, String)] = [
            ("{artist}", artist),
            ("{album}", album),
            ("{albumArtist}", albumArtist),
            ("{title}", title),
            ("{track}", track.trackNumber.map(String.init) ?? ""),
            ("{year}", track.year.map(String.init) ?? ""),
            ("{ext}", track.url.pathExtension),
        ]
        for (token, replacement) in replacements {
            value = value.replacingOccurrences(of: token, with: replacement)
        }
        return value
    }

    /// `sanitize` is also used by the preview UI for display, so it stays
    /// public. `/` becomes `、` (readable for Chinese names) and `:` becomes
    /// `-`; the Windows-illegal set and control characters become `-` too,
    /// which keeps archives and external disks usable.
    public static func sanitize(_ value: String) -> String {
        var result = value
            .replacingOccurrences(of: "/", with: "、")
            .replacingOccurrences(of: ":", with: "-")

        let illegal: Set<Character> = ["\\", "*", "?", "\"", "<", ">", "|"]
        result = String(result.map { character in
            illegal.contains(character) ? "-" : character
        })
        result = String(result.unicodeScalars.map { scalar in
            scalar.value < 32 || scalar.value == 127 ? "-" : Character(scalar)
        })
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix(".") || result.hasSuffix(" ") {
            result.removeLast()
        }
        if result == "." || result == ".." {
            return fallbackComponent
        }
        return result
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
