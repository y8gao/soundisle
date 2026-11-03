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

    /// TagLib decodes malformed ISO-8859-1 tag bytes in 0x80...0x9F with the
    /// Windows-1252 table, so a real UTF-8 mis-decode contains U+2039, U+0178
    /// and friends rather than C1 controls. Map those scalars back to the
    /// original byte before trying to decode.
    private static let windows1252ToByte: [UInt32: UInt8] = [
        0x20AC: 0x80, 0x201A: 0x82, 0x0192: 0x83, 0x201E: 0x84,
        0x2026: 0x85, 0x2020: 0x86, 0x2021: 0x87, 0x02C6: 0x88,
        0x2030: 0x89, 0x0160: 0x8A, 0x2039: 0x8B, 0x0152: 0x8C,
        0x017D: 0x8E, 0x2018: 0x91, 0x2019: 0x92, 0x201C: 0x93,
        0x201D: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97,
        0x02DC: 0x98, 0x2122: 0x99, 0x0161: 0x9A, 0x203A: 0x9B,
        0x0153: 0x9C, 0x017E: 0x9E, 0x0178: 0x9F,
    ]

    /// Returns the repaired text when a UTF-8 or GB18030 decode contains more
    /// Chinese characters than the input; `nil` when the input is not Latin-1
    /// mojibake or no candidate improves on it.
    public static func repaired(_ text: String) -> String? {
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty else { return nil }

        var bytes = [UInt8]()
        bytes.reserveCapacity(scalars.count)
        for scalar in scalars {
            if scalar.value <= 0xFF {
                bytes.append(UInt8(scalar.value))
            } else if let byte = windows1252ToByte[scalar.value] {
                bytes.append(byte)
            } else {
                // Real Chinese text is already above U+00FF and needs no repair.
                return nil
            }
        }

        let originalRatio = chineseRatio(text)
        let originalASCII = asciiOnly(text)
        var best: (text: String, ratio: Double)?

        // Both candidates are scored so a GB18030 mis-decode wins when UTF-8
        // only yields Latin letters. Candidates must keep every ASCII run
        // intact: GB18030 consumes ASCII bytes as trail bytes for some pairs,
        // which is how accidental "Han" text is told apart from real text.
        for candidate in [String(data: Data(bytes), encoding: .utf8),
                          String(data: Data(bytes), encoding: gb18030)] {
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
