//
//  PayEngineTests.swift
//  HelmDomainTests
//
//  v8 Pay engine: flat pay, per-week overtime, tax-year boundaries, line items.
//

import Testing
import Foundation
@testable import HelmDomain

struct PayEngineTests {
    /// Monday-first gregorian calendar so week math is deterministic.
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2 // Monday
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }

    private func paid(_ y: Int, _ m: Int, _ d: Int, _ hours: Double, label: String = "Day") -> InsightShift {
        InsightShift(day: DayKey(year: y, month: m, day: d), start: nil, end: nil,
                     paidHours: hours, typeKey: label, typeLabel: label, colorHex: nil, isAllDay: false)
    }
    private func allDay(_ y: Int, _ m: Int, _ d: Int, label: String = "TBC") -> InsightShift {
        InsightShift(day: DayKey(year: y, month: m, day: d), start: nil, end: nil,
                     paidHours: nil, typeKey: label, typeLabel: label, colorHex: nil, isAllDay: true)
    }
    private func range(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> ClosedRange<DayKey> {
        DayKey(year: a.0, month: a.1, day: a.2)...DayKey(year: b.0, month: b.1, day: b.2)
    }

    @Test func flatPayNoOvertime() {
        let shifts = [paid(2026, 6, 1, 8), paid(2026, 6, 2, 8), paid(2026, 6, 3, 8)]
        let rules = PayRules(hourlyRate: 10)
        let s = PayEngine.summary(shifts: shifts, in: range((2026, 6, 1), (2026, 6, 7)), rules: rules, calendar: cal)
        #expect(s.totalHours == 24)
        #expect(s.baseHours == 24 && s.overtimeHours == 0)
        #expect(s.grossPay == 240)
        #expect(s.shiftCount == 3)
    }

    @Test func weeklyOvertimeSplit() {
        // Jun 1 2026 is a Monday → Jun 1–5 are all in the same Mon-first week.
        let week = (1...5).map { paid(2026, 6, $0, 9) } // 45h in one week
        let rules = PayRules(hourlyRate: 10, overtimeEnabled: true, overtimeThresholdHours: 40, overtimeMultiplier: 1.5)
        let s = PayEngine.summary(shifts: week, in: range((2026, 6, 1), (2026, 6, 7)), rules: rules, calendar: cal)
        #expect(s.totalHours == 45)
        #expect(s.baseHours == 40 && s.overtimeHours == 5)
        #expect(s.basePay == 400)
        #expect(s.overtimePay == 75) // 5 × 10 × 1.5
        #expect(s.grossPay == 475)
    }

    @Test func overtimeIsPerWeekNotPerPeriod() {
        // Two separate weeks each at 45h → overtime applies to EACH (not the sum).
        let w1 = (1...5).map { paid(2026, 6, $0, 9) }   // week of Jun 1
        let w2 = (8...12).map { paid(2026, 6, $0, 9) }  // week of Jun 8
        let rules = PayRules(hourlyRate: 10, overtimeEnabled: true, overtimeThresholdHours: 40, overtimeMultiplier: 1.5)
        let s = PayEngine.summary(shifts: w1 + w2, in: range((2026, 6, 1), (2026, 6, 14)), rules: rules, calendar: cal)
        #expect(s.overtimeHours == 10)       // 5 + 5, not (90 - 40)
        #expect(s.grossPay == 950)           // 80×10 + 10×10×1.5
    }

    @Test func overtimeProratesAcrossPeriodBoundary() {
        // Mon Jun 29 2026 begins a week that straddles into July (Jun 1 is a Monday,
        // +28d = Jun 29). 30h on Jun 29–30 + 30h on Jul 1–3 = 60h that week → 20h OT.
        let all = [paid(2026, 6, 29, 15), paid(2026, 6, 30, 15),      // 30h in June
                   paid(2026, 7, 1, 10), paid(2026, 7, 2, 10), paid(2026, 7, 3, 10)] // 30h in July
        let rules = PayRules(hourlyRate: 10, overtimeEnabled: true, overtimeThresholdHours: 40, overtimeMultiplier: 1.5)

        // Each month sees only its 30h, but overtime is computed on the FULL 60h week
        // and shared 50/50 → 20h base + 10h OT each, not 30h base + 0 OT.
        let jun = PayEngine.summary(shifts: all, in: range((2026, 6, 1), (2026, 6, 30)), rules: rules, calendar: cal)
        #expect(jun.baseHours == 20 && jun.overtimeHours == 10)
        #expect(jun.grossPay == 350) // 20×10 + 10×10×1.5

        let jul = PayEngine.summary(shifts: all, in: range((2026, 7, 1), (2026, 7, 31)), rules: rules, calendar: cal)
        #expect(jul.baseHours == 20 && jul.overtimeHours == 10)
        #expect(jul.grossPay == 350)

        // The two periods reconstruct the single-week result exactly (40 base + 20 OT).
        let week = PayEngine.summary(shifts: all, in: range((2026, 6, 29), (2026, 7, 5)), rules: rules, calendar: cal)
        #expect(week.grossPay == 700 && jun.grossPay + jul.grossPay == week.grossPay)
    }

    @Test func unpaidShiftTypeEarnsNothing() {
        let worked = paid(2026, 6, 1, 8)
        let unpaid = InsightShift(day: DayKey(year: 2026, month: 6, day: 2), start: nil, end: nil,
                                  paidHours: 8, typeKey: "UT", typeLabel: "Unpaid training",
                                  colorHex: nil, isAllDay: false, isPaid: false)
        let r = range((2026, 6, 1), (2026, 6, 7))
        let s = PayEngine.summary(shifts: [worked, unpaid], in: r, rules: PayRules(hourlyRate: 10), calendar: cal)
        #expect(s.totalHours == 8 && s.grossPay == 80) // the unpaid 8h is ignored
        #expect(s.shiftCount == 1)
        let items = PayEngine.lineItems(shifts: [worked, unpaid], in: r, rules: PayRules(hourlyRate: 10), calendar: cal)
        #expect(items.count == 1 && items[0].typeLabel == "Day")
    }

    @Test func overtimeDisabledPaysFlat() {
        let week = (1...5).map { paid(2026, 6, $0, 9) }
        let rules = PayRules(hourlyRate: 10, overtimeEnabled: false)
        let s = PayEngine.summary(shifts: week, in: range((2026, 6, 1), (2026, 6, 7)), rules: rules, calendar: cal)
        #expect(s.overtimeHours == 0 && s.grossPay == 450)
    }

    @Test func tentativeShiftsCountButDontPay() {
        let shifts = [paid(2026, 6, 1, 8), allDay(2026, 6, 2)]
        let s = PayEngine.summary(shifts: shifts, in: range((2026, 6, 1), (2026, 6, 7)), rules: PayRules(hourlyRate: 10), calendar: cal)
        #expect(s.totalHours == 8 && s.grossPay == 80)
        #expect(s.shiftCount == 2 && s.tentativeCount == 1)
    }

    @Test func zeroRateZeroPay() {
        let s = PayEngine.summary(shifts: [paid(2026, 6, 1, 8)], in: range((2026, 6, 1), (2026, 6, 7)), rules: PayRules(hourlyRate: 0), calendar: cal)
        #expect(s.totalHours == 8 && s.grossPay == 0)
    }

    @Test func taxYearRangeUKDefault() {
        let rules = PayRules(hourlyRate: 10) // 6 Apr default
        // Before 6 Apr → previous tax year.
        let r1 = PayEngine.taxYearRange(containing: DayKey(year: 2026, month: 3, day: 15), rules: rules, calendar: cal)
        #expect(r1.lowerBound == DayKey(year: 2025, month: 4, day: 6))
        #expect(r1.upperBound == DayKey(year: 2026, month: 4, day: 5))
        // On/after 6 Apr → current tax year.
        let r2 = PayEngine.taxYearRange(containing: DayKey(year: 2026, month: 4, day: 6), rules: rules, calendar: cal)
        #expect(r2.lowerBound == DayKey(year: 2026, month: 4, day: 6))
        #expect(r2.upperBound == DayKey(year: 2027, month: 4, day: 5))
    }

    @Test func lineItemsAreChronologicalBasePayAndSkipAllDay() {
        let shifts = [paid(2026, 6, 3, 8, label: "Late"), paid(2026, 6, 1, 6, label: "Early"), allDay(2026, 6, 2)]
        let items = PayEngine.lineItems(shifts: shifts, in: range((2026, 6, 1), (2026, 6, 7)), rules: PayRules(hourlyRate: 10), calendar: cal)
        #expect(items.count == 2) // all-day excluded
        #expect(items[0].day == DayKey(year: 2026, month: 6, day: 1) && items[0].pay == 60)
        #expect(items[1].day == DayKey(year: 2026, month: 6, day: 3) && items[1].pay == 80)
        #expect(Set(items.map(\.id)).count == 2) // unique ids
    }
}
