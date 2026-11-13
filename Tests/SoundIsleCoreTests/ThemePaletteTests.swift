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
        XCTAssertEqual(settings.preset, .celadon)
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

/// Text drawn on a filled accent control — the play button, the update pill,
/// a notice's action button — takes its colour from `accentTextHex`, which
/// picks black or white by contrast. These pin the property down for every
/// preset in both appearances, and for the extremes a custom accent can hit.
final class AccentContrastTests: XCTestCase {
    /// WCAG relative luminance.
    private func luminance(_ hex: String) -> Double {
        let rgb = ThemeRGB(hex: hex)!
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
    }

    private func contrast(_ a: String, _ b: String) -> Double {
        let one = luminance(a), two = luminance(b)
        return (max(one, two) + 0.05) / (min(one, two) + 0.05)
    }

    func testAccentTextIsReadableOnEveryPresetInBothAppearances() {
        for preset in ThemePreset.allCases {
            for isDark in [false, true] {
                let tokens = ThemeCatalog.tokens(for: preset, isDark: isDark)
                let ratio = contrast(tokens.accentHex, tokens.accentTextHex)
                XCTAssertGreaterThanOrEqual(
                    ratio, 4.5,
                    "\(preset) dark=\(isDark): \(tokens.accentTextHex) on \(tokens.accentHex)"
                )
            }
        }
    }

    /// The worst case for "pick the better of black and white" is the luminance
    /// where the two are equal, which still clears 4.5:1 — so a custom accent
    /// cannot produce an unreadable button.
    func testCustomAccentsCannotProduceUnreadableText() {
        let samples = [
            "#000000", "#FFFFFF", "#808080", "#777777", "#767676",
            "#4FB89A", "#2F7D6A", "#F5B942", "#C2703D", "#3E8FB0",
            "#B48CF2", "#123456", "#ABCDEF", "#FF0000", "#00FF00", "#0000FF"
        ]
        for hex in samples {
            let text = AccentContrast.textColor(on: hex)
            XCTAssertGreaterThanOrEqual(contrast(hex, text), 4.5, "\(text) on \(hex)")
            XCTAssertTrue(text == "#000000" || text == "#FFFFFF")
        }
    }

    func testTheScreenshotsCaseIsTheDarkConvention() {
        // Celadon dark: a light accent, so filled controls carry dark text.
        // White there would read at about 2.4:1.
        let dark = ThemeCatalog.tokens(for: .celadon, isDark: true)
        XCTAssertEqual(dark.accentHex, "#4FB89A")
        XCTAssertEqual(ThemeCatalog.tokens(for: .celadon, isDark: true).accentTextHex, "#000000")
        XCTAssertGreaterThan(contrast("#4FB89A", "#FFFFFF"), 0)
        XCTAssertLessThan(contrast("#4FB89A", "#FFFFFF"), 3)

        // Celadon light: a dark accent, so filled controls carry white text.
        let light = ThemeCatalog.tokens(for: .celadon, isDark: false)
        XCTAssertEqual(light.accentHex, "#2F7D6A")
        XCTAssertEqual(light.accentTextHex, "#FFFFFF")
    }
}
