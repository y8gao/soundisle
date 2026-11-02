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
    /// Han characters than the input; `nil` when the input is not Latin-1
    /// mojibake or no candidate improves on it.
    public static func repaired(_ text: String) -> String? {
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty else { return nil }
        // Real Chinese text is already above U+00FF and needs no repair.
        guard scalars.allSatisfy({ $0.value <= 0xFF }) else { return nil }
        // Mis-decoded CJK never contains ASCII letters: UTF-8/GBK Chinese bytes
        // are all >= 0x80. Plain Latin words with accents ("Mötley Crüe") do,
        // and GB18030 would otherwise "decode" them into accidental Han text.
        guard !scalars.contains(where: { isASCIILetter($0) }) else { return nil }

        let bytes = Data(scalars.map { UInt8($0.value) })
        let originalRatio = hanRatio(text)

        // Try UTF-8 first: a valid UTF-8 decode containing Han is an
        // unambiguous signal. GB18030 accepts almost any high-byte pair and
        // can produce *more* accidental Han characters ("姣嶄翰" for the UTF-8
        // bytes of 母亲), so comparing raw ratios would pick the wrong one.
        for candidate in [String(data: bytes, encoding: .utf8),
                          String(data: bytes, encoding: gb18030)] {
            guard let candidate else { continue }
            let ratio = hanRatio(candidate)
            if ratio > originalRatio, ratio > 0 {
                return candidate
            }
        }
        return nil
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x41...0x5A, 0x61...0x7A: return true
        default: return false
        }
    }

    private static func hanRatio(_ text: String) -> Double {
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty else { return 0 }
        let han = scalars.filter(isHan).count
        return Double(han) / Double(scalars.count)
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0x20000...0x2FA1F: // Extensions B-F
            return true
        default:
            return false
        }
    }
}
