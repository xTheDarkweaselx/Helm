//
//  PremiumPay.swift
//  HelmDomain
//
//  v9 Premium Pay: enhanced rates for shifts a flat hourly rate underpays —
//  night/unsocial hours, weekends, bank holidays, on-call. PURE value types +
//  a pure extension on PayEngine, so the whole thing is unit-tested with no
//  SwiftData/SwiftUI. Everything is USER-CONFIGURED and clearly an estimate:
//  the engine encodes NO jurisdiction law, it just applies the rules it's given.
//
//  Model: a `PremiumRule` is a TRIGGER (when it applies) + an ADJUSTMENT (how it
//  changes pay). Triggers can be whole-shift (weekday / bank-holiday / type-tag)
//  or hour-banded (a daily time window, e.g. 22:00–06:00 — only the overlapping
//  hours are enhanced). Where rules overlap on the same hour, the stacking policy
//  decides: `.highest` (the single best enhancement wins — the common rule) or
//  `.sum` (they add). Premium pay is the EXTRA above base (hours × rate); base
//  and weekly overtime are unchanged.
//

import Foundation

/// When a premium rule applies to a shift (or to hours within it).
public enum PremiumTrigger: Sendable, Equatable, Codable, Hashable {
    /// Whole shift, when its civil day is one of these weekdays (Calendar
    /// convention: 1 = Sunday … 7 = Saturday).
    case weekdays(Set<Int>)
    /// Whole shift, when its day is in the bank-holiday set the engine is given.
    case bankHoliday
    /// Only the hours that fall inside this recurring daily window, in minutes
    /// from local midnight. May wrap past midnight (e.g. 1320…360 = 22:00–06:00).
    case timeWindow(startMinute: Int, endMinute: Int)
    /// Whole shift, when its type carries this tag (matched case-insensitively).
    case shiftTag(String)
}

/// How a premium changes pay for the hours it applies to.
public enum PremiumAdjustment: Sendable, Equatable, Codable, Hashable {
    /// Multiply the base rate (1.5 = time-and-a-half). The premium is the EXTRA
    /// over base, i.e. rate × (multiplier − 1) per hour.
    case multiplier(Double)
    /// A flat addition per hour on top of base (e.g. +£2.50/hr unsocial allowance).
    case flatPerHour(Double)
}

/// How overlapping premiums combine on the same hour.
public enum PremiumStacking: String, Sendable, Equatable, Codable, Hashable {
    /// The single highest enhancement wins (a weekend night hour gets the better
    /// of weekend/night, not both). The common real-world rule.
    case highest
    /// Enhancements add together.
    case sum
}

/// One user-defined premium rule.
public struct PremiumRule: Sendable, Equatable, Codable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let trigger: PremiumTrigger
    public let adjustment: PremiumAdjustment
    public let enabled: Bool

    public init(id: String = UUID().uuidString, name: String, trigger: PremiumTrigger,
                adjustment: PremiumAdjustment, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.adjustment = adjustment
        self.enabled = enabled
    }
}

extension PayEngine {
    /// The premium uplift (extra pay ABOVE base hours × rate) one shift earns
    /// under `rules`. Whole-shift rules apply across all the shift's paid hours;
    /// time-window rules apply only to the overlapping hours; overlaps resolve by
    /// `rules.premiumStacking`. Breaks reduce the premium in proportion (the
    /// engine doesn't know WHEN the break falls, so it scales by paid/clock).
    public static func premiumPay(for shift: InsightShift, rate: Double, rules: PayRules, calendar: Calendar) -> Double {
        // Note: rate may be 0 (e.g. a job with custom premiums but no base rate).
        // A flat-per-hour allowance is independent of the base rate, so don't gate
        // on rate > 0 — multiplier uplifts already compute to 0 at rate 0.
        guard shift.isPaid else { return 0 }
        let active = rules.premiumRules.filter(\.enabled)
        guard !active.isEmpty else { return 0 }

        let weekday = calendar.component(.weekday, from: shift.day.startOfDay(in: calendar))
        let isHoliday = rules.bankHolidays.contains(shift.day)

        // Per-hour £ uplift a rule adds where it applies.
        func uplift(_ rule: PremiumRule) -> Double {
            switch rule.adjustment {
            case .multiplier(let m): return rate * max(0, m - 1)
            case .flatPerHour(let f): return max(0, f)
            }
        }
        func wholeShiftApplies(_ rule: PremiumRule) -> Bool {
            switch rule.trigger {
            case .weekdays(let days): return days.contains(weekday)
            case .bankHoliday: return isHoliday
            case .shiftTag(let tag): return shift.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
            case .timeWindow: return false
            }
        }
        let wholeShiftUplifts = active.filter(wholeShiftApplies).map(uplift)
        let windowRules: [(start: Int, end: Int, uplift: Double)] = active.compactMap { rule in
            if case .timeWindow(let s, let e) = rule.trigger { return (s, e, uplift(rule)) }
            return nil
        }

        // No committed clock times → only whole-shift rules, over paid hours.
        guard let start = shift.start, let end = shift.end, end > start else {
            let hours = shift.paidHours ?? 0
            return hours > 0 ? combine(wholeShiftUplifts, rules.premiumStacking) * hours : 0
        }

        let clockHours = end.timeIntervalSince(start) / 3600
        guard clockHours > 0 else { return 0 }

        // Walk the shift minute-by-minute (cheap, ≤1440/shift) so time windows,
        // midnight crossings and overlaps all resolve naturally. A single GMT
        // offset (taken at the start) is used — intra-shift DST jumps are a
        // negligible, rare edge for a pay estimate.
        let offset = Double(calendar.timeZone.secondsFromGMT(for: start))
        let totalMinutes = Int((clockHours * 60).rounded())
        var clockPremium = 0.0
        for minute in 0..<totalMinutes {
            let instant = start.addingTimeInterval(Double(minute) * 60 + 30) // mid-minute
            let minuteOfDay = ((Int((instant.timeIntervalSince1970 + offset) / 60) % 1440) + 1440) % 1440
            var uplifts = wholeShiftUplifts
            for w in windowRules where Self.inDailyWindow(minuteOfDay, start: w.start, end: w.end) {
                uplifts.append(w.uplift)
            }
            clockPremium += combine(uplifts, rules.premiumStacking) / 60.0
        }

        // Scale clock-hours premium down to paid hours (breaks are unpaid).
        let paidHours = shift.paidHours ?? clockHours
        let scale = clockHours > 0 ? min(1, max(0, paidHours / clockHours)) : 1
        return clockPremium * scale
    }

    static func combine(_ uplifts: [Double], _ stacking: PremiumStacking) -> Double {
        guard !uplifts.isEmpty else { return 0 }
        switch stacking {
        case .highest: return uplifts.max() ?? 0
        case .sum: return uplifts.reduce(0, +)
        }
    }

    /// True if `minute` (0…1439) is inside a daily window that may wrap midnight.
    static func inDailyWindow(_ minute: Int, start: Int, end: Int) -> Bool {
        guard start != end else { return false } // empty window
        return start < end ? (minute >= start && minute < end)
                           : (minute >= start || minute < end)
    }
}
