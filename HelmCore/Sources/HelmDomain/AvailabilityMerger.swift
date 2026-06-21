//
//  AvailabilityMerger.swift
//  HelmDomain
//
//  v7 planning: pure availability math. Two sources — recurring WEEKLY rules
//  ("can't work Monday mornings") and one-off WINDOWS for specific dates — are
//  expanded into per-day bands and used to flag shifts that fall in an
//  UNAVAILABLE band. No SwiftData; weekday is read via the passed Calendar so
//  locale/timezone stay consistent with the rest of Helm.
//

import Foundation

public enum AvailabilityKind: String, Sendable, CaseIterable, Codable {
    case available
    case unavailable

    public var displayName: String {
        switch self {
        case .available: "Available"
        case .unavailable: "Unavailable"
        }
    }
}

/// A recurring weekly availability rule (minute-of-day band on chosen weekdays,
/// optionally bounded by an effective date range).
public struct AvailabilityRuleSpec: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: AvailabilityKind
    /// Foundation weekdays: 1 = Sunday … 7 = Saturday.
    public let weekdays: Set<Int>
    public let startMinute: Int
    public let endMinute: Int
    public let effectiveFrom: DayKey?
    public let effectiveTo: DayKey?

    public init(id: String, kind: AvailabilityKind, weekdays: Set<Int>, startMinute: Int, endMinute: Int, effectiveFrom: DayKey? = nil, effectiveTo: DayKey? = nil) {
        self.id = id
        self.kind = kind
        self.weekdays = weekdays
        // Stored AS AUTHORED — end ≤ start means OVERNIGHT (e.g. 22:00→06:00),
        // expanded across midnight in `bands(on:)`. (A min/max swap here silently
        // inverted "can't work nights" into a daytime band.)
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.effectiveFrom = effectiveFrom
        self.effectiveTo = effectiveTo
    }

    /// end ≤ start (and not a zero-length band) → the band wraps past midnight.
    var isOvernight: Bool { endMinute <= startMinute }

    func applies(on day: DayKey, calendar: Calendar) -> Bool {
        if let from = effectiveFrom, day < from { return false }
        if let to = effectiveTo, day > to { return false }
        let weekday = calendar.component(.weekday, from: day.startOfDay(in: calendar))
        return weekdays.contains(weekday)
    }
}

/// A one-off availability window pinned to a single date (all-day or a band).
public struct AvailabilityWindowSpec: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: AvailabilityKind
    public let day: DayKey
    public let startMinute: Int
    public let endMinute: Int
    public let allDay: Bool

    public init(id: String, kind: AvailabilityKind, day: DayKey, startMinute: Int = 0, endMinute: Int = 1440, allDay: Bool = false) {
        self.id = id
        self.kind = kind
        self.day = day
        // As authored (overnight = end ≤ start), except all-day = full day.
        self.startMinute = allDay ? 0 : startMinute
        self.endMinute = allDay ? 1440 : endMinute
        self.allDay = allDay
    }

    var isOvernight: Bool { !allDay && endMinute <= startMinute }
}

/// A resolved band to render on a day's timeline.
public struct AvailabilityBand: Sendable, Equatable {
    public let startMinute: Int
    public let endMinute: Int
    public let kind: AvailabilityKind
    public let isOneOff: Bool

    public init(startMinute: Int, endMinute: Int, kind: AvailabilityKind, isOneOff: Bool) {
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.kind = kind
        self.isOneOff = isOneOff
    }
}

/// A shift snapshot for conflict checking (minute-of-day band; endMinute may
/// exceed 1440 for an overnight shift).
public struct AvailabilityShift: Sendable, Equatable, Identifiable {
    public let id: String
    public let day: DayKey
    public let startMinute: Int
    public let endMinute: Int
    public let isAllDay: Bool

    public init(id: String, day: DayKey, startMinute: Int, endMinute: Int, isAllDay: Bool) {
        self.id = id
        self.day = day
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.isAllDay = isAllDay
    }
}

