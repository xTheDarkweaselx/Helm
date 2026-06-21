//
//  RosterSummaryTests.swift
//  HelmDomainTests
//
//  v9 Roster Card text formatting.
//

import Testing
import Foundation
@testable import HelmDomain

struct RosterSummaryTests {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func date(_ m: Int, _ d: Int) -> Date {
        DateComponents(calendar: cal, timeZone: cal.timeZone, year: 2026, month: m, day: d).date!
    }

    @Test func formatsCardWithStatsAndSortedLines() {
        let lines = [
            RosterSummary.ShiftLine(date: date(6, 3), label: "Night", detail: "22:00–06:00"),
            RosterSummary.ShiftLine(date: date(6, 1), label: "Early", detail: "07:00–15:00"),
        ]
        let text = RosterSummary.text(title: "June", rangeText: "1 Jun – 3 Jun",
                                      shiftCount: 2, hours: 16, lines: lines, calendar: cal)
        #expect(text.hasPrefix("June\n2 shifts · 16 h · 1 Jun – 3 Jun"))
        // Earlier date first.
        let earlyIdx = text.range(of: "Early")!.lowerBound
        let nightIdx = text.range(of: "Night")!.lowerBound
        #expect(earlyIdx < nightIdx)
        #expect(text.contains("Early  07:00–15:00"))
        #expect(text.hasSuffix("Shared from Helm"))
    }

    @Test func singularShiftAndNoHoursAndDefaultTitle() {
        let text = RosterSummary.text(title: "  ", rangeText: nil, shiftCount: 1, hours: 0,
                                      lines: [RosterSummary.ShiftLine(date: date(1, 1), label: "TBC", detail: "TBC")],
                                      calendar: cal)
        #expect(text.hasPrefix("Roster\n1 shift\n"))   // default title, singular, no hours/range
    }
}
