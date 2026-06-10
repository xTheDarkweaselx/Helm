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

/// The flavour a theme belongs to — used to group the picker into sections.
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

    /// Stable ordering for the picker sections.
    public var sortOrder: Int {
        switch self {
        case .classic: 0
        case .professional: 1
        case .vibrant: 2
        case .dark: 3
        case .seasonal: 4
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

    public init(
        id: String,
        name: String,
        vibe: ThemeVibe,
        accentHex: String?,
        secondaryHex: String? = nil,
        scheme: ThemeScheme,
        glassTintHex: String? = nil
    ) {
        self.id = id
        self.name = name
        self.vibe = vibe
        self.accentHex = accentHex
        self.secondaryHex = secondaryHex
        self.scheme = scheme
        self.glassTintHex = glassTintHex
    }
}

/// The fixed catalog of themes. Default first; at least five alternates spanning
/// the four requested vibes (professional, vibrant, dark-first, seasonal).
public enum ThemeCatalog {
    public static let defaultID = "default"

    public static let all: [ThemePalette] = [
        ThemePalette(id: "default", name: "Default", vibe: .classic,
                     accentHex: nil, scheme: .system, glassTintHex: nil),

        // Professional
        ThemePalette(id: "slate", name: "Slate", vibe: .professional,
                     accentHex: "3A4A5E", secondaryHex: "6E8CA8", scheme: .system),
        ThemePalette(id: "graphite", name: "Graphite", vibe: .professional,
                     accentHex: "5B6770", secondaryHex: "8A99A6", scheme: .light),

        // Vibrant
        ThemePalette(id: "electric", name: "Electric", vibe: .vibrant,
                     accentHex: "7B2FF7", secondaryHex: "00C2FF", scheme: .system),
        ThemePalette(id: "sunrise", name: "Sunrise", vibe: .vibrant,
                     accentHex: "FF7A1A", secondaryHex: "FF3D77", scheme: .light),

        // Dark-first
        ThemePalette(id: "midnight", name: "Midnight", vibe: .dark,
                     accentHex: "5E9BFF", secondaryHex: "8E7BFF", scheme: .dark, glassTintHex: "0E1726"),
        ThemePalette(id: "carbon", name: "Carbon", vibe: .dark,
                     accentHex: "9AE6B4", secondaryHex: "4FD1C5", scheme: .dark, glassTintHex: "111315"),

        // Seasonal
        ThemePalette(id: "forest", name: "Forest", vibe: .seasonal,
                     accentHex: "2E7D5B", secondaryHex: "8FB339", scheme: .system),
        ThemePalette(id: "aurora", name: "Aurora", vibe: .seasonal,
                     accentHex: "C84CC8", secondaryHex: "4CC8C8", scheme: .dark, glassTintHex: "141029"),
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

    /// Themes grouped by vibe in display order (for the picker sections).
    public static var grouped: [(vibe: ThemeVibe, palettes: [ThemePalette])] {
        Dictionary(grouping: all, by: \.vibe)
            .sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { (vibe: $0.key, palettes: $0.value) }
    }
}
