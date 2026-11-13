import Foundation

/// A dotted version such as `0.7.2`. A leading `v` and any pre-release or
/// build suffix are ignored, so `v0.8.0-beta.1` compares as `0.8.0`, and the
/// comparison is component-wise rather than lexical: `0.7.10` is newer than
/// `0.7.9`, which a string compare gets backwards.
public struct AppVersion: Comparable, Equatable, CustomStringConvertible {
    public let components: [Int]
    public let raw: String

    public init?(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var text = trimmed.lowercased()
        if text.hasPrefix("v") { text.removeFirst() }
        for separator in ["-", "+"] {
            if let range = text.range(of: separator) {
                text = String(text[text.startIndex..<range.lowerBound])
            }
        }

        var numbers: [Int] = []
        for part in text.split(separator: ".", omittingEmptySubsequences: false) {
            guard let value = Int(part), value >= 0 else { return nil }
            numbers.append(value)
        }
        guard !numbers.isEmpty else { return nil }

        components = numbers
        // Normalised, so what is shown and sent is the version itself rather
        // than whatever spelling the tag used.
        raw = text
    }

    /// Equality is the same comparison: `1.0` and `1.0.0` are one version.
    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public var description: String { raw }
}
