//
//  PremiumPayTests.swift
//  HelmDomainTests
//
//  v9 Premium Pay engine: triggers (weekday / time-window / bank-holiday / tag),
//  multiplier vs flat adjustments, stacking, break-scaling, and backward-compat.
//

import Testing
import Foundation
@testable import HelmDomain

struct PremiumPayTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// A timed shift on `day`, `clockHours` long from `startHour` (UTC), paid `paidHours`.
    private func shift(_ day: DayKey, startHour: Double, clockHours: Double, paidHours: Double? = nil,
                       tags: [String] = []) -> InsightShift {
        let midnight = day.startOfDay(in: cal)
        let start = midnight.addingTimeInterval(startHour * 3600)
        let end = start.addingTimeInterval(clockHours * 3600)
        return InsightShift(day: day, start: start, end: end, paidHours: paidHours ?? clockHours,
                            typeKey: "x", typeLabel: "Shift", colorHex: nil, isAllDay: false, tags: tags)
    }

    private func rate(_ r: Double, _ rules: [PremiumRule], stacking: PremiumStacking = .highest,
                      holidays: Set<DayKey> = []) -> PayRules {
        PayRules(hourlyRate: r, premiumRules: rules, premiumStacking: stacking, bankHolidays: holidays)
    }

    @Test func weekdayMultiplierAppliesToWholeShift() {
        let day = DayKey(year: 2026, month: 6, day: 13)
        let weekday = cal.component(.weekday, from: day.startOfDay(in: cal))
        let rules = rate(10, [PremiumRule(name: "Weekend", trigger: .weekdays([weekday]), adjustment: .multiplier(1.5))])
        // 8h × rate 10, ×1.5 → +£5/hr × 8 = £40 premium above base.
        let premium = PayEngine.premiumPay(for: shift(day, startHour: 9, clockHours: 8), rate: 10, rules: rules, calendar: cal)
        #expect(abs(premium - 40) < 0.001)
    }

    @Test func weekdayRuleDoesNotApplyOnOtherDays() {
        let sat = DayKey(year: 2026, month: 6, day: 13)
        let weekday = cal.component(.weekday, from: sat.startOfDay(in: cal))
        let otherDay = DayKey(year: 2026, month: 6, day: 16) // a different weekday
        let rules = rate(10, [PremiumRule(name: "Weekend", trigger: .weekdays([weekday]), adjustment: .multiplier(2))])
        #expect(PayEngine.premiumPay(for: shift(otherDay, startHour: 9, clockHours: 8), rate: 10, rules: rules, calendar: cal) == 0)
    }

    @Test func timeWindowEnhancesOnlyOverlappingHours() {
        // Shift 18:00–02:00 (8h). Night window 22:00–06:00 (1320…360) = 4h overlap.
        let day = DayKey(year: 2026, month: 6, day: 15)
        let night = PremiumRule(name: "Night", trigger: .timeWindow(startMinute: 22 * 60, endMinute: 6 * 60),
                                adjustment: .flatPerHour(3))
        let premium = PayEngine.premiumPay(for: shift(day, startHour: 18, clockHours: 8), rate: 12, rules: rate(12, [night]), calendar: cal)
        #expect(abs(premium - (3 * 4)) < 0.05) // +£3/hr × 4 night hours
    }

    @Test func bankHolidayTrigger() {
        let day = DayKey(year: 2026, month: 12, day: 25)
        let rules = rate(10, [PremiumRule(name: "Bank holiday", trigger: .bankHoliday, adjustment: .multiplier(2))], holidays: [day])
        // ×2 → +£10/hr × 8 = £80
        #expect(abs(PayEngine.premiumPay(for: shift(day, startHour: 9, clockHours: 8), rate: 10, rules: rules, calendar: cal) - 80) < 0.001)
        // Same shift on a non-holiday day earns no premium.
        let other = DayKey(year: 2026, month: 12, day: 26)
        #expect(PayEngine.premiumPay(for: shift(other, startHour: 9, clockHours: 8), rate: 10, rules: rules, calendar: cal) == 0)
    }

    @Test func shiftTagTriggerCaseInsensitive() {
        let day = DayKey(year: 2026, month: 6, day: 15)
        let rules = rate(10, [PremiumRule(name: "On-call", trigger: .shiftTag("On-Call"), adjustment: .flatPerHour(1.5))])
        let onCall = shift(day, startHour: 0, clockHours: 12, tags: ["senior", "on-call"])
        #expect(abs(PayEngine.premiumPay(for: onCall, rate: 10, rules: rules, calendar: cal) - (1.5 * 12)) < 0.001)
        let plain = shift(day, startHour: 0, clockHours: 12, tags: ["senior"])
        #expect(PayEngine.premiumPay(for: plain, rate: 10, rules: rules, calendar: cal) == 0)
    }

    @Test func stackingHighestVsSum() {
        // Saturday night: weekend ×1.5 (+£5/hr whole shift) AND night +£8/hr (22:00–02:00).
        let day = DayKey(year: 2026, month: 6, day: 13)
        let weekday = cal.component(.weekday, from: day.startOfDay(in: cal))
        let weekend = PremiumRule(name: "Weekend", trigger: .weekdays([weekday]), adjustment: .multiplier(1.5))
        let night = PremiumRule(name: "Night", trigger: .timeWindow(startMinute: 22 * 60, endMinute: 6 * 60), adjustment: .flatPerHour(8))
        let s = shift(day, startHour: 18, clockHours: 8) // 18:00–02:00; 4h pre-night + 4h night
        // highest: 4h × max(5) + 4h × max(5,8) = 20 + 32 = 52
        let highest = PayEngine.premiumPay(for: s, rate: 10, rules: rate(10, [weekend, night], stacking: .highest), calendar: cal)
        #expect(abs(highest - 52) < 0.1)
        // sum: 4h × 5 + 4h × (5+8) = 20 + 52 = 72
        let sum = PayEngine.premiumPay(for: s, rate: 10, rules: rate(10, [weekend, night], stacking: .sum), calendar: cal)
        #expect(abs(sum - 72) < 0.1)
    }

    @Test func breakScalesPremiumDown() {
        // 8h clock, 7h paid (1h unpaid break) — premium scales by 7/8.
        let day = DayKey(year: 2026, month: 6, day: 13)
        let weekday = cal.component(.weekday, from: day.startOfDay(in: cal))
        let rules = rate(10, [PremiumRule(name: "Weekend", trigger: .weekdays([weekday]), adjustment: .multiplier(1.5))])
        let premium = PayEngine.premiumPay(for: shift(day, startHour: 9, clockHours: 8, paidHours: 7), rate: 10, rules: rules, calendar: cal)
        #expect(abs(premium - 40 * (7.0 / 8.0)) < 0.001) // £35
    }

    @Test func noRulesMeansNoPremiumAndUnchangedGross() {
        let day = DayKey(year: 2026, month: 6, day: 13)
        let s = shift(day, startHour: 9, clockHours: 8)
        let rules = PayRules(hourlyRate: 10) // no premium rules
        #expect(PayEngine.premiumPay(for: s, rate: 10, rules: rules, calendar: cal) == 0)
        let summary = PayEngine.summary(shifts: [s], in: day...day, rules: rules, calendar: cal)
        #expect(summary.premiumPay == 0)
        #expect(abs(summary.grossPay - 80) < 0.001) // base only, unchanged from v8
    }

    @Test func summaryAndLineItemsIncludePremium() {
        let day = DayKey(year: 2026, month: 6, day: 13)
        let weekday = cal.component(.weekday, from: day.startOfDay(in: cal))
        let rules = rate(10, [PremiumRule(name: "Weekend", trigger: .weekdays([weekday]), adjustment: .multiplier(1.5))])
        let s = shift(day, startHour: 9, clockHours: 8)
        let summary = PayEngine.summary(shifts: [s], in: day...day, rules: rules, calendar: cal)
        #expect(abs(summary.basePay - 80) < 0.001)
        #expect(abs(summary.premiumPay - 40) < 0.001)
        #expect(abs(summary.grossPay - 120) < 0.001)
        let items = PayEngine.lineItems(shifts: [s], in: day...day, rules: rules, calendar: cal)
        #expect(items.count == 1)
        #expect(abs(items[0].premiumPay - 40) < 0.001)
        #expect(abs(items[0].pay - 120) < 0.001) // base + premium
    }
}
