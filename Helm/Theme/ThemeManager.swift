//
//  ThemeManager.swift
//  Helm
//
//  v7 theming runtime. One @Observable ThemeManager holds the selected theme id
//  (persisted in UserDefaults), and resolves the pure HelmDomain ThemePalette
//  into SwiftUI Colors + a ColorScheme. Injected ONCE at each scene root so the
//  main window and the macOS Settings window share a single source of truth.
//
//  Two propagation channels, both required (see the v7 design):
//   • CONTROLS get `.tint(theme.accent)` + `.preferredColorScheme(...)` at the root.
//   • CUSTOM DRAWING reads `\.helmAccent` / `\.helmGlassTint` from the environment —
//     because `Color.accentColor` does NOT follow `.tint()` in shape/Canvas fills.
//  The env colours carry SAFE DEFAULTS (.accentColor / nil) so any view renders
//  correctly even if the manager isn't injected (previews, tests).
//

import SwiftUI
import HelmDomain

@Observable
final class ThemeManager {
    static let storageKey = "selectedThemeID"

    var selectedID: String {
        didSet {
            guard oldValue != selectedID else { return }
            UserDefaults.standard.set(selectedID, forKey: Self.storageKey)
        }
    }

    init() {
        self.selectedID = UserDefaults.standard.string(forKey: Self.storageKey) ?? ThemeCatalog.defaultID
    }

    /// The resolved palette (unknown/absent id → Default).
    var palette: ThemePalette { ThemeCatalog.palette(id: selectedID) }
    var all: [ThemePalette] { ThemeCatalog.all }

    /// The accent for custom drawing + the accent-filled selected sidebar row
    /// (which pairs it with WHITE text, so it must stay mid-toned). Default → system.
    var accent: Color { palette.accentHex.flatMap { Color(hex: $0) } ?? .accentColor }

    private var isDarkChrome: Bool { resolvedColorScheme == .dark }

    /// The vivid, legible accent for TINTED controls/links + the SIDEBAR ICONS.
    /// The raw accent (e.g. Forest's 2E7D5B) sits right on its own wash and reads
    /// as grey; this keeps the hue + full saturation but shifts the LIGHTNESS so it
    /// always contrasts (validated ≥3:1 against every theme's wash). Default →
    /// system accent. `accent` (unchanged) still fills shapes + the selected row.
    var legibleAccent: Color {
        guard let hex = palette.accentHex else { return accent }
        return Self.hsl(hex, lightness: isDarkChrome ? 0.72 : 0.34, saturationMul: 1.0)
    }

    /// The themed body/label text colour — a crisp, clearly THEME-TINTED light
    /// (dark-chrome) or dark (light-chrome) derived from the WASH hue, so text is
    /// cohesive with the surface AND legible everywhere (validated ≥4.5:1). Applied
    /// as the root foreground; `.secondary`/`.tertiary` fade from it. Default →
    /// the system label colour (unchanged).
    var primaryText: Color {
        guard let wash = washAverageHex else { return .primary }
        return Self.hsl(wash, lightness: isDarkChrome ? 0.90 : 0.15, saturationMul: 0.65)
    }

    /// Text/icon colour for the SELECTED sidebar capsule, which is filled with the
    /// raw `accent`. Black or white — whichever has the higher WCAG contrast with
    /// the fill (W3C's 0.179 luminance pivot, equivalently "use black whenever
    /// white would fall below 4.5:1"). A light accent (Carbon's mint) otherwise got
    /// white text at ~1.5:1. Default (system accent) keeps the white convention.
    var onAccent: Color {
        guard let hex = palette.accentHex else { return .white }
        return Self.relativeLuminance(hex) > 0.179 ? .black : .white
    }

    /// WCAG relative luminance (sRGB-linearised) of a hex, for the on-accent pivot.
    private static func relativeLuminance(_ hex: String) -> Double {
        var s = hex; if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return 0 }
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let r = lin(Double((v >> 16) & 0xFF) / 255)
        let g = lin(Double((v >> 8) & 0xFF) / 255)
        let b = lin(Double(v & 0xFF) / 255)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// Vivid destructive red that reads on a themed wash (the inherited accent
    /// tint otherwise hides role:.destructive). Lighter on dark chrome.
    var destructive: Color {
        guard palette.accentHex != nil else { return .red } // Default → system red
        return (isDarkChrome ? Color(hex: "EC8E8E") : Color(hex: "C82222")) ?? .red
    }

    private var washAverageHex: String? {
        guard let t = palette.backgroundTopHex, let b = palette.backgroundBottomHex else { return nil }
        return Self.averageHex(t, b)
    }

