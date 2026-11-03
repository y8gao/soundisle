import AppKit
import SoundIsleCore
import SwiftUI

// MARK: - Palette

/// UI-side colours for one resolved theme. Core owns the accent contract;
/// this type adds the background skin, glass tints and control fills.
struct ThemePalette {
    let preset: ThemePreset
    let tokens: ThemeTokens

    let accent: Color
    let accentSecondary: Color
    let accentLight: Color
    let accentGradient: LinearGradient
    let onAccent: Color
    let text: Color
    let warning: Color
    let panelTint: Color
    let playerTint: Color
    let backgroundTop: Color
    let backgroundMiddle: Color
    let backgroundBottom: Color
    let coverGradient: LinearGradient
    let hairline: Color
    let raisedFill: Color
    let sliderTrack: Color

    var isDark: Bool { tokens.isDark }

    /// Secondary text/icons stay subtle in dark mode but are raised on light
    /// backgrounds, where opacity 0.4–0.55 is only about 2.6–3.3:1 contrast.
    func mutedText(_ base: Double) -> Color {
        text.opacity(isDark ? base : max(base, 0.62))
    }

    init(preset: ThemePreset, tokens: ThemeTokens) {
        self.preset = preset
        self.tokens = tokens

        let skin = Self.skin(for: preset)
        let accentRGB = ThemeRGB(hex: tokens.accentHex) ?? ThemeRGB(red: 0.48, green: 0.64, blue: 1)
        let secondaryRGB = ThemeRGB(hex: tokens.isDark ? skin.darkGlow : skin.lightGlow)
            ?? ThemeRGB(red: 0.71, green: 0.55, blue: 0.95)

        let accent = Color(rgb: accentRGB)
        let secondary = Color(rgb: secondaryRGB)
        self.accent = accent
        self.accentSecondary = secondary
        self.accentGradient = LinearGradient(
            colors: [accent, secondary],
            startPoint: .leading,
            endPoint: .trailing
        )
        self.accentLight = Color(rgb: accentRGB.blended(
            with: tokens.isDark ? .white : .black,
            amount: tokens.isDark ? 0.55 : 0.28
        ))
        self.onAccent = Color(hex: tokens.accentTextHex)
        self.text = Color(hex: tokens.isDark ? "#EDF0FA" : "#1B1F27")
        self.warning = Color(hex: tokens.isDark ? "#FFB766" : "#A65F00")
        self.panelTint = Color(hex: tokens.isDark ? skin.darkPanel : skin.lightPanel)
        self.playerTint = Color(hex: tokens.isDark ? skin.darkPlayer : skin.lightPlayer)
        self.backgroundTop = Color(hex: tokens.isDark ? skin.darkTop : skin.lightTop)
        self.backgroundMiddle = Color(hex: tokens.isDark ? skin.darkMiddle : skin.lightMiddle)
        self.backgroundBottom = Color(hex: tokens.isDark ? skin.darkBottom : skin.lightBottom)
        self.coverGradient = LinearGradient(
            colors: [accent, secondary, Color(hex: tokens.isDark ? "#C45B8E" : "#D98AB4")],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        self.hairline = tokens.isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.09)
        self.raisedFill = tokens.isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.055)
        self.sliderTrack = tokens.isDark ? Color.white.opacity(0.15) : Color.black.opacity(0.13)
    }

    /// Resolves the persisted settings plus the effective system appearance.
    static func resolve(
        preset: ThemePreset,
        mode: ThemeMode,
        customAccentHex: String?,
        systemIsDark: Bool
    ) -> ThemePalette {
        let isDark = ThemeResolver.isDark(mode: mode, systemIsDark: systemIsDark)
        return ThemePalette(
            preset: preset,
            tokens: ThemeCatalog.tokens(
                for: preset,
                isDark: isDark,
                customAccentHex: customAccentHex
            )
        )
    }

    private struct Skin {
        let darkTop: String
        let darkMiddle: String
        let darkBottom: String
        let darkPanel: String
        let darkPlayer: String
        let darkGlow: String
        let lightTop: String
        let lightMiddle: String
        let lightBottom: String
        let lightPanel: String
        let lightPlayer: String
        let lightGlow: String
    }

    private static func skin(for preset: ThemePreset) -> Skin {
        switch preset {
        case .deepBlue:
            return Skin(
                darkTop: "#121521", darkMiddle: "#1B2132", darkBottom: "#161B28",
                darkPanel: "#141824", darkPlayer: "#0A0D16", darkGlow: "#D660A8",
                lightTop: "#F4F7FD", lightMiddle: "#E8EEFA", lightBottom: "#FBFDFF",
                lightPanel: "#FFFFFF", lightPlayer: "#F4F7FE", lightGlow: "#8FA9F2"
            )
        case .morning:
            return Skin(
                darkTop: "#1A1411", darkMiddle: "#2A1D15", darkBottom: "#231811",
                darkPanel: "#201814", darkPlayer: "#140F0C", darkGlow: "#E0A15C",
                lightTop: "#FBF4EC", lightMiddle: "#F5E6D6", lightBottom: "#FFFCF8",
                lightPanel: "#FFFCF9", lightPlayer: "#FAF1E8", lightGlow: "#E8A566"
            )
        case .inkAmber:
            return Skin(
                darkTop: "#0F0E0A", darkMiddle: "#1D1810", darkBottom: "#15110A",
                darkPanel: "#18140D", darkPlayer: "#0C0A07", darkGlow: "#C97B2B",
                lightTop: "#FBF7EA", lightMiddle: "#F2E9CF", lightBottom: "#FFFDF5",
                lightPanel: "#FFFCF3", lightPlayer: "#FAF4E6", lightGlow: "#C98A32"
            )
        case .celadon:
            return Skin(
                darkTop: "#0C1716", darkMiddle: "#142724", darkBottom: "#0F1F1C",
                darkPanel: "#12201E", darkPlayer: "#091311", darkGlow: "#7FC7B0",
                lightTop: "#EFF7F4", lightMiddle: "#DFF0EA", lightBottom: "#FAFDFC",
                lightPanel: "#FBFEFD", lightPlayer: "#EDF7F3", lightGlow: "#79B79F"
            )
        case .berry:
            return Skin(
                darkTop: "#160F1C", darkMiddle: "#271731", darkBottom: "#1B1024",
                darkPanel: "#1C1226", darkPlayer: "#0F0914", darkGlow: "#E28BC4",
                lightTop: "#F8F1FC", lightMiddle: "#EEE0F7", lightBottom: "#FDFAFF",
                lightPanel: "#FFFCFF", lightPlayer: "#F7EFFC", lightGlow: "#C87CAF"
            )
        case .seaSalt:
            return Skin(
                darkTop: "#0C161B", darkMiddle: "#132630", darkBottom: "#0E1E26",
                darkPanel: "#11212A", darkPlayer: "#081116", darkGlow: "#7FC4D8",
                lightTop: "#EEF6FA", lightMiddle: "#DDEDF5", lightBottom: "#F9FDFF",
                lightPanel: "#FBFEFF", lightPlayer: "#EDF6FB", lightGlow: "#6FAFC4"
            )
        }
    }
}

