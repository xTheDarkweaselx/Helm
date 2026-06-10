//
//  CalendarGridTests.swift
//  HelmDomainTests
//
//  The v3 calendar's pure math: grid construction (locale week starts, fixed
//  42 cells, DST), day bucketing (noon/midnight localDate anchors, overnight,
//  all-day exclusive ends), and the Helm-authored-event signature.
//

import Foundation
import Testing
@testable import HelmDomain

private func ukCalendar(tz: String = "Europe/London") -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.locale = Locale(identifier: "en_GB")
    cal.firstWeekday = 2 // Monday (what en_GB resolves to; pinned for determinism)
    cal.timeZone = TimeZone(identifier: tz)!
    return cal
}

@Suite struct MonthGridTests {
    @Test func june2026StartsCleanOnMonday() {
        // 2026-06-01 is a Monday: zero leading fill days.
        let grid = MonthGrid.make(month: MonthKey(year: 2026, month: 6), calendar: ukCalendar())
        #expect(grid.weeks.count == 6)
        #expect(grid.weeks.allSatisfy { $0.count == 7 })
        #expect(grid.weeks[0][0].day == DayKey(year: 2026, month: 6, day: 1))
        #expect(grid.weeks[0][0].isInMonth)
        // 30 in-month cells, 12 trailing fill (into July).
        #expect(grid.allCells.filter(\.isInMonth).count == 30)
        #expect(grid.weeks[5][6].day == DayKey(year: 2026, month: 7, day: 12))
        #expect(!grid.weeks[5][6].isInMonth)
    }

    @Test func august2026HasLeadingFillFromJuly() {
        // 2026-08-01 is a Saturday → 5 leading fill days (Mon 27 Jul – Fri 31 Jul).
        let grid = MonthGrid.make(month: MonthKey(year: 2026, month: 8), calendar: ukCalendar())
        #expect(grid.weeks[0][0].day == DayKey(year: 2026, month: 7, day: 27))
        #expect(!grid.weeks[0][0].isInMonth)
        #expect(grid.weeks[0][5].day == DayKey(year: 2026, month: 8, day: 1))
        #expect(grid.weeks[0][5].isInMonth)
        #expect(grid.allCells.filter(\.isInMonth).count == 31)
    }

    @Test func sundayFirstLocaleShiftsColumns() {
        var us = Calendar(identifier: .gregorian)
        us.locale = Locale(identifier: "en_US")
        us.firstWeekday = 1 // Sunday
        us.timeZone = TimeZone(identifier: "America/New_York")!
        let grid = MonthGrid.make(month: MonthKey(year: 2026, month: 6), calendar: us)
        // June 1 2026 is Monday → with Sunday-first, one leading fill day (Sun 31 May).
        #expect(grid.weeks[0][0].day == DayKey(year: 2026, month: 5, day: 31))
        #expect(grid.weeks[0][1].day == DayKey(year: 2026, month: 6, day: 1))
    }

    @Test func gridSpansDSTTransitionWithoutSkippingDays() {
        // March 2026 contains the UK spring-forward (29 Mar, 23-hour day).
        let grid = MonthGrid.make(month: MonthKey(year: 2026, month: 3), calendar: ukCalendar())
        let days = grid.allCells.map(\.day)
        #expect(Set(days).count == 42) // all distinct — no skip/duplicate at DST
        #expect(days.contains(DayKey(year: 2026, month: 3, day: 29)))
        // Consecutive cells differ by exactly one civil day.
        for i in 1..<days.count {
            #expect(days[i] == days[i - 1].advanced(by: 1, in: ukCalendar()))
        }
    }

    @Test func weekdaySymbolsRotateToFirstWeekday() {
        let symbols = CalendarGridMath.orderedWeekdaySymbols(ukCalendar())
        #expect(symbols.count == 7)
        #expect(symbols.first == "M")
        #expect(symbols.last == "S") // Sunday
    }