    /// Re-light a hex in HSL (keep hue, scale saturation, set lightness) → Color.
    /// HSL (not the RGB-toward-white blend it replaced, which DESATURATED into mud).
    private static func hsl(_ hex: String, lightness L: Double, saturationMul sm: Double) -> Color {
        var s = hex; if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return .accentColor }
        let r = Double((v >> 16) & 0xFF) / 255, g = Double((v >> 8) & 0xFF) / 255, b = Double(v & 0xFF) / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        let l0 = (mx + mn) / 2
        var h = 0.0, sat = 0.0
        if d != 0 {
            sat = d / (1 - abs(2 * l0 - 1))
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h *= 60; if h < 0 { h += 360 }
        }
        let newS = min(1, sat * sm)
        let c = (1 - abs(2 * L - 1)) * newS
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = L - c / 2
        let (rr, gg, bb): (Double, Double, Double)
        switch h {
        case 0..<60:   (rr, gg, bb) = (c, x, 0)
        case 60..<120: (rr, gg, bb) = (x, c, 0)
        case 120..<180:(rr, gg, bb) = (0, c, x)
        case 180..<240:(rr, gg, bb) = (0, x, c)
        case 240..<300:(rr, gg, bb) = (x, 0, c)
        default:       (rr, gg, bb) = (c, 0, x)
        }
        return Color(.sRGB, red: rr + m, green: gg + m, blue: bb + m)
    }

    private static func averageHex(_ a: String, _ b: String) -> String? {
        guard let va = UInt64(a, radix: 16), let vb = UInt64(b, radix: 16) else { return nil }
        let r = (Int((va >> 16) & 0xFF) + Int((vb >> 16) & 0xFF)) / 2
        let g = (Int((va >> 8) & 0xFF) + Int((vb >> 8) & 0xFF)) / 2
        let bl = (Int(va & 0xFF) + Int(vb & 0xFF)) / 2
        return String(format: "%02X%02X%02X", r, g, bl)
    }
    var secondary: Color? { palette.secondaryHex.flatMap { Color(hex: $0) } }
    var glassTint: Color? { palette.glassTintHex.flatMap { Color(hex: $0) } }
    /// v7.1 chrome wash gradient stops (nil for Default → unthemed chrome).
    var backgroundTop: Color? { palette.backgroundTopHex.flatMap { Color(hex: $0) } }
    var backgroundBottom: Color? { palette.backgroundBottomHex.flatMap { Color(hex: $0) } }

    /// The scheme the chrome renders under. Uses the wash-derived legible scheme
    /// (so a dark-toned theme gets light text, a light one dark text) and only
    /// falls back to the catalog scheme when there's no wash (Default = system).
    /// The wash/glass appearance is unchanged — this just keeps text readable.
    var resolvedColorScheme: ColorScheme? {
        switch palette.legibleScheme ?? palette.scheme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

// MARK: - Environment colours (safe-defaulted, for custom drawing)

private struct HelmAccentKey: EnvironmentKey {
    static let defaultValue: Color = .accentColor
}
private struct HelmSecondaryKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}
private struct HelmGlassTintKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}
private struct HelmBackgroundTopKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}
private struct HelmBackgroundBottomKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    /// The theme accent for shape/Canvas fills (never nil — defaults to .accentColor).
    var helmAccent: Color {
        get { self[HelmAccentKey.self] }
        set { self[HelmAccentKey.self] = newValue }
    }
    var helmSecondary: Color? {
        get { self[HelmSecondaryKey.self] }
        set { self[HelmSecondaryKey.self] = newValue }
    }
    /// A faint tint laid over glass materials, or nil for plain material.
    var helmGlassTint: Color? {
        get { self[HelmGlassTintKey.self] }
        set { self[HelmGlassTintKey.self] = newValue }
    }
    /// v7.1 chrome wash stops — nil (the defaults) means unthemed chrome.
    var helmBackgroundTop: Color? {
        get { self[HelmBackgroundTopKey.self] }
        set { self[HelmBackgroundTopKey.self] = newValue }
    }
    var helmBackgroundBottom: Color? {
        get { self[HelmBackgroundBottomKey.self] }
        set { self[HelmBackgroundBottomKey.self] = newValue }
    }
}

extension View {
    /// Apply a ThemeManager at a scene root: controls (.tint), colour scheme,
    /// the observable itself (for Settings), and the custom-drawing env colours.
    func helmThemed(_ theme: ThemeManager) -> some View {
        self
            .environment(theme)
            .environment(\.helmAccent, theme.accent)
            .environment(\.helmSecondary, theme.secondary)
            .environment(\.helmGlassTint, theme.glassTint)
            .environment(\.helmBackgroundTop, theme.backgroundTop)
            .environment(\.helmBackgroundBottom, theme.backgroundBottom)
            .tint(theme.legibleAccent)
            .foregroundStyle(theme.primaryText) // cohesive, theme-tinted text (secondary fades from it)
            .preferredColorScheme(theme.resolvedColorScheme)
    }
}
