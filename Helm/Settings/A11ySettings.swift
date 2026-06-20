//
//  A11ySettings.swift
//  Helm
//
//  v9 Accessibility. App-level toggles that complement (never fight) the system
//  settings. Helm already honours system Dynamic Type, Bold Text and Reduce
//  Motion automatically; these add an in-app override so a user can flatten the
//  Liquid-Glass translucency for legibility without changing it system-wide.
//

import Foundation

enum A11ySettings {
    /// Flatten translucent glass to solid surfaces. Composed with (OR'd against)
    /// the system `accessibilityReduceTransparency` by the glass components.
    static let reduceTransparencyKey = "a11yReduceTransparency"

    static var reduceTransparency: Bool { UserDefaults.standard.bool(forKey: reduceTransparencyKey) }
}
