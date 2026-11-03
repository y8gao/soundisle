import XCTest
@testable import SoundIsleCore

final class MojibakeRepairTests: XCTestCase {
    /// Builds the string you get when the given bytes are decoded as Latin-1,
    /// which is how GBK/UTF-8 Chinese looks after a mis-decode.
    private func latin1(_ bytes: [UInt8]) -> String {
        String(data: Data(bytes), encoding: .isoLatin1)!
    }

    func testRepairUTF8MisreadAsLatin1() {
        let broken = latin1([0xE6, 0xAF, 0x8D, 0xE4, 0xBA, 0xB2]) // 母亲 in UTF-8
        XCTAssertEqual(MojibakeRepair.repaired(broken), "母亲")
    }

    func testRepairGB18030MisreadAsLatin1() {
        let broken = latin1([0xC4, 0xB8, 0xC7, 0xD7]) // 母亲 in GBK
        XCTAssertEqual(MojibakeRepair.repaired(broken), "母亲")
    }

    func testRepairUTF8MisreadAsWindows1252() {
        // TagLib maps the 0x80...0x9F range with Windows-1252, producing
        // characters above U+00FF (e.g. 0x8B -> U+2039). Real files must
        // still repair.
        let broken = String(data: Data(Array("天空之城".utf8)), encoding: .windowsCP1252)!
        XCTAssertEqual(MojibakeRepair.repaired(broken), "天空之城")
    }

    func testNormalChineseUnchanged() {
        XCTAssertNil(MojibakeRepair.repaired("母亲"))
    }

    func testPlainASCIINoRepair() {
        XCTAssertNil(MojibakeRepair.repaired("hello"))
        XCTAssertNil(MojibakeRepair.repaired(""))
    }

    func testLatinTextWithAccentsNoRepair() {
        // GB18030 can decode some Latin-1 bytes into accidental Han characters;
        // a string with ASCII letters is real text, not mis-decoded Chinese.
        XCTAssertNil(MojibakeRepair.repaired("Mötley Crüe"))
        XCTAssertNil(MojibakeRepair.repaired("café"))
        // A single accidental Han character (accent + typographic quote) is
        // not enough to rewrite a real title.
        XCTAssertNil(MojibakeRepair.repaired("Beyoncé’s"))
    }

    func testRepairKeepsASCIIPrefix() {
        let bytes = Array("01 - ".utf8) + [0xE6, 0xAF, 0x8D, 0xE4, 0xBA, 0xB2]
        XCTAssertEqual(MojibakeRepair.repaired(latin1(bytes)), "01 - 母亲")
    }

    private var gb18030: String.Encoding {
        String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
    }

    private func utf8Misread(_ text: String) -> String {
        latin1(Array(text.utf8))
    }

    private func gb18030Misread(_ text: String) -> String {
        latin1(Array(text.data(using: gb18030)!))
    }

    func testRepairUTF8MixedWithLatinText() {
        let original = "母亲 (Live)"
        XCTAssertEqual(MojibakeRepair.repaired(utf8Misread(original)), original)
    }

    func testRepairUTF8WithFeatureText() {
        let original = "周杰伦 feat. 青花瓷"
        XCTAssertEqual(MojibakeRepair.repaired(utf8Misread(original)), original)
    }

    func testRepairUTF8WithFullwidthPunctuation() {
        let original = "（母亲）"
        XCTAssertEqual(MojibakeRepair.repaired(utf8Misread(original)), original)
    }

    func testRepairGB18030MixedWithLatinText() {
        let original = "母亲 (Live)"
        XCTAssertEqual(MojibakeRepair.repaired(gb18030Misread(original)), original)
    }

    func testRepairGB18030AfterASCIIPrefix() {
        let original = "Track 01 - 母亲"
        XCTAssertEqual(MojibakeRepair.repaired(gb18030Misread(original)), original)
    }
}
