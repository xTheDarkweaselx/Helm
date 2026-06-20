//
//  PayCycle.swift
//  HelmDomain
//
//  v9 Payday Forecast. A pure description of WHEN a job pays: a recurring period
//  (weekly / fortnightly / 4-weekly / calendar month) plus the day the money
//  lands. From it the app projects upcoming paydays and the pay each covers, using
//  the same PayEngine over future shifts. No SwiftData/SwiftUI; unit-tested.
//

import Foundation

public enum PayFrequency: String, Sendable, Codable, CaseIterable, Hashable {
    case weekly, fortnightly, fourWeekly, monthly

    public var label: String {
        switch self {
        case .weekly: "Weekly"
        case .fortnightly: "Fortnightly"
        case .fourWeekly: "Every 4 weeks"
        case .monthly: "Monthly"
        }
    }

    /// Fixed period length in days, or nil for a calendar month (variable length).
    public var fixedDays: Int? {
        switch self {
        case .weekly: 7
        case .fortnightly: 14
        case .fourWeekly: 28
        case .monthly: nil
        }
    }
}

/// How a job's pay is timed.
public struct PayCycle: Sendable, Equatable, Hashable, Codable {
    public let frequency: PayFrequency
    /// Phases the cycle. For FIXED cycles it's the first day of a known period; for
    /// MONTHLY only its day-of-month matters (that's the payday day each month).
    public let anchor: DayKey
    /// Days after a period's LAST day that the money lands (paid in arrears). Fixed
    /// cycles only — monthly pays on the anchor's day-of-month.
    public let lagDays: Int

    public init(frequency: PayFrequency, anchor: DayKey, lagDays: Int = 0) {
        self.frequency = frequency
        self.anchor = anchor
        self.lagDays = max(0, lagDays)
    }
}

extension PayCycle {
    private func dayDelta(from a: DayKey, to b: DayKey, _ cal: Calendar) -> Int {
        cal.dateComponents([.day], from: a.startOfDay(in: cal), to: b.startOfDay(in: cal)).day ?? 0
    }

    private func daysInMonth(_ day: DayKey, _ cal: Calendar) -> Int {
        cal.range(of: .day, in: .month, for: MonthKey(of: day).start(in: cal))?.count ?? 30
    }

    /// The inclusive day range of the pay period containing `day`.
    public func period(containing day: DayKey, calendar cal: Calendar) -> ClosedRange<DayKey> {
        guard let len = frequency.fixedDays else {
            return InsightsMath.monthRange(MonthKey(of: day), calendar: cal)
        }
        // Floor the offset from the anchor to a whole number of cycles (works for
        // days before the anchor too — Swift's Int division truncates toward zero,
        // so use floor explicitly).
        let delta = dayDelta(from: anchor, to: day, cal)
        let k = Int((Double(delta) / Double(len)).rounded(.down))
        let start = anchor.advanced(by: k * len, in: cal)
        return start...start.advanced(by: len - 1, in: cal)
    }

    /// The payday for the period that `day` falls in.
    public func payday(forPeriodContaining day: DayKey, calendar cal: Calendar) -> DayKey {
        let p = period(containing: day, calendar: cal)
        switch frequency {
        case .monthly:
            let dom = min(max(1, anchor.day), daysInMonth(p.lowerBound, cal))
            return DayKey(year: p.lowerBound.year, month: p.lowerBound.month, day: dom)
        default:
            return p.upperBound.advanced(by: lagDays, in: cal)
        }
    }

    /// The pay period a given payday pays for.
    public func period(forPayday payday: DayKey, calendar cal: Calendar) -> ClosedRange<DayKey> {
        switch frequency {
        case .monthly:
            return InsightsMath.monthRange(MonthKey(of: payday), calendar: cal)
        default:
            return period(containing: payday.advanced(by: -lagDays, in: cal), calendar: cal)
        }
    }

    /// The first payday strictly after `day` (bounded scan forward).
    public func nextPayday(after day: DayKey, calendar cal: Calendar) -> DayKey {
        guard frequency.fixedDays != nil else {
            // Monthly: payday is a day-of-month within each month — step by month.
            var probe = day
            for _ in 0..<400 {
                let pd = payday(forPeriodContaining: probe, calendar: cal)
                if pd > day { return pd }
                probe = period(containing: probe, calendar: cal).upperBound.advanced(by: 1, in: cal)
            }
            return payday(forPeriodContaining: day, calendar: cal)
        }
        // Fixed cycle: payday = period end + lag. Iterate over PERIODS (not paydays)
        // so the stride stays one period even when lag ≥ the period length (a payday
        // can belong to a period up to `lagDays` earlier — start the scan there).
        var p = period(containing: day.advanced(by: -lagDays, in: cal), calendar: cal)
        for _ in 0..<800 {
            let pd = p.upperBound.advanced(by: lagDays, in: cal)
            if pd > day { return pd }
            p = period(containing: p.upperBound.advanced(by: 1, in: cal), calendar: cal)
        }
        return p.upperBound.advanced(by: lagDays, in: cal)
    }

    /// Up to `count` upcoming paydays on/after `day`, each with the period it pays.
    public func upcomingPaydays(from day: DayKey, count: Int, calendar cal: Calendar) -> [(payday: DayKey, period: ClosedRange<DayKey>)] {
        var result: [(DayKey, ClosedRange<DayKey>)] = []
        var cursor = day.advanced(by: -1, in: cal) // so a payday landing exactly on `day` is included
        for _ in 0..<max(0, count) {
            let pd = nextPayday(after: cursor, calendar: cal)
            result.append((pd, period(forPayday: pd, calendar: cal)))
            cursor = pd
        }
        return result
    }
}
