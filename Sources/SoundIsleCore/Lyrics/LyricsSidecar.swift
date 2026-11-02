import Foundation

/// Finds a same-directory `.lrc` beside a track. Matching is case- and
/// width-insensitive (so `（` equals `(`), and falls back to comparing stems
/// with bracket suffixes such as `(Live)` removed.
public enum LyricsSidecar {
    public static func find(for track: Track, manager: FileManager = .default) -> URL? {
        let directory = track.url.deletingLastPathComponent()
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let candidates = entries.filter { $0.pathExtension.lowercased() == "lrc" }
        guard !candidates.isEmpty else { return nil }

        let stem = track.url.deletingPathExtension().lastPathComponent
        let exact = normalize(stem)
        let stripped = normalize(withoutBrackets(stem))

        var best: (url: URL, score: Int)?
        for candidate in candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let candidateStem = candidate.deletingPathExtension().lastPathComponent
            let normalized = normalize(candidateStem)
            let score: Int
            if normalized == exact {
                score = 2
            } else if !stripped.isEmpty, normalize(withoutBrackets(candidateStem)) == stripped {
                score = 1
            } else {
                continue
            }
            if best?.score ?? -1 < score {
                best = (candidate, score)
            }
        }
        return best?.url
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }

    private static func withoutBrackets(_ value: String) -> String {
        value.replacingOccurrences(
            of: #"[\(\[（【][^\)\]）】]*[\)\]）】]"#,
            with: "",
            options: .regularExpression
        )
    }
}
