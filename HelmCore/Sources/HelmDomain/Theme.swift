//
//  Theme.swift
//  HelmDomain
//
//  v7 theming: the pure, Foundation-only theme CATALOG. Colors are stored as
//  hex strings (HelmDomain has no SwiftUI), decoded into `Color` by the app's
//  `ThemeManager`. The Default theme carries a nil accent (so it falls through
//  to the system accent — byte-identical to the pre-v7 look) and a .system
//  colour scheme. Everything here is headlessly unit-tested: hex validity,
//  id uniqueness, Default semantics, vibe coverage.
//

import Foundation

/// Light / dark / follow-the-system, stored as a raw String for an @AppStorage
/// or model-friendly round-trip.
public enum ThemeScheme: String, Sendable, CaseIterable, Codable {
    case system
    case light
    case dark
}

/// The flavour a theme belongs to — shown as a caption on the picker cards.
public enum ThemeVibe: String, Sendable, CaseIterable, Codable {
    case classic
    case professional
    case vibrant
    case dark
    case seasonal

    public var displayName: String {
        switch self {
        case .classic: "Classic"
        case .professional: "Professional"
        case .vibrant: "Vibrant"
        case .dark: "Dark"
        case .seasonal: "Seasonal"
        }
    }
}

/// One selectable theme. Pure value: the app maps `accentHex`/`secondaryHex`/
/// `glassTintHex` into `Color` and `scheme` into a `ColorScheme?`.
public struct ThemePalette: Sendable, Identifiable, Equatable, Codable {
    public let id: String
    public let name: String
    public let vibe: ThemeVibe
    /// nil → fall through to the system accent colour (the Default behaviour).
    public let accentHex: String?
    /// Optional companion accent for gradients / secondary emphasis.
    public let secondaryHex: String?
    public let scheme: ThemeScheme
    /// Optional tint laid faintly over glass materials (kept subtle in the UI).
    public let glassTintHex: String?
    /// v7.1 chrome wash: top-leading stop of the whole-app background gradient
    /// (RRGGBB). nil → unthemed system chrome (the Default). Wash OPACITY is an
    /// app-side scheme-keyed constant, deliberately not stored here.
    public let backgroundTopHex: String?
    /// Bottom-trailing stop. Pair invariant (tested): both nil or both set.
    public let backgroundBottomHex: String?

    public init(
        id: String,
        name: String,
        vibe: ThemeVibe,
        accentHex: String?,
        secondaryHex: String? = nil,
        scheme: ThemeScheme,
        glassTintHex: String? = nil,
        backgroundTopHex: String? = nil,
        backgroundBottomHex: String? = nil
    ) {
        self.id = id
        self.name = name
        self.vibe = vibe
        self.accentHex = accentHex
        self.secondaryHex = secondaryHex
        self.scheme = scheme
        self.glassTintHex = glassTintHex
        self.backgroundTopHex = backgroundTopHex
        self.backgroundBottomHex = backgroundBottomHex
    }
}

extension ThemePalette {
    /// Perceived luminance (0–1) of the wash (mean of its two stops), or nil when
    /// the theme has no wash.
    public var washLuminance: Double? {
        guard let a = backgroundTopHex.flatMap(Self.luminance(ofHex:)),
              let b = backgroundBottomHex.flatMap(Self.luminance(ofHex:)) else { return nil }
        return (a + b) / 2
    }

    /// The colour scheme this theme's CHROME should render under so its text stays
    /// legible: a dark-toned wash wants light text (`.dark`), a light-toned wash
    /// dark text (`.light`). nil when there's no wash → follow the catalog `scheme`
    /// (e.g. Default = system). This only flips the TEXT/scheme — the wash colours
    /// and glass are unchanged, so the theme's identity matches its preview card.
    public var legibleScheme: ThemeScheme? {
        guard let lum = washLuminance else { return nil }
        return lum < 0.5 ? .dark : .light
    }

    private static func luminance(ofHex hex: String) -> Double? {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        return 0.299 * r + 0.587 * g + 0.114 * b
    }
}

