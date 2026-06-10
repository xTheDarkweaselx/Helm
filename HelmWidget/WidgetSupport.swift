//
//  WidgetSupport.swift
//  HelmWidget (STAGED — add to the widget target in Xcode; see README.md)
//
//  Small shared helpers for the widget views. Color(hex:) lives in the app
//  target, so the widget carries its own minimal copy.
//

import SwiftUI

extension Color {
    /// Minimal "RRGGBB" / "AARRGGBB" hex initialiser (widget-local copy).
    init?(helmHex hex: String?) {
        guard var hex else { return nil }
        hex = hex.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard let value = UInt64(hex, radix: 16) else { return nil }
        let r, g, b, a: Double
        switch hex.count {
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        case 8:
            a = Double((value >> 24) & 0xFF) / 255
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        default:
            return nil
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