public enum AvailabilityMerger {
    /// All bands that fall on `day` (recurring rules expanded + one-off windows),
    /// sorted by start. Overnight bands (end ≤ start) are split across midnight:
    /// the [start,1440) part lands on the band's own day and the [0,end) part on
    /// the NEXT day. One-off windows are marked so the UI can distinguish them.
    public static func bands(on day: DayKey, rules: [AvailabilityRuleSpec], windows: [AvailabilityWindowSpec], calendar: Calendar) -> [AvailabilityBand] {
        var out: [AvailabilityBand] = []
        let prevDay = day.advanced(by: -1, in: calendar)

        for rule in rules {
            if rule.applies(on: day, calendar: calendar) {
                if rule.isOvernight {
                    out.append(AvailabilityBand(startMinute: rule.startMinute, endMinute: 1440, kind: rule.kind, isOneOff: false))
                } else if rule.endMinute > rule.startMinute {
                    out.append(AvailabilityBand(startMinute: rule.startMinute, endMinute: rule.endMinute, kind: rule.kind, isOneOff: false))
                }
            }
            // The morning tail of a rule that began the previous day.
            if rule.isOvernight, rule.endMinute > 0, rule.applies(on: prevDay, calendar: calendar) {
                out.append(AvailabilityBand(startMinute: 0, endMinute: rule.endMinute, kind: rule.kind, isOneOff: false))
            }
        }

        for window in windows {
            if window.day == day {
                if window.isOvernight {
                    out.append(AvailabilityBand(startMinute: window.startMinute, endMinute: 1440, kind: window.kind, isOneOff: true))
                } else {
                    out.append(AvailabilityBand(startMinute: window.startMinute, endMinute: window.endMinute, kind: window.kind, isOneOff: true))
                }
            }
            if window.isOvernight, window.endMinute > 0, window.day == prevDay {
                out.append(AvailabilityBand(startMinute: 0, endMinute: window.endMinute, kind: window.kind, isOneOff: true))
            }
        }
        return out.sorted { $0.startMinute != $1.startMinute ? $0.startMinute < $1.startMinute : $0.endMinute < $1.endMinute }
    }

    /// Ids of shifts that overlap an UNAVAILABLE band. Half-open overlap so
    /// back-to-back is fine. An overnight shift's post-midnight tail is checked
    /// against the NEXT day's bands too. All-day shifts are skipped (no times).
    public static func conflictingShiftIDs(
        shifts: [AvailabilityShift],
        rules: [AvailabilityRuleSpec],
        windows: [AvailabilityWindowSpec],
        calendar: Calendar
    ) -> Set<String> {
        var bandCache: [DayKey: [AvailabilityBand]] = [:]
        func unavailable(on day: DayKey) -> [AvailabilityBand] {
            if let cached = bandCache[day] { return cached }
            let b = bands(on: day, rules: rules, windows: windows, calendar: calendar).filter { $0.kind == .unavailable }
            bandCache[day] = b
            return b
        }
        var conflicts = Set<String>()
        for shift in shifts where !shift.isAllDay && shift.endMinute > shift.startMinute {
            // Same-day portion.
            let sameDayEnd = min(shift.endMinute, 1440)
            if overlapsAny(start: shift.startMinute, end: sameDayEnd, bands: unavailable(on: shift.day)) {
                conflicts.insert(shift.id); continue
            }
            // Overnight tail into the next day.
            if shift.endMinute > 1440 {
                let nextDay = shift.day.advanced(by: 1, in: calendar)
                if overlapsAny(start: 0, end: shift.endMinute - 1440, bands: unavailable(on: nextDay)) {
                    conflicts.insert(shift.id)
                }
            }
        }
        return conflicts
    }

    private static func overlapsAny(start: Int, end: Int, bands: [AvailabilityBand]) -> Bool {
        bands.contains { start < $0.endMinute && $0.startMinute < end }
    }
}
