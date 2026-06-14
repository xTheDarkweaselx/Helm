//
//  PaySettings.swift
//  Helm
//
//  v8: resolves the user's pay preferences (UserDefaults) into a pure
//  HelmDomain `PayRules`. One source of truth shared by the Settings form, the
//  Overview pay card, and the Timesheet. The hourly-rate key is the pre-v8
//  "hourlyRate" so existing values carry over.
//

import Foundation
import HelmDomain

enum PaySettings {
    static let rateKey = "hourlyRate"                       // pre-v8 — preserved
    static let overtimeEnabledKey = "payOvertimeEnabled"
    static let overtimeThresholdKey = "payOvertimeThreshold"
    static let overtimeMultiplierKey = "payOvertimeMultiplier"
    static let taxYearPresetKey = "payTaxYearPreset"        // "uk" | "calendar"

    static let defaultThreshold = 40.0
    static let defaultMultiplier = 1.5

    /// Tax-year start (month, day) for a stored preset.
    static func taxYearStart(for preset: String) -> (month: Int, day: Int) {
        preset == "calendar" ? (1, 1) : (4, 6) // default UK 6 April
    }

    static var rules: PayRules {
        let d = UserDefaults.standard
        let (month, day) = taxYearStart(for: d.string(forKey: taxYearPresetKey) ?? "uk")
        return PayRules(
            hourlyRate: d.double(forKey: rateKey),
            overtimeEnabled: d.bool(forKey: overtimeEnabledKey),
            overtimeThresholdHours: (d.object(forKey: overtimeThresholdKey) as? Double) ?? defaultThreshold,
            overtimeMultiplier: (d.object(forKey: overtimeMultiplierKey) as? Double) ?? defaultMultiplier,
            taxYearStartMonth: month,
            taxYearStartDay: day
        )
    }

    static var currencyCode: String { Locale.current.currency?.identifier ?? "GBP" }
}
