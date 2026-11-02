import Foundation

/// Repairs text that was decoded with Latin-1 even though the file stored
/// UTF-8 or GB18030 Chinese. A mis-decoded string maps its original bytes
/// one-to-one to Unicode scalars U+0000...U+00FF, so the bytes can be
/// recovered and decoded again.
public enum MojibakeRepair {
    private static let gb18030 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )

    /// Returns the repaired text when a UTF-8 or GB18030 decode contains more
    /// Chinese characters than the input; `nil` when the input is not Latin-1
    /// mojibake or no candidate improves on it.
    public static func repaired(_ text: String) -> String? {
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty else { return nil }
        // Real Chinese text is already above U+00FF and needs no repair.
        guard scalars.allSatisfy({ $0.value <= 0xFF }) else { return nil }

        let bytes = Data(scalars.map { UInt8($0.value) })
        let originalRatio = chineseRatio(text)
        let originalASCII = asciiOnly(text)
        var best: (text: String, ratio: Double)?

        // Both candidates are scored so a GB18030 mis-decode wins when UTF-8
        // only yields Latin letters. Candidates must keep every ASCII run
        // intact: GB18030 consumes ASCII bytes as trail bytes for some pairs,
        // which is how accidental "Han" text is told apart from real text.
        for candidate in [String(data: bytes, encoding: .utf8),
                          String(data: bytes, encoding: gb18030)] {
            guard let candidate, asciiOnly(candidate) == originalASCII else { continue }
            let ratio = chineseRatio(candidate)
            guard ratio > originalRatio else { continue }
            if best == nil || ratio > best!.ratio {
                best = (candidate, ratio)
            }
        }
        return best?.text
    }

    /// ASCII characters that survived the decode, used to reject candidates
    /// that ate English words or punctuation.
    private static func asciiOnly(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars where scalar.value < 0x80 {
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    /// Chinese characters divided by non-ASCII characters. ASCII text is
    /// ignored so appending "(Live)" or "feat. X" cannot change the score.
    private static func chineseRatio(_ text: String) -> Double {
        var chinese = 0
        var nonASCII = 0
        for scalar in text.unicodeScalars where scalar.value >= 0x80 {
            nonASCII += 1
            if isChinese(scalar) { chinese += 1 }
        }
        return nonASCII == 0 ? 0 : Double(chinese) / Double(nonASCII)
    }

    private static func isChinese(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0x20000...0x2FA1F, // Extensions B-F
             0x3000...0x303F,   // CJK punctuation
             0xFE30...0xFE4F,   // CJK compatibility forms
             0xFF00...0xFFEF:   // Fullwidth forms
            return true
        default:
            return false
        }
    }
}