    @Test func monthKeyArithmeticCrossesYears() {
        #expect(MonthKey(year: 2026, month: 12).advanced(by: 1) == MonthKey(year: 2027, month: 1))
        #expect(MonthKey(year: 2026, month: 1).advanced(by: -1) == MonthKey(year: 2025, month: 12))
        #expect(MonthKey(year: 2026, month: 6).advanced(by: -18) == MonthKey(year: 2024, month: 12))
    }

    @Test func dayKeyOrderingAndDescription() {
        #expect(DayKey(year: 2026, month: 6, day: 9) < DayKey(year: 2026, month: 6, day: 10))
        #expect(DayKey(year: 2026, month: 12, day: 31) < DayKey(year: 2027, month: 1, day: 1))
        #expect(DayKey(year: 2026, month: 6, day: 9).description == "2026-06-09")
    }
}

@Suite struct DayBucketerTests {
    @Test func importedShiftNoonAnchorBucketsToItsRotaDay() {
        // RosterDateParser anchors localDate at NOON in the shift's zone.
        var cal = ukCalendar()
        let noonJune9 = cal.date(from: DateComponents(year: 2026, month: 6, day: 9, hour: 12))!
        let start = cal.date(from: DateComponents(year: 2026, month: 6, day: 9, hour: 6, minute: 30))!
        let end = cal.date(from: DateComponents(year: 2026, month: 6, day: 9, hour: 13, minute: 30))!
        let (day, endsLater) = DayBucketer.shiftDay(localDate: noonJune9, start: start, end: end, timeZone: cal.timeZone)
        #expect(day == DayKey(year: 2026, month: 6, day: 9))
        #expect(!endsLater)
        cal = ukCalendar() // silence mutation warning paths
    }

