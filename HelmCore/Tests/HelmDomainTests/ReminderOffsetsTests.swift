//
//  ReminderOffsetsTests.swift
//  HelmDomainTests
//

import Foundation
import Testing
@testable import HelmDomain

@Suite struct ReminderOffsetsTests {
    @Test func roundTripSortsAndDedupes() {
        #expect(ReminderOffsets.parse("720,60,60") == [60, 720])
        #expect(ReminderOffsets.encode([720, 60, 720]) == "60,720")
        #expect(ReminderOffsets.parse(ReminderOffsets.encode([0, 30])) == [0, 30])
    }

    @Test func emptyStringMeansNoReminders() {
        #expect(ReminderOffsets.parse("") == [])
        #expect(ReminderOffsets.encode([]) == "")
    }

    @Test func junkAndBoundsAreSanitised() {
        #expect(ReminderOffsets.parse("abc, -5, 999999, 60") == [0, 60, ReminderOffsets.maxMinutes])
        // Cap at 5 (Google's overrides limit), keeping the smallest offsets.
        #expect(ReminderOffsets.parse("10,20,30,40,50,60,70") == [10, 20, 30, 40, 50])
    }

    @Test func intervalOverlapIsHalfOpen() {
        let base = Date(timeIntervalSince1970: 1_780_986_600)
        let plus = { (m: Int) in base.addingTimeInterval(TimeInterval(m * 60)) }
        // Touching boundaries don't conflict (shift ends 13:30, event starts 13:30).
        #expect(!IntervalOverlap.intersects(base, plus(60), plus(60), plus(120)))
        #expect(IntervalOverlap.intersects(base, plus(61), plus(60), plus(120)))
        #expect(IntervalOverlap.intersects(plus(10), plus(20), base, plus(120))) // containment
    }
}
