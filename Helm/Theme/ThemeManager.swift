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

    /// The accent used to TINT controls + accent-coloured text/buttons. Several
    /// themes put the accent very close to their own wash (e.g. Forest's 2E7D5B
    /// over a 3E7A5C wash), so accent text vanished. This nudges the accent toward
    /// contrast with the wash — lighter on dark (white-text) themes, darker on
    /// light ones — so links/buttons stay legible. `accent` (unchanged) is kept
    /// for shape fills + the selected row.
    var legibleAccent: Color {
        guard let hex = palette.accentHex else { return accent } // Default → system accent
        switch resolvedColorScheme {
        case .dark: return Self.adjust(hex, by: 0.5)    // lighten toward white
        case .light: return Self.adjust(hex, by: -0.18) // darken toward black
        default: return accent
        }
    }

    /// The themed body/label text colour — a legible, theme-TINTED alternative to
    /// stark black/white, so the app's text feels cohesive with the wash and is
    /// consistent everywhere. Light + green-tinted on dark themes, dark + green-
    /// tinted on light ones. Default → the system label colour (unchanged). Used
    /// as the root foreground; `.secondary`/`.tertiary` then fade FROM this, so
    /// secondary text is automatically a muted, theme-tracking shade.
    var primaryText: Color {
        guard let hex = palette.accentHex else { return .primary }
        switch resolvedColorScheme {
        case .dark: return Self.adjust(hex, by: 0.82)   // light, faintly green
        case .light: return Self.adjust(hex, by: -0.55) // dark, faintly green
        default: return .primary
        }
    }

    /// Lighten (amount > 0, toward white) or darken (amount < 0, toward black) a hex.
    private static func adjust(_ hex: String, by amount: Double) -> Color {
        var s = hex; if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return .accentColor }
        var r = Double((v >> 16) & 0xFF) / 255, g = Double((v >> 8) & 0xFF) / 255, b = Double(v & 0xFF) / 255
        if amount >= 0 { r += (1 - r) * amount; g += (1 - g) * amount; b += (1 - b) * amount }
        else { let k = 1 + amount; r *= k; g *= k; b *= k }
        return Color(.sRGB, red: r, green: g, blue: b)
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