    @Test func overnightShiftStaysOnStartDayWithPlusOne() {
        let cal = ukCalendar()
        let localDate = cal.date(from: DateComponents(year: 2026, month: 6, day: 9, hour: 12))!
        let start = cal.date(from: DateComponents(year: 2026, month: 6, day: 9, hour: 22))!
        let end = cal.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 6))!
        let (day, endsLater) = DayBucketer.shiftDay(localDate: localDate, start: start, end: end, timeZone: cal.timeZone)
        #expect(day == DayKey(year: 2026, month: 6, day: 9))
        #expect(endsLater)
    }

    @Test func builderMidnightAnchorBucketsToSameDay() {
        // Builder localDates anchor at local midnight — same civil day either way.
        let cal = ukCalendar()
        let midnight = cal.date(from: DateComponents(year: 2026, month: 6, day: 9))!
        let (day, _) = DayBucketer.shiftDay(localDate: midnight, start: nil, end: nil, timeZone: cal.timeZone)
        #expect(day == DayKey(year: 2026, month: 6, day: 9))
    }

    @Test func multiDayEventOccupiesEachIntersectedDay() {
        let cal = ukCalendar()
        let start = cal.date(from: DateComponents(year: 2026, month: 6, day: 9, hour: 18))!
        let end = cal.date(from: DateComponents(year: 2026, month: 6, day: 11, hour: 10))!
        let keys = DayBucketer.dayKeys(start: start, end: end, in: cal)
        #expect(keys == [
            DayKey(year: 2026, month: 6, day: 9),
            DayKey(year: 2026, month: 6, day: 10),
            DayKey(year: 2026, month: 6, day: 11),
        ])
    }

    @Test func exactMidnightEndIsExclusive() {
        let cal = ukCalendar()
        let start = cal.date(from: DateComponents(year: 2026, month: 6, day: 9))!
        let end = cal.date(from: DateComponents(year: 2026, month: 6, day: 10))! // all-day next-midnight convention
        let keys = DayBucketer.dayKeys(start: start, end: end, in: cal)
        #expect(keys == [DayKey(year: 2026, month: 6, day: 9)])
    }

    @Test func longRunningEventStillAppearsInALaterWindow() {
        // Regression: an event starting months before the window must still
        // contribute its in-window days (the guardrail must not burn out on
        // pre-window days). Jan 10 – Jul 20 viewed in a May–Aug window.
        let cal = ukCalendar()
        let start = cal.date(from: DateComponents(year: 2026, month: 1, day: 10))!
        let end = cal.date(from: DateComponents(year: 2026, month: 7, day: 20, hour: 12))!
        let window = DayKey(year: 2026, month: 5, day: 1)...DayKey(year: 2026, month: 8, day: 1)
        let keys = DayBucketer.dayKeys(start: start, end: end, in: cal, clampedTo: window)
        #expect(keys.first == DayKey(year: 2026, month: 5, day: 1))
        #expect(keys.last == DayKey(year: 2026, month: 7, day: 20))
        #expect(keys.contains(DayKey(year: 2026, month: 6, day: 15)))
        // Full window coverage: 31 (May) + 30 (June) + 20 (July) days.
        #expect(keys.count == 81)
    }

    @Test func midnightEndingShiftIsNotOvernight() {
        let cal = ukCalendar()
        let localDate = cal.date(from: DateComponents(year: 2026, month: 6, day: 9, hour: 12))!
        let start = cal.date(from: DateComponents(year: 2026, month: 6, day: 9, hour: 18))!
        let midnight = cal.date(from: DateComponents(year: 2026, month: 6, day: 10))!
        let (_, atMidnight) = DayBucketer.shiftDay(localDate: localDate, start: start, end: midnight, timeZone: cal.timeZone)
        #expect(!atMidnight) // 18:00–00:00 is a late shift, not overnight

        let pastMidnight = cal.date(from: DateComponents(year: 2026, month: 6, day: 10, minute: 1))!
        let (_, past) = DayBucketer.shiftDay(localDate: localDate, start: start, end: pastMidnight, timeZone: cal.timeZone)
        #expect(past) // 18:00–00:01 genuinely crosses
    }

    @Test func windowClampDropsOutOfRangeDays() {
        let cal = ukCalendar()
        let start = cal.date(from: DateComponents(year: 2026, month: 6, day: 28))!
        let end = cal.date(from: DateComponents(year: 2026, month: 7, day: 3, hour: 12))!
        let window = DayKey(year: 2026, month: 6, day: 1)...DayKey(year: 2026, month: 6, day: 30)
        let keys = DayBucketer.dayKeys(start: start, end: end, in: cal, clampedTo: window)
        #expect(keys == [
            DayKey(year: 2026, month: 6, day: 28),
            DayKey(year: 2026, month: 6, day: 29),
            DayKey(year: 2026, month: 6, day: 30),
        ])
    }

    @Test func sortKeyOrdersAllDayFirstThenStartThenTitle() {
        let t = Date(timeIntervalSince1970: 1_780_986_600)
        let allDay = CalendarItemSort.SortKey(isAllDay: true, start: t, title: "Z")
        let early = CalendarItemSort.SortKey(isAllDay: false, start: t, title: "B")
        let earlySameTime = CalendarItemSort.SortKey(isAllDay: false, start: t, title: "A")
        let later = CalendarItemSort.SortKey(isAllDay: false, start: t.addingTimeInterval(3600), title: "A")
        #expect([later, early, allDay, earlySameTime].sorted() == [allDay, earlySameTime, early, later])
    }
}

@Suite struct HelmEventSignatureTests {
    @Test func recognisesEventKitCopyByURL() {
        #expect(HelmEventSignature.isHelmAuthored(calendarTitle: "Work", urlScheme: "helm", notes: nil))
    }

    @Test func recognisesGoogleBridgedCopyByNotesTagAlone() {
        // The Google account added to iOS/macOS Calendar: no URL field exists —
        // only the description tag identifies the event if the calendar was renamed.
        #expect(HelmEventSignature.isHelmAuthored(
            calendarTitle: "My Renamed Shifts",
            urlScheme: nil,
            notes: "Imported by Helm. Do not edit the tag.\n[helm:2026-06-09|Europe/London|M]"
        ))
    }

    @Test func recognisesDedicatedCalendarByTitle() {
        #expect(HelmEventSignature.isHelmAuthored(calendarTitle: "Helm Shifts", urlScheme: nil, notes: nil))
    }

    @Test func ordinaryEventsPass() {
        #expect(!HelmEventSignature.isHelmAuthored(calendarTitle: "Family", urlScheme: "https", notes: "dentist, helmet shop"))
    }
}
