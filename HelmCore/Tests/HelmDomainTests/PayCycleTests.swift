//
//  PayCycleTests.swift
//  HelmDomainTests
//
//  v9 Payday Forecast: period boundaries (weekly/fortnightly/4-weekly/monthly),
//  payday derivation (lag for fixed cycles, day-of-month for monthly, clamped),
//  next/upcoming paydays, and the payday↔period round-trip.
//

import Testing
import Foundation
@testable import HelmDomain

struct PayCycleTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func d(_ y: Int, _ m: Int, _ day: Int) -> DayKey { DayKey(year: y, month: m, day: day) }

    @Test func weeklyPeriodBoundaries() {
        let c = PayCycle(frequency: .weekly, anchor: d(2026, 6, 1))
        #expect(c.period(containing: d(2026, 6, 3), calendar: cal) == d(2026, 6, 1)...d(2026, 6, 7))
        #expect(c.period(containing: d(2026, 6, 8), calendar: cal) == d(2026, 6, 8)...d(2026, 6, 14))
        // Before the anchor floors correctly (not toward zero).
        #expect(c.period(containing: d(2026, 5, 30), calendar: cal) == d(2026, 5, 25)...d(2026, 5, 31))
    }

    @Test func fortnightlyAndFourWeekly() {
        let f = PayCycle(frequency: .fortnightly, anchor: d(2026, 6, 1))
        #expect(f.period(containing: d(2026, 6, 14), calendar: cal) == d(2026, 6, 1)...d(2026, 6, 14))
        #expect(f.period(containing: d(2026, 6, 15), calendar: cal) == d(2026, 6, 15)...d(2026, 6, 28))
        let w4 = PayCycle(frequency: .fourWeekly, anchor: d(2026, 6, 1))
        #expect(w4.period(containing: d(2026, 6, 28), calendar: cal) == d(2026, 6, 1)...d(2026, 6, 28))
        #expect(w4.period(containing: d(2026, 6, 29), calendar: cal) == d(2026, 6, 29)...d(2026, 7, 26))
    }

    @Test func monthlyPeriodIsCalendarMonth() {
        let m = PayCycle(frequency: .monthly, anchor: d(2026, 6, 28))
        #expect(m.period(containing: d(2026, 6, 15), calendar: cal) == d(2026, 6, 1)...d(2026, 6, 30))
        #expect(m.period(containing: d(2026, 2, 9), calendar: cal) == d(2026, 2, 1)...d(2026, 2, 28))
    }

    @Test func monthlyPaydayUsesAnchorDayClamped() {
        let m = PayCycle(frequency: .monthly, anchor: d(2026, 1, 31))
        #expect(m.payday(forPeriodContaining: d(2026, 6, 10), calendar: cal) == d(2026, 6, 30)) // June has 30
        #expect(m.payday(forPeriodContaining: d(2026, 2, 10), calendar: cal) == d(2026, 2, 28)) // 2026 not leap
    }

    @Test func fixedPaydayUsesLag() {
        let c = PayCycle(frequency: .weekly, anchor: d(2026, 6, 1), lagDays: 3)
        // Period 1–7 Jun, money lands 3 days after the 7th.
        #expect(c.payday(forPeriodContaining: d(2026, 6, 4), calendar: cal) == d(2026, 6, 10))
    }

    @Test func nextPaydayScans() {
        let c = PayCycle(frequency: .weekly, anchor: d(2026, 6, 1)) // lag 0 → payday = period end
        #expect(c.nextPayday(after: d(2026, 6, 3), calendar: cal) == d(2026, 6, 7))
        #expect(c.nextPayday(after: d(2026, 6, 7), calendar: cal) == d(2026, 6, 14)) // strictly after
        let m = PayCycle(frequency: .monthly, anchor: d(2026, 6, 28))
        #expect(m.nextPayday(after: d(2026, 6, 20), calendar: cal) == d(2026, 6, 28))
        #expect(m.nextPayday(after: d(2026, 6, 28), calendar: cal) == d(2026, 7, 28))
    }

    @Test func paydayPeriodRoundTrip() {
        for cycle in [PayCycle(frequency: .weekly, anchor: d(2026, 6, 1), lagDays: 3),
                      PayCycle(frequency: .monthly, anchor: d(2026, 6, 28))] {
            let p = cycle.period(containing: d(2026, 6, 4), calendar: cal)
            let pd = cycle.payday(forPeriodContaining: d(2026, 6, 4), calendar: cal)
            #expect(cycle.period(forPayday: pd, calendar: cal) == p)
        }
    }

    @Test func upcomingPaydaysAreOrderedAndInclusive() {
        let c = PayCycle(frequency: .weekly, anchor: d(2026, 6, 1))
        let up = c.upcomingPaydays(from: d(2026, 6, 7), count: 3, calendar: cal) // 7 Jun IS a payday
        #expect(up.map(\.payday) == [d(2026, 6, 7), d(2026, 6, 14), d(2026, 6, 21)])
        #expect(up[0].period == d(2026, 6, 1)...d(2026, 6, 7))
    }
}
