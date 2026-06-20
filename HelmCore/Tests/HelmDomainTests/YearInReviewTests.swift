//
//  YearInReviewTests.swift
//  HelmDomainTests
//
//  v9 Shift Year in Review aggregate.
//

import Testing
import Foundation
@testable import HelmDomain

struct YearInReviewTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func d(_ y: Int, _ m: Int, _ day: Int) -> DayKey { DayKey(year: y, month: m, day: day) }

    private func shift(_ key: DayKey, startHour: Double, hours: Double, type: String = "Day") -> InsightShift {
        let start = key.startOfDay(in: cal).addingTimeInterval(startHour * 3600)
        let end = start.addingTimeInterval(hours * 3600)
        return InsightShift(day: key, start: start, end: end, paidHours: hours,
                            typeKey: type, typeLabel: type, colorHex: nil, isAllDay: false)
    }

    @Test func totalsAndBusiestMonthAndTopType() {
        let shifts = [
            shift(d(2026, 1, 5), startHour: 8, hours: 8, type: "Day"),
            shift(d(2026, 1, 6), startHour: 8, hours: 8, type: "Day"),
            shift(d(2026, 3, 10), startHour: 22, hours: 10, type: "Night"),
        ]
        let r = YearInReview.compute(shifts: shifts, year: 2026, calendar: cal)
        #expect(r.totalShifts == 3)
        #expect(abs(r.totalHours - 26) < 0.001)
        #expect(r.daysWorked == 3)
        #expect(r.busiestMonth == 1)            // Jan 16h > Mar 10h
        #expect(abs(r.busiestMonthHours - 16) < 0.001)
        #expect(r.topTypeLabel == "Day")        // 2 Day > 1 Night
        #expect(r.topTypeCount == 2)
        #expect(r.earliestStartMinute == 8 * 60)
        #expect(r.nightShifts == 1)             // the 22:00 Night
    }

    @Test func longestStreakOfConsecutiveDays() {
        let shifts = [d(2026, 2, 1), d(2026, 2, 2), d(2026, 2, 3), d(2026, 2, 6)]
            .map { shift($0, startHour: 9, hours: 8) }
        let r = YearInReview.compute(shifts: shifts, year: 2026, calendar: cal)
        #expect(r.longestStreakDays == 3)       // 1–3 consecutive
    }

    @Test func countsWeekendAndOvernightNights() {
        let shifts = [
            shift(d(2026, 6, 13), startHour: 9, hours: 8),   // Saturday
            shift(d(2026, 6, 15), startHour: 19, hours: 12), // Mon, runs to 07:00 next day → night
        ]
        let r = YearInReview.compute(shifts: shifts, year: 2026, calendar: cal)
        #expect(r.weekendShifts == 1)
        #expect(r.nightShifts == 1)             // the overnight 19:00→07:00
    }

    @Test func excludesOtherYearsAndAllDay() {
        let shifts = [
            shift(d(2025, 12, 31), startHour: 9, hours: 8),  // wrong year
            InsightShift(day: d(2026, 5, 1), start: nil, end: nil, paidHours: nil,
                         typeKey: "TBC", typeLabel: "TBC", colorHex: nil, isAllDay: true), // no hours
            shift(d(2026, 5, 2), startHour: 9, hours: 8),
        ]
        let r = YearInReview.compute(shifts: shifts, year: 2026, calendar: cal)
        #expect(r.totalShifts == 1)
        #expect(r.hasData)
    }

    @Test func busiestMonthTieBreaksToEarliestMonth() {
        // Jan and Mar tie at 8h — the earliest month must win deterministically.
        let shifts = [shift(d(2026, 3, 1), startHour: 9, hours: 8),
                      shift(d(2026, 1, 1), startHour: 9, hours: 8)]
        #expect(YearInReview.compute(shifts: shifts, year: 2026, calendar: cal).busiestMonth == 1)
    }

    @Test func emptyYearHasNoData() {
        let r = YearInReview.compute(shifts: [], year: 2026, calendar: cal)
        #expect(!r.hasData)
        #expect(r.totalShifts == 0)
    }
}
