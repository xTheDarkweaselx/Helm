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
    static let premiumRulesKey = "payPremiumRules"          // v9 — JSON [PremiumRule]
    static let premiumStackingKey = "payPremiumStacking"    // v9 — "highest" | "sum"

    static let defaultThreshold = 40.0
    static let defaultMultiplier = 1.5

    /// Tax-year start (month, day) for a stored preset.
    static func taxYearStart(for preset: String) -> (month: Int, day: Int) {
        preset == "calendar" ? (1, 1) : (4, 6) // default UK 6 April
    }

    /// User-authored premium rules (v9), persisted as JSON.
    static var premiumRules: [PremiumRule] {
        get {
            guard let data = UserDefaults.standard.data(forKey: premiumRulesKey),
                  let rules = try? JSONDecoder().decode([PremiumRule].self, from: data) else { return [] }
            return rules
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: premiumRulesKey) }
    }

    static var premiumStacking: PremiumStacking {
        get { PremiumStacking(rawValue: UserDefaults.standard.string(forKey: premiumStackingKey) ?? "") ?? .highest }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: premiumStackingKey) }
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
            taxYearStartDay: day,
            premiumRules: premiumRules,
            premiumStacking: premiumStacking,
            bankHolidays: [] // holiday-date management is a follow-up sub-step
        )
    }

    static var currencyCode: String { Locale.current.currency?.identifier ?? "GBP" }
}
