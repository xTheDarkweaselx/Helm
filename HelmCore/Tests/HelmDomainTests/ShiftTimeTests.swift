//
//  ShiftTimeTests.swift
//  HelmDomainTests
//
//  Correctness tests for the wall-clock → absolute-time resolver, using the
//  real M/A shift definitions and the UK DST transitions of 2026.
//

import Testing
import Foundation
@testable import HelmDomain

private let london = TimeZone(identifier: "Europe/London")!

private func londonDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = london
    // Noon avoids any midnight DST edge when we only care about y/m/d.
    return cal.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
}

private func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0005 }

@Suite("ShiftTimeResolver")
struct ShiftTimeTests {

    @Test("Morning shift 06:30–13:30 is 7 hours")
    func morning() throws {
        let r = try #require(ShiftTimeResolver.resolve(
            localDay: londonDay(2026, 6, 14),
            startMinuteOfDay: 6 * 60 + 30,
            endMinuteOfDay: 13 * 60 + 30,
            timeZone: london
        ))
        #expect(approx(r.durationHours, 7.0))
    }

    @Test("Afternoon shift 13:30–22:00 is 8.5 hours")
    func afternoon() throws {
        let r = try #require(ShiftTimeResolver.resolve(
            localDay: londonDay(2026, 6, 14),
            startMinuteOfDay: 13 * 60 + 30,
            endMinuteOfDay: 22 * 60,
            timeZone: london
        ))
        #expect(approx(r.durationHours, 8.5))
    }

    @Test("Overnight shift 22:00–06:00 rolls to the next day and is 8 hours")
    func overnight() throws {
        let base = londonDay(2026, 6, 14)
        let r = try #require(ShiftTimeResolver.resolve(
            localDay: base,
            startMinuteOfDay: 22 * 60,
            endMinuteOfDay: 6 * 60, // earlier than start → overnight
            timeZone: london
        ))
        #expect(approx(r.durationHours, 8.0))
        var cal = Calendar(identifier: .gregorian); cal.timeZone = london
        #expect(cal.component(.day, from: r.end) == 15)
        #expect(cal.component(.day, from: r.start) == 14)
    }

    @Test("Spring-forward night loses an hour (8 wall hours → 7 real hours)")
    func springForward() throws {
        // UK clocks go forward 2026-03-29 at 01:00 → 02:00.
        let r = try #require(ShiftTimeResolver.resolve(
            localDay: londonDay(2026, 3, 28),
            startMinuteOfDay: 22 * 60,
            endMinuteOfDay: 6 * 60,
            timeZone: london
        ))
        #expect(approx(r.durationHours, 7.0))
    }

    @Test("Fall-back night gains an hour (8 wall hours → 9 real hours)")
    func fallBack() throws {
        // UK clocks go back 2026-10-25 at 02:00 → 01:00.
        let r = try #require(ShiftTimeResolver.resolve(
            localDay: londonDay(2026, 10, 24),
            startMinuteOfDay: 22 * 60,
            endMinuteOfDay: 6 * 60,
            timeZone: london
        ))
        #expect(approx(r.durationHours, 9.0))
    }

    @Test("Paid hours subtract the unpaid break")
    func paidHours() throws {
        let r = try #require(ShiftTimeResolver.resolve(
            localDay: londonDay(2026, 6, 14),
            startMinuteOfDay: 6 * 60 + 30,
            endMinuteOfDay: 13 * 60 + 30,
            timeZone: london
        ))
        #expect(approx(r.paidHours(breakMinutes: 30), 6.5))
    }

    @Test("endDayOffset is honoured explicitly")
    func explicitEndDayOffset() throws {
        let base = londonDay(2026, 6, 14)
        let r = try #require(ShiftTimeResolver.resolve(
            localDay: base,
            startMinuteOfDay: 9 * 60,
            endMinuteOfDay: 9 * 60, // same minute, but next day
            endDayOffset: 1,
            timeZone: london
        ))
        #expect(approx(r.durationHours, 24.0))
    }
}
