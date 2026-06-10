//
//  LeaveAccumulator.swift
//  HelmDomain
//
//  v7 planning: pure time-off / leave math. Operates on value snapshots of
//  leave entries (a date range + kind + paid flag + optional hours/day) — no
//  SwiftData — so the calendar bands, the Overview leave-balance card and any
//  future Siri answer all count leave the same way. Day counting is DST-safe
//  (DayKey.advanced steps through noon) and ranges are INCLUSIVE on both ends.
//

import Foundation

/// What a stretch of time-off represents (kept distinct from WorkKind, which is
/// about a *shift*; leave is about *days away*).
public enum LeaveKind: String, Sendable, CaseIterable, Codable {
    case annual      // booked holiday / vacation
    case sick
    case unpaid
    case publicHoliday
    case other

    public var displayName: String {
        switch self {
        case .annual: "Annual leave"
        case .sick: "Sick"
        case .unpaid: "Unpaid"
        case .publicHoliday: "Public holiday"
        case .other: "Other"
        }
    }
}

/// A value snapshot of one booked stretch of leave.
public struct LeaveEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let start: DayKey
    public let end: DayKey          // inclusive
    public let kind: LeaveKind
    public let paid: Bool
    /// Optional credited hours per leave day (e.g. 7.5). nil → counted in days only.
    public let hoursPerDay: Double?

    public init(id: String, start: DayKey, end: DayKey, kind: LeaveKind, paid: Bool, hoursPerDay: Double? = nil) {
        self.id = id
        // Tolerate an inverted range defensively.
        if end < start { self.start = end; self.end = start } else { self.start = start; self.end = end }
        self.kind = kind
        self.paid = paid
        self.hoursPerDay = hoursPerDay
    }
}

public enum LeaveAccumulator {
    /// Entries that cover a given civil day (inclusive range membership).
    public static func entriesCovering(_ day: DayKey, in entries: [LeaveEntry]) -> [LeaveEntry] {
        entries.filter { $0.start <= day && day <= $0.end }
    }

    /// Inclusive day count of an entry, optionally clamped to a range. DST-safe.
    public static func days(in entry: LeaveEntry, clampedTo range: ClosedRange<DayKey>? = nil, calendar: Calendar) -> Int {
        var lower = entry.start
        var upper = entry.end
        if let range {
            lower = max(lower, range.lowerBound)
            upper = min(upper, range.upperBound)
        }
        guard lower <= upper else { return 0 }
        var count = 0
        var day = lower
        // Hard guardrail against a pathological range (mirrors DayBucketer's walk cap).
        while day <= upper && count < 4000 {
            count += 1
            day = day.advanced(by: 1, in: calendar)
        }
        return count
    }

    public struct KindCount: Sendable, Equatable {
        public let kind: LeaveKind
        public let days: Int
    }

    /// Aggregated leave over a day range — the Overview balance card and any
    /// period query. `hours` sums hoursPerDay × clamped-days where hours are set.
    public struct LeaveSummary: Sendable, Equatable {
        public let totalDays: Int
        public let paidDays: Int
        public let unpaidDays: Int
        public let hours: Double
        public let byKind: [KindCount]

        public static let empty = LeaveSummary(totalDays: 0, paidDays: 0, unpaidDays: 0, hours: 0, byKind: [])
    }

    public static func summary(_ entries: [LeaveEntry], in range: ClosedRange<DayKey>, calendar: Calendar) -> LeaveSummary {
        var total = 0, paid = 0, unpaid = 0
        var hours = 0.0
        var byKind: [LeaveKind: Int] = [:]
        for entry in entries {
            let d = days(in: entry, clampedTo: range, calendar: calendar)
            guard d > 0 else { continue }
            total += d
            if entry.paid { paid += d } else { unpaid += d }
            if let h = entry.hoursPerDay { hours += h * Double(d) }
            byKind[entry.kind, default: 0] += d
        }
        let kinds = byKind
            .map { KindCount(kind: $0.key, days: $0.value) }
            .sorted { $0.days != $1.days ? $0.days > $1.days : $0.kind.rawValue < $1.kind.rawValue }
        return LeaveSummary(totalDays: total, paidDays: paid, unpaidDays: unpaid, hours: hours, byKind: kinds)
    }
}
