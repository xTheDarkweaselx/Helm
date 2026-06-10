//
//  InsightsMath.swift
//  HelmDomain
//
//  v6 Insights: ONE hours engine for the dashboard AND the Siri intents (two
//  engines with different week semantics would contradict each other out
//  loud). Membership = the shift's civil DAY (same DayBucketer rule as the
//  calendar: overnight counts on its start day); hours = paidHours when the
//  source computed them, else duration; all-day tentative shifts contribute
//  NO hours but are counted, surfaced honestly as "awaiting times".
//

import Foundation

/// Value snapshot of a shift for insight computation (no SwiftData here).
public struct InsightShift: Sendable, Equatable {
    public let day: DayKey
    public let start: Date?
    public let end: Date?
    public let paidHours: Double?
    public let typeKey: String?     // ShiftType id or code — mix grouping
    public let typeLabel: String?
    public let colorHex: String?
    public let isAllDay: Bool

    public init(day: DayKey, start: Date?, end: Date?, paidHours: Double?, typeKey: String?, typeLabel: String?, colorHex: String?, isAllDay: Bool) {
        self.day = day
        self.start = start
        self.end = end
        self.paidHours = paidHours
        self.typeKey = typeKey
        self.typeLabel = typeLabel
        self.colorHex = colorHex
        self.isAllDay = isAllDay
    }
}

public enum InsightsMath {
    /// paid ?? duration; all-day (no committed times) → nil, never 24.
    public static func hours(for shift: InsightShift) -> Double? {
        if shift.isAllDay { return nil }
        if let paid = shift.paidHours { return paid }
        if let start = shift.start, let end = shift.end, end > start {
            return end.timeIntervalSince(start) / 3600
        }
        return nil
    }

    /// The locale week containing `day` (column 0 = calendar.firstWeekday).
    public static func weekStart(of day: DayKey, calendar: Calendar) -> DayKey {
        let weekday = calendar.component(.weekday, from: day.startOfDay(in: calendar))
        let delta = (weekday - calendar.firstWeekday + 7) % 7
        return day.advanced(by: -delta, in: calendar)
    }

    public struct WeekBucket: Sendable, Equatable {
        public let weekStart: DayKey
        public let hours: Double
        public let shiftCount: Int
        public let tentativeCount: Int
    }

    /// The last `weeks` locale-weeks ending at the week containing `today`,
    /// ZERO-FILLED (an empty week is a real data point, not a gap).
    public static func weeklyHours(shifts: [InsightShift], weeks: Int, endingAt today: DayKey, calendar: Calendar) -> [WeekBucket] {
        guard weeks > 0 else { return [] }
        let currentWeek = weekStart(of: today, calendar: calendar)
        var starts: [DayKey] = []
        for back in stride(from: weeks - 1, through: 0, by: -1) {
            starts.append(currentWeek.advanced(by: -7 * back, in: calendar))
        }
        var hoursByWeek: [DayKey: (hours: Double, count: Int, tentative: Int)] = [:]
        for shift in shifts {
            let week = weekStart(of: shift.day, calendar: calendar)
            var bucket = hoursByWeek[week] ?? (0, 0, 0)
            if let h = hours(for: shift) {
                bucket.hours += h
                bucket.count += 1
            } else if shift.isAllDay {
                bucket.count += 1
                bucket.tentative += 1
            }
            hoursByWeek[week] = bucket
        }
        return starts.map { start in
            let bucket = hoursByWeek[start] ?? (0, 0, 0)
            return WeekBucket(weekStart: start, hours: bucket.hours, shiftCount: bucket.count, tentativeCount: bucket.tentative)
        }
    }

    public struct TypeSlice: Sendable, Equatable {
        public let key: String
        public let label: String
        public let colorHex: String?
        public let hours: Double
        public let count: Int
    }

    /// Hours by shift type within a day range, largest first.
    public static func typeMix(shifts: [InsightShift], in range: ClosedRange<DayKey>) -> [TypeSlice] {
        var byKey: [String: (label: String, color: String?, hours: Double, count: Int)] = [:]
        for shift in shifts where range.contains(shift.day) {
            guard let h = hours(for: shift) else { continue }
            let key = shift.typeKey ?? "untyped"
            var slice = byKey[key] ?? (shift.typeLabel ?? key, shift.colorHex, 0, 0)
            slice.hours += h
            slice.count += 1
            byKey[key] = slice
        }
        return byKey.map { TypeSlice(key: $0.key, label: $0.value.label, colorHex: $0.value.color, hours: $0.value.hours, count: $0.value.count) }
            .sorted { $0.hours != $1.hours ? $0.hours > $1.hours : $0.key < $1.key }
    }

    /// One period's totals — the dashboard cards AND the Siri answer.
    public struct PeriodSummary: Sendable, Equatable {
        public let hours: Double
        public let shiftCount: Int
        public let tentativeCount: Int
    }

    public static func periodSummary(shifts: [InsightShift], in range: ClosedRange<DayKey>) -> PeriodSummary {
        var hoursTotal = 0.0
        var count = 0
        var tentative = 0
        for shift in shifts where range.contains(shift.day) {
            if let h = hours(for: shift) {
                hoursTotal += h
                count += 1
            } else if shift.isAllDay {
                count += 1
                tentative += 1
            }
        }
        return PeriodSummary(hours: hoursTotal, shiftCount: count, tentativeCount: tentative)
    }

    /// Day range of a month (1st … last day).
    public static func monthRange(_ month: MonthKey, calendar: Calendar) -> ClosedRange<DayKey> {
        let first = DayKey(year: month.year, month: month.month, day: 1)
        let nextFirst = month.advanced(by: 1)
        let last = DayKey(year: nextFirst.year, month: nextFirst.month, day: 1).advanced(by: -1, in: calendar)
        return first...last
    }

    /// This month's hours vs the previous month's (Dec→Jan-safe).
    public static func monthComparison(shifts: [InsightShift], month: MonthKey, calendar: Calendar) -> (current: Double, previous: Double) {
        let current = periodSummary(shifts: shifts, in: monthRange(month, calendar: calendar)).hours
        let previous = periodSummary(shifts: shifts, in: monthRange(month.advanced(by: -1), calendar: calendar)).hours
        return (current, previous)
    }

    /// Consecutive worked days ending at (and including) `today`, 0 if today
    /// is off. All-day tentative days count as worked (the user owns the day).
    public static func currentStreak(endingAt today: DayKey, workedDays: Set<DayKey>, calendar: Calendar) -> Int {
        var streak = 0
        var day = today
        while workedDays.contains(day) {
            streak += 1
            day = day.advanced(by: -1, in: calendar)
        }
        return streak
    }
}