// MARK: - Environment

private struct ThemePaletteKey: EnvironmentKey {
    static let defaultValue = ThemePalette(
        preset: .deepBlue,
        tokens: ThemeCatalog.tokens(for: .deepBlue, isDark: true)
    )
}

extension EnvironmentValues {
    var theme: ThemePalette {
        get { self[ThemePaletteKey.self] }
        set { self[ThemePaletteKey.self] = newValue }
    }
}

extension View {
    /// Applies a resolved palette to this subtree. Root windows call it once;
    /// every descendant reads `@Environment(\.theme)`.
    func soundIsleTheme(_ palette: ThemePalette) -> some View {
        environment(\.theme, palette)
    }
}

// MARK: - Shared drawing

/// Blurred desktop/window behind a clear window. Shared by the main window,
/// the settings sheet, the mini player and the lyrics overlay.
struct MaterialBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct AppBackground: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            // The window is clear; this is the glass the content floats on.
            MaterialBackdrop()

            LinearGradient(
                colors: [
                    theme.backgroundTop.opacity(theme.isDark ? 0.70 : 0.80),
                    theme.backgroundMiddle.opacity(theme.isDark ? 0.60 : 0.70),
                    theme.backgroundBottom.opacity(theme.isDark ? 0.72 : 0.82),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Ambient colour blobs, drawn once and never animated.
            Circle()
                .fill(theme.accent.opacity(theme.isDark ? 0.22 : 0.16))
                .frame(width: 420, height: 420)
                .blur(radius: 120)
                .offset(x: -250, y: -210)
            Circle()
                .fill(theme.accentSecondary.opacity(theme.isDark ? 0.18 : 0.12))
                .frame(width: 380, height: 380)
                .blur(radius: 120)
                .offset(x: 280, y: 170)

            RadialGradient(
                colors: [theme.accent.opacity(theme.isDark ? 0.26 : 0.16), .clear],
                center: UnitPoint(x: 0.12, y: 0.05),
                startRadius: 0,
                endRadius: 480
            )
            RadialGradient(
                colors: [theme.accentSecondary.opacity(theme.isDark ? 0.18 : 0.12), .clear],
                center: UnitPoint(x: 0.88, y: 0.22),
                startRadius: 0,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}

private struct GlassPanelModifier: ViewModifier {
    @Environment(\.theme) private var theme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(theme.panelTint.opacity(theme.isDark ? 0.55 : 0.78), in: shape)
            .background(.ultraThinMaterial, in: shape)
            .overlay(shape.strokeBorder(theme.hairline, lineWidth: 0.5))
    }
}

extension View {
    /// Frosted panel: material blurs what is behind, a translucent tint gives
    /// the theme cast, and a hairline border catches the light.
    func glassPanel(cornerRadius: CGFloat = 12) -> some View {
        modifier(GlassPanelModifier(cornerRadius: cornerRadius))
    }
}

// MARK: - Color bridges

extension Color {
    init(hex: String) {
        self.init(rgb: ThemeRGB(hex: hex) ?? ThemeRGB(red: 0.5, green: 0.5, blue: 0.5))
    }

    init(rgb: ThemeRGB) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: 1)
    }

    /// `ColorPicker` hands back an opaque `Color`; persist it as `#RRGGBB`.
    var hexString: String {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return "#FFFFFF" }
        return ThemeRGB(
            red: Double(rgb.redComponent),
            green: Double(rgb.greenComponent),
            blue: Double(rgb.blueComponent)
        ).hexString
    }
}
