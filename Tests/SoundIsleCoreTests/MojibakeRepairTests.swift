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
    }

    func testRepairKeepsASCIIPrefix() {
        let bytes = Array("01 - ".utf8) + [0xE6, 0xAF, 0x8D, 0xE4, 0xBA, 0xB2]
        XCTAssertEqual(MojibakeRepair.repaired(latin1(bytes)), "01 - 母亲")
    }
}
