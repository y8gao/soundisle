import XCTest
@testable import SoundIsleCore

final class ThemePaletteTests: XCTestCase {
    func testDeepBlueAccents() {
        XCTAssertEqual(ThemeCatalog.tokens(for: .deepBlue, isDark: false).accentHex, "#3E6FE0")
        XCTAssertEqual(ThemeCatalog.tokens(for: .deepBlue, isDark: true).accentHex, "#7AA2FF")
        XCTAssertFalse(ThemeCatalog.tokens(for: .deepBlue, isDark: false).isDark)
        XCTAssertTrue(ThemeCatalog.tokens(for: .deepBlue, isDark: true).isDark)
    }

    func testEveryPresetAccent() {
        let expected: [(ThemePreset, String)] = [
            (.morning, "#C2703D"),
            (.inkAmber, "#F5B942"),
            (.celadon, "#4FB89A"),
            (.berry, "#B48CF2"),
            (.seaSalt, "#3E8FB0"),
        ]
        for (preset, hex) in expected {
            XCTAssertEqual(ThemeCatalog.tokens(for: preset, isDark: false).accentHex, hex)
            XCTAssertEqual(ThemeCatalog.tokens(for: preset, isDark: true).accentHex, hex)
        }
    }

    func testSystemModeResolution() {
        XCTAssertTrue(ThemeResolver.isDark(mode: .system, systemIsDark: true))
        XCTAssertFalse(ThemeResolver.isDark(mode: .system, systemIsDark: false))
        XCTAssertFalse(ThemeResolver.isDark(mode: .light, systemIsDark: true))
        XCTAssertTrue(ThemeResolver.isDark(mode: .dark, systemIsDark: false))
    }

    func testContrastOnLightAccentIsBlack() {
        XCTAssertEqual(AccentContrast.textColor(on: "#F5B942"), "#000000")
        XCTAssertEqual(AccentContrast.textColor(on: "#7AA2FF"), "#000000")
    }

    func testContrastOnDarkAccentIsWhite() {
        XCTAssertEqual(AccentContrast.textColor(on: "#1B1F27"), "#FFFFFF")
        XCTAssertEqual(AccentContrast.textColor(on: "#3E6FE0"), "#FFFFFF")
    }

    func testInvalidHexFallsBackToWhiteText() {
        XCTAssertEqual(AccentContrast.textColor(on: "not-a-colour"), "#FFFFFF")
    }

    func testCustomAccentOverridesPreset() {
        let tokens = ThemeCatalog.tokens(
            for: .deepBlue,
            isDark: true,
            customAccentHex: "#20C997"
        )
        XCTAssertEqual(tokens.accentHex, "#20C997")
        XCTAssertEqual(tokens.accentTextHex, "#000000")
    }

    func testInvalidCustomAccentIsIgnored() {
        let tokens = ThemeCatalog.tokens(
            for: .berry,
            isDark: true,
            customAccentHex: "#12"
        )
        XCTAssertEqual(tokens.accentHex, "#B48CF2")
    }

    func testSettingsStringsResolveToEnums() {
        let settings = AppSettings()
        XCTAssertEqual(settings.preset, .deepBlue)
        XCTAssertEqual(settings.mode, .system)

        var custom = settings
        custom.themePreset = "celadon"
        custom.themeMode = "dark"
        custom.rowStyle = "cover"
        XCTAssertEqual(custom.preset, .celadon)
        XCTAssertEqual(custom.mode, .dark)
        XCTAssertTrue(custom.usesCoverRowStyle)

        custom.themePreset = "unknown"
        XCTAssertEqual(custom.preset, .deepBlue)
    }
}
