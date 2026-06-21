//
//  CalendarGrid.swift
//  HelmDomain
//
//  Pure month-grid math for the v3 calendar view: civil-day keys, month keys,
//  and a fixed 42-cell (6×7) grid whose first column follows the calendar's
//  locale-driven firstWeekday (en_GB → Monday). No SwiftUI, no EventKit —
//  headlessly tested.
//

import Foundation

/// A civil day (year-month-day), independent of any time zone — the unit the
/// calendar grid is keyed by. Which DayKey a Date belongs to depends on the
/// calendar (and its time zone) used to extract it.
public struct DayKey: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The civil day containing `instant`, as seen by `calendar` (which carries
    /// the relevant time zone).
    public init(containing instant: Date, in calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: instant)
        self.init(year: c.year ?? 1, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// Midnight starting this civil day in `calendar`'s zone.
    public func startOfDay(in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    /// DST-safe day stepping (goes through noon so 23/25-hour days can't skip).
    public func advanced(by days: Int, in calendar: Calendar) -> DayKey {
        let noon = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .distantPast
        guard let stepped = calendar.date(byAdding: .day, value: days, to: noon) else { return self }
        return DayKey(containing: stepped, in: calendar)
    }

    public static func < (l: DayKey, r: DayKey) -> Bool {
        (l.year, l.month, l.day) < (r.year, r.month, r.day)
    }

    /// "2026-06-10" — the same civil-day format ShiftKey uses.
    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }
}

/// A year-month — the calendar's page unit.
public struct MonthKey: Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int

    public init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    public init(containing instant: Date, in calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month], from: instant)
        self.init(year: c.year ?? 1, month: c.month ?? 1)
    }

    public init(of day: DayKey) {
        self.init(year: day.year, month: day.month)
    }

    public func advanced(by months: Int) -> MonthKey {
        // Pure arithmetic — month arithmetic needs no calendar.
        let zeroBased = (year * 12 + (month - 1)) + months
        return MonthKey(year: zeroBased / 12, month: zeroBased % 12 + 1)
    }

    /// First instant of the month in `calendar`'s zone.
    public func start(in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? .distantPast
    }

    public static func < (l: MonthKey, r: MonthKey) -> Bool {
        (l.year, l.month) < (r.year, r.month)
    }
}

/// The fixed 6×7 grid for one month page.
public struct MonthGrid: Sendable, Equatable {
    public struct Cell: Sendable, Equatable, Identifiable {
        public let day: DayKey
        /// False for the muted leading/trailing fill days (still live/tappable).
        public let isInMonth: Bool
        public var id: DayKey { day }
    }

    public let month: MonthKey
    /// Exactly 6 rows of exactly 7 — fixed height so month paging never jumps.
    public let weeks: [[Cell]]

    public var allCells: [Cell] { weeks.flatMap(\.self) }

    public static func make(month: MonthKey, calendar: Calendar) -> MonthGrid {
        let firstOfMonth = month.start(in: calendar)
        // Leading fill: how many columns before day 1, with column 0 = firstWeekday.
        let weekdayOfFirst = calendar.component(.weekday, from: firstOfMonth) // 1=Sun...7=Sat
        let leading = (weekdayOfFirst - calendar.firstWeekday + 7) % 7
        let firstCellDay = DayKey(containing: firstOfMonth, in: calendar).advanced(by: -leading, in: calendar)

        var cells: [Cell] = []
        cells.reserveCapacity(42)
        var day = firstCellDay
        for _ in 0..<42 {
            cells.append(Cell(day: day, isInMonth: day.year == month.year && day.month == month.month))
            day = day.advanced(by: 1, in: calendar)
        }
        return MonthGrid(month: month, weeks: stride(from: 0, to: 42, by: 7).map { Array(cells[$0..<$0 + 7]) })
    }
}

public enum CalendarGridMath {
    /// Weekday header symbols rotated so index 0 is the calendar's firstWeekday
    /// (locale-correct labels AND order: en_GB → ["M","T","W","T","F","S","S"]).
    public static func orderedWeekdaySymbols(_ calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols // Sun-first
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }
}
