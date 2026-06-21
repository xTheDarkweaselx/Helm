//
//  YearInReview.swift
//  HelmDomain
//
//  v9 Shift Year in Review: a Spotify-Wrapped-style aggregate of a year's shifts,
//  computed PURELY over the same [InsightShift] the dashboard uses (so the figures
//  never disagree with Insights/Pay). The UI just renders these stats as cards.
//

import Foundation

public struct YearInReview: Sendable, Equatable {
    public let year: Int
    public let totalShifts: Int
    public let totalHours: Double
    public let daysWorked: Int
    public let busiestMonth: Int?          // 1…12
    public let busiestMonthHours: Double
    public let topTypeLabel: String?
    public let topTypeCount: Int
    public let longestStreakDays: Int
    public let nightShifts: Int
    public let weekendShifts: Int
    public let earliestStartMinute: Int?   // earliest clock start seen (minutes of day)

    public var hasData: Bool { totalShifts > 0 }

    public static func empty(year: Int) -> YearInReview {
        YearInReview(year: year, totalShifts: 0, totalHours: 0, daysWorked: 0,
                     busiestMonth: nil, busiestMonthHours: 0, topTypeLabel: nil, topTypeCount: 0,
                     longestStreakDays: 0, nightShifts: 0, weekendShifts: 0, earliestStartMinute: nil)
    }
}

extension YearInReview {
    /// Compute the review for `year` from all shifts. Counts WORKED shifts (those
    /// with real hours); all-day/tentative rows contribute nothing.
    public static func compute(shifts: [InsightShift], year: Int, calendar: Calendar) -> YearInReview {
        let worked = shifts.filter { $0.day.year == year && InsightsMath.hours(for: $0) != nil }
        guard !worked.isEmpty else { return .empty(year: year) }

        var totalHours = 0.0
        var monthHours: [Int: Double] = [:]
        var typeCounts: [String: Int] = [:]
        var nightShifts = 0
        var weekendShifts = 0
        var earliest: Int? = nil
        var workedDays = Set<DayKey>()

        for shift in worked {
            let hours = InsightsMath.hours(for: shift) ?? 0
            totalHours += hours
            monthHours[shift.day.month, default: 0] += hours
            if let label = shift.typeLabel, !label.isEmpty { typeCounts[label, default: 0] += 1 }
            workedDays.insert(shift.day)

            let weekday = calendar.component(.weekday, from: shift.day.startOfDay(in: calendar))
            if weekday == 1 || weekday == 7 { weekendShifts += 1 } // Sun / Sat

            if let start = shift.start {
                let comps = calendar.dateComponents([.hour, .minute], from: start)
                let startMinute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
                earliest = min(earliest ?? startMinute, startMinute)
                // A "night" shift: starts in the evening, or runs past midnight.
                // Strict `<` — a zero-length (end == start) shift isn't overnight,
                // matching InsightsMath/PremiumPay's `end > start` convention.
                let overnight = shift.end.map { $0 < start } ?? false
                if startMinute >= 18 * 60 || overnight { nightShifts += 1 }
            }
        }

        // Deterministic tie-break on month (earliest wins), like topType below —
        // dictionary order is unspecified, so a bare value compare flickers on ties.
        let busiest = monthHours.max { ($0.value, $1.key) < ($1.value, $0.key) }
        let topType = typeCounts.max { ($0.value, $1.key) < ($1.value, $0.key) }

        return YearInReview(
            year: year,
            totalShifts: worked.count,
            totalHours: totalHours,
            daysWorked: workedDays.count,
            busiestMonth: busiest?.key,
            busiestMonthHours: busiest?.value ?? 0,
            topTypeLabel: topType?.key,
            topTypeCount: topType?.value ?? 0,
            longestStreakDays: longestStreak(of: workedDays, calendar: calendar),
            nightShifts: nightShifts,
            weekendShifts: weekendShifts,
            earliestStartMinute: earliest
        )
    }

    /// Longest run of consecutive worked days.
    static func longestStreak(of days: Set<DayKey>, calendar: Calendar) -> Int {
        var best = 0
        for day in days {
            // Only count from a run START (the day before isn't worked).
            if days.contains(day.advanced(by: -1, in: calendar)) { continue }
            var run = 1
            var cursor = day
            while days.contains(cursor.advanced(by: 1, in: calendar)) {
                cursor = cursor.advanced(by: 1, in: calendar)
                run += 1
            }
            best = max(best, run)
        }
        return best
    }
}
