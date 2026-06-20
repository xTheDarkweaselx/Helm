//
//  ModuleSettings.swift
//  Helm
//
//  v9 Modules. Secondary features the user can switch off to declutter the app.
//  Each defaults to ON (so existing setups are unchanged); turning one off hides
//  its sidebar item, Overview cards, Settings sections and menu entries — without
//  deleting any data, so flipping it back on restores everything.
//
//  The @AppStorage keys are stable strings ("module_<case>"); views read them
//  directly with @AppStorage(..., default: true) for reactivity, and non-view
//  callers use ModuleSettings.isEnabled(_:).
//

import Foundation

enum AppModule: String, CaseIterable, Identifiable {
    case pay, planning, insights
    var id: String { rawValue }

    var title: String {
        switch self {
        case .pay: "Pay & Timesheet"
        case .planning: "Planning"
        case .insights: "Insights dashboard"
        }
    }
    var summary: String {
        switch self {
        case .pay: "Pay card, Timesheet, premium pay, multiple jobs, payday forecast and payslips."
        case .planning: "Time off & availability, and the Overview leave card."
        case .insights: "The Overview analytics — weekly-hours chart, shift mix and streaks."
        }
    }
    var icon: String {
        switch self {
        case .pay: "banknote"
        case .planning: "calendar.badge.clock"
        case .insights: "chart.bar.xaxis"
        }
    }
    /// UserDefaults / @AppStorage key. Stable — do not rename.
    var key: String { "module_\(rawValue)" }
}

enum ModuleSettings {
    /// Modules default to ON: an absent key reads as enabled.
    static func isEnabled(_ module: AppModule) -> Bool {
        UserDefaults.standard.object(forKey: module.key) as? Bool ?? true
    }
}
