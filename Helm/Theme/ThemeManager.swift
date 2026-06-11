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

    /// The accent for controls AND custom drawing. Default theme → system accent.
    var accent: Color { palette.accentHex.flatMap { Color(hex: $0) } ?? .accentColor }
    var secondary: Color? { palette.secondaryHex.flatMap { Color(hex: $0) } }
    var glassTint: Color? { palette.glassTintHex.flatMap { Color(hex: $0) } }
    /// v7.1 chrome wash gradient stops (nil for Default → unthemed chrome).
    var backgroundTop: Color? { palette.backgroundTopHex.flatMap { Color(hex: $0) } }
    var backgroundBottom: Color? { palette.backgroundBottomHex.flatMap { Color(hex: $0) } }

    var resolvedColorScheme: ColorScheme? {
        switch palette.scheme {
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
            .tint(theme.accent)
            .preferredColorScheme(theme.resolvedColorScheme)
    }
}