/// The fixed catalog of themes. Default first; at least five alternates spanning
/// the four requested vibes (professional, vibrant, dark-first, seasonal).
public enum ThemeCatalog {
    public static let defaultID = "default"

    public static let all: [ThemePalette] = [
        // Every optional nil — the byte-identical-to-unthemed guard.
        ThemePalette(id: "default", name: "Default", vibe: .classic,
                     accentHex: nil, scheme: .system, glassTintHex: nil),

        // Professional
        ThemePalette(id: "slate", name: "Slate", vibe: .professional,
                     accentHex: "3A4A5E", secondaryHex: "6E8CA8", scheme: .system,
                     glassTintHex: "6E8CA8",
                     backgroundTopHex: "5E7287", backgroundBottomHex: "8FA3B8"),
        ThemePalette(id: "graphite", name: "Graphite", vibe: .professional,
                     accentHex: "5B6770", secondaryHex: "8A99A6", scheme: .light,
                     glassTintHex: "8A99A6",
                     backgroundTopHex: "AEBAC6", backgroundBottomHex: "D8DEE4"),

        // Vibrant
        ThemePalette(id: "electric", name: "Electric", vibe: .vibrant,
                     accentHex: "7B2FF7", secondaryHex: "00C2FF", scheme: .system,
                     glassTintHex: "4C72D8",
                     backgroundTopHex: "6E3BD8", backgroundBottomHex: "2BA9D8"),
        ThemePalette(id: "sunrise", name: "Sunrise", vibe: .vibrant,
                     accentHex: "FF7A1A", secondaryHex: "FF3D77", scheme: .light,
                     glassTintHex: "FF8A4D",
                     backgroundTopHex: "FFE3C2", backgroundBottomHex: "FFB59B"),

        // Dark-first (deep tinted washes — the surfaces must read as the hue,
        // not stay system charcoal)
        ThemePalette(id: "midnight", name: "Midnight", vibe: .dark,
                     accentHex: "5E9BFF", secondaryHex: "8E7BFF", scheme: .dark,
                     glassTintHex: "1B2B4D",
                     backgroundTopHex: "0E1830", backgroundBottomHex: "233356"),
        ThemePalette(id: "carbon", name: "Carbon", vibe: .dark,
                     accentHex: "9AE6B4", secondaryHex: "4FD1C5", scheme: .dark,
                     glassTintHex: "1F3530",
                     backgroundTopHex: "141719", backgroundBottomHex: "1A2C26"),

        // Seasonal
        ThemePalette(id: "forest", name: "Forest", vibe: .seasonal,
                     accentHex: "2E7D5B", secondaryHex: "8FB339", scheme: .system,
                     glassTintHex: "4F8C68",
                     backgroundTopHex: "3E7A5C", backgroundBottomHex: "7FA65A"),
        // Light-green companion to Forest — a paler wash that stays a LIGHT
        // appearance (its wash luminance keeps legibleScheme = .light, black text).
        ThemePalette(id: "meadow", name: "Meadow", vibe: .seasonal,
                     accentHex: "2E7D5B", secondaryHex: "8FB339", scheme: .light,
                     glassTintHex: "7FB08C",
                     backgroundTopHex: "A9D3B0", backgroundBottomHex: "CDE6B8"),
        ThemePalette(id: "aurora", name: "Aurora", vibe: .seasonal,
                     accentHex: "C84CC8", secondaryHex: "4CC8C8", scheme: .dark,
                     glassTintHex: "301C55",
                     backgroundTopHex: "2A1245", backgroundBottomHex: "0E3A3F"),
    ]

    /// The Default palette (never nil — the resolution floor).
    public static var `default`: ThemePalette {
        all.first { $0.id == defaultID } ?? all[0]
    }

    /// Look up a theme by id; an unknown / absent id resolves to Default so a
    /// stale @AppStorage value (or a future-removed theme) is always safe.
    public static func palette(id: String?) -> ThemePalette {
        guard let id, let found = all.first(where: { $0.id == id }) else { return `default` }
        return found
    }
}
