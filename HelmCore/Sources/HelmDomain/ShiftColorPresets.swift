//
//  ShiftColorPresets.swift
//  HelmDomain
//
//  v7: a curated palette of shift-type colours offered as quick swatches in the
//  Shift Type editor (a tasteful default set instead of forcing the system
//  colour wheel for every new type), and the deterministic palette tags draw
//  from when they have no custom colour. Pure hex strings — the app decodes.
//

import Foundation

public enum ShiftColorPresets {
    /// Twelve well-spaced, accessible hues for shift types. Order is intentional
    /// (warm → cool → neutral) so the swatch grid reads pleasantly.
    public static let all: [String] = [
        "E5484D", // red
        "F76808", // orange
        "FFB224", // amber
        "F5D90A", // yellow
        "46A758", // green
        "12A594", // teal
        "00A2C7", // cyan
        "0091FF", // blue
        "3E63DD", // indigo
        "8E4EC6", // purple
        "E93D82", // pink
        "8B8D98", // slate-grey
    ]

    /// The hues tags cycle through when uncoloured — a slightly cooler subset so
    /// tag pills don't clash with shift-type chips that use the full set.
    public static let tagPalette: [String] = [
        "0091FF", // blue
        "12A594", // teal
        "8E4EC6", // purple
        "46A758", // green
        "E93D82", // pink
        "F76808", // orange
        "3E63DD", // indigo
        "8B8D98", // slate-grey
    ]
}
