//
//  ShiftTime.swift
//  HelmDomain
//
//  Wall-clock → absolute-time resolution for shifts, the #1 correctness trap
//  (DEVELOPMENT_PLAN.md §10 risk 5). Shifts are defined in local wall-clock time
//  in a specific IANA time zone; we derive absolute Dates so that:
//    • overnight shifts (end ≤ start) roll into the next day,
//    • duration is the true elapsed time, so it is correct across DST
//      (a fall-back night is 9h, a spring-forward night is 7h).
//

import Foundation

/// Absolute start/end of a shift, with the true elapsed duration.
public struct ResolvedShiftTimes: Sendable, Equatable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    /// True elapsed hours (DST-aware: derived from the absolute UTC delta).
    public var durationHours: Double {
        end.timeIntervalSince(start) / 3600
    }

    /// Paid hours = elapsed time minus unpaid break minutes (never below zero).
    public func paidHours(breakMinutes: Int) -> Double {
        max(0, durationHours - Double(breakMinutes) / 60)
    }
}

public enum ShiftTimeResolver {

    /// Resolve a shift's wall-clock minutes-of-day to absolute Dates.
    ///
    /// - Parameters:
    ///   - localDay: any instant on the shift's calendar day (only y/m/d in `timeZone` is used).
    ///   - startMinuteOfDay: minutes after local midnight the shift starts (e.g. 06:30 → 390).
    ///   - endMinuteOfDay: minutes after local midnight the shift ends (may exceed 1440).
    ///   - endDayOffset: whole days the end rolls forward (alternative to >1440 minutes).
    ///   - timeZone: the IANA zone the wall-clock times are expressed in.
    /// - Returns: resolved times, or nil if the calendar math fails.
    ///
    /// Both start and end are computed as **wall-clock** times (DST-correct via
    /// `Calendar`), so the elapsed duration automatically reflects any transition
    /// crossed between them. If the end is not strictly after the start and no
    /// explicit overflow/offset was supplied, the shift is treated as overnight.
    public static func resolve(
        localDay: Date,
        startMinuteOfDay: Int,
        endMinuteOfDay: Int,
        endDayOffset: Int = 0,
        timeZone: TimeZone
    ) -> ResolvedShiftTimes? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let ymd = calendar.dateComponents([.year, .month, .day], from: localDay)
        guard
            let year = ymd.year, let month = ymd.month, let day = ymd.day,
            let baseDay = calendar.date(from: DateComponents(year: year, month: month, day: day))
        else { return nil }

        guard let start = wallClock(minuteOfDay: startMinuteOfDay, onDayOffset: 0, from: baseDay, calendar: calendar) else {
            return nil
        }

        // Total end minutes from local midnight of the base day.
        var totalEndMinutes = endMinuteOfDay + endDayOffset * 1440
        if totalEndMinutes <= startMinuteOfDay {
            totalEndMinutes += 1440 // overnight: roll to next day
        }
        let endDayAdd = totalEndMinutes / 1440
        let endMinuteOfDayNormalized = totalEndMinutes % 1440

        guard let end = wallClock(minuteOfDay: endMinuteOfDayNormalized, onDayOffset: endDayAdd, from: baseDay, calendar: calendar) else {
            return nil
        }
        return ResolvedShiftTimes(start: start, end: end)
    }

    /// Build a Date at a wall-clock minute-of-day on `baseDay + dayOffset`,
    /// letting `Calendar` resolve DST gaps/overlaps.
    private static func wallClock(minuteOfDay: Int, onDayOffset dayOffset: Int, from baseDay: Date, calendar: Calendar) -> Date? {
        guard let day = calendar.date(byAdding: .day, value: dayOffset, to: baseDay) else { return nil }
        let ymd = calendar.dateComponents([.year, .month, .day], from: day)
        var comps = DateComponents()
        comps.year = ymd.year
        comps.month = ymd.month
        comps.day = ymd.day
        comps.hour = minuteOfDay / 60
        comps.minute = minuteOfDay % 60
        return calendar.date(from: comps)
    }
}
