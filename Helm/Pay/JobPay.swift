//
//  JobPay.swift
//  Helm
//
//  v9 Multiple Jobs. A roster can represent one job/employer with its own hourly
//  rate and premium rules; pay is then the SUM of each job computed under its own
//  rules. This resolves a roster's effective `PayRules` (per-roster rate/premiums
//  when set, else the global Settings defaults — overtime & tax-year stay global,
//  they're person-level), and aggregates a period into a combined total plus a
//  per-employer breakdown. Computing each job independently also makes weekly
//  overtime correctly per-employer rather than pooled across jobs.
//

import Foundation
import HelmDomain

// MARK: - Roster pay accessors

extension Roster {
    /// Name to show in per-employer subtotals: the employer override, else the
    /// roster title, else a generic fallback.
    var employerDisplayName: String {
        if let e = employerName?.trimmingCharacters(in: .whitespaces), !e.isEmpty { return e }
        if let t = title?.trimmingCharacters(in: .whitespaces), !t.isEmpty { return t }
        return "This job"
    }

    /// Decoded per-roster premium rules, or nil to inherit the global ones.
    var premiumRules: [PremiumRule]? {
        guard let data = premiumRulesData else { return nil }
        return try? JSONDecoder().decode([PremiumRule].self, from: data)
    }
    /// Per-roster stacking, or nil to inherit global.
    var premiumStacking: PremiumStacking? {
        premiumStackingRaw.flatMap(PremiumStacking.init(rawValue:))
    }

    /// True when this roster carries ANY pay override (employer/rate/premiums).
    var hasPayOverride: Bool {
        hourlyRateOverride != nil || premiumRulesData != nil
            || (employerName?.trimmingCharacters(in: .whitespaces).isEmpty == false)
    }
}

// MARK: - Aggregation

/// One employer's slice of a period.
struct EmployerPay: Identifiable {
    let id: String          // roster id ("" = shifts with no roster)
    let employer: String
    let rate: Double
    let summary: PaySummary
}

/// One timesheet row tagged with its employer (for the multi-job shift list / CSV).
struct TimesheetRow: Identifiable {
    let id: String
    let employer: String
    let item: PayLineItem
}

enum JobPay {
    /// A roster's effective pay rules. Rate and premiums come from the roster when
    /// it sets them, otherwise from the global rules; overtime and the tax-year
    /// boundary are always global (they describe the person, not the job).
    static func rules(for roster: Roster?, global: PayRules) -> PayRules {
        guard let roster else { return global }
        return PayRules(
            hourlyRate: roster.hourlyRateOverride ?? global.hourlyRate,
            overtimeEnabled: global.overtimeEnabled,
            overtimeThresholdHours: global.overtimeThresholdHours,
            overtimeMultiplier: global.overtimeMultiplier,
            taxYearStartMonth: global.taxYearStartMonth,
            taxYearStartDay: global.taxYearStartDay,
            premiumRules: roster.premiumRules ?? global.premiumRules,
            premiumStacking: roster.premiumStacking ?? global.premiumStacking,
            bankHolidays: global.bankHolidays
        )
    }

    /// Combined total + per-employer subtotals for a range. Each roster's shifts
    /// are evaluated under that roster's resolved rules, then summed.
    static func breakdown(instances: [ShiftInstance], in range: ClosedRange<DayKey>,
                          global: PayRules, calendar: Calendar) -> (combined: PaySummary, employers: [EmployerPay]) {
        let groups = Dictionary(grouping: instances) { $0.roster?.id ?? "" }
        var all: [PaySummary] = []           // every group, so tentative counts survive
        var employers: [EmployerPay] = []    // only jobs with actual paid activity
        for (rid, group) in groups {
            let roster = group.first?.roster
            let resolved = rules(for: roster, global: global)
            let shifts = InsightsSnapshot.shifts(from: group)
            let summary = PayEngine.summary(shifts: shifts, in: range, rules: resolved, calendar: calendar)
            guard summary.shiftCount > 0 else { continue }
            all.append(summary)
            // A job whose only in-range shifts are tentative (no hours/pay) shouldn't
            // appear as a £0 employer row or flip the timesheet into multi-job layout —
            // but its tentative count still belongs in the combined total above.
            guard summary.totalHours > 0 || summary.grossPay > 0 else { continue }
            employers.append(EmployerPay(id: rid,
                                         employer: roster?.employerDisplayName ?? "Other shifts",
                                         rate: resolved.hourlyRate,
                                         summary: summary))
        }
        employers.sort { $0.summary.grossPay > $1.summary.grossPay }
        let combined = all.reduce(.zero, add)
        return (combined, employers)
    }

    /// Per-shift rows across all jobs, each under its own rules, chronological.
    static func rows(instances: [ShiftInstance], in range: ClosedRange<DayKey>,
                     global: PayRules, calendar: Calendar) -> [TimesheetRow] {
        let groups = Dictionary(grouping: instances) { $0.roster?.id ?? "" }
        var rows: [TimesheetRow] = []
        for (rid, group) in groups {
            let roster = group.first?.roster
            let resolved = rules(for: roster, global: global)
            let shifts = InsightsSnapshot.shifts(from: group)
            let name = roster?.employerDisplayName ?? "Other shifts"
            for item in PayEngine.lineItems(shifts: shifts, in: range, rules: resolved, calendar: calendar) {
                rows.append(TimesheetRow(id: "\(rid)#\(item.id)", employer: name, item: item))
            }
        }
        return rows.sorted { lhs, rhs in
            if lhs.item.day != rhs.item.day { return lhs.item.day < rhs.item.day }
            return (lhs.item.start ?? .distantPast) < (rhs.item.start ?? .distantPast)
        }
    }

    /// Adds two summaries (for the combined headline across jobs).
    static func add(_ a: PaySummary, _ b: PaySummary) -> PaySummary {
        PaySummary(totalHours: a.totalHours + b.totalHours,
                   baseHours: a.baseHours + b.baseHours,
                   overtimeHours: a.overtimeHours + b.overtimeHours,
                   basePay: a.basePay + b.basePay,
                   overtimePay: a.overtimePay + b.overtimePay,
                   premiumPay: a.premiumPay + b.premiumPay,
                   shiftCount: a.shiftCount + b.shiftCount,
                   tentativeCount: a.tentativeCount + b.tentativeCount)
    }
}
