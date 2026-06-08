//
//  ShiftCodeTests.swift
//  HelmDomainTests
//

import Testing
import Foundation
@testable import HelmDomain

@Suite("ShiftCodeNormalizer")
struct ShiftCodeNormalizerTests {
    @Test("Trims, collapses whitespace, uppercases")
    func normalize() {
        #expect(ShiftCodeNormalizer.normalize("  m ") == "M")
        #expect(ShiftCodeNormalizer.normalize("off") == "OFF")
        #expect(ShiftCodeNormalizer.normalize("M / A") == "M / A")
        #expect(ShiftCodeNormalizer.normalize("tbc") == "TBC")
    }

    @Test("Recognises off and tentative sentinels")
    func sentinels() {
        #expect(ShiftCodeNormalizer.isOff("OFF"))
        #expect(ShiftCodeNormalizer.isOff("-"))
        #expect(ShiftCodeNormalizer.isOff("0"))
        #expect(!ShiftCodeNormalizer.isOff("M"))
        #expect(ShiftCodeNormalizer.isTentative("TBC"))
        #expect(!ShiftCodeNormalizer.isTentative("A"))
    }
}

@Suite("InlineTimeRange")
struct InlineTimeRangeTests {
    @Test("Parses compact ranges like 0900-1700")
    func compact() {
        let r = InlineTimeRange.parse("0900-1700")
        #expect(r == InlineTimeRange(startMinuteOfDay: 540, endMinuteOfDay: 1020))
    }

    @Test("Parses colon and spaced ranges")
    func variants() {
        #expect(InlineTimeRange.parse("09:00-17:00") == InlineTimeRange(startMinuteOfDay: 540, endMinuteOfDay: 1020))
        #expect(InlineTimeRange.parse("0930 - 1500") == InlineTimeRange(startMinuteOfDay: 570, endMinuteOfDay: 900))
        #expect(InlineTimeRange.parse("2200–0600") == InlineTimeRange(startMinuteOfDay: 1320, endMinuteOfDay: 360))
    }

    @Test("Returns nil for non-ranges")
    func nonRanges() {
        #expect(InlineTimeRange.parse("M") == nil)
        #expect(InlineTimeRange.parse("OFF") == nil)
        #expect(InlineTimeRange.parse("2500-0600") == nil) // invalid hour
    }
}

@Suite("ParsedShift")
struct ParsedShiftTests {
    @Test("Dedup key input is stable for the same day/zone/code")
    func dedupStable() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        let date = cal.date(from: DateComponents(year: 2026, month: 6, day: 14, hour: 9))!
        let a = ParsedShift(localDate: date, timeZoneIdentifier: "Europe/London", normalizedCode: "M")
        let b = ParsedShift(localDate: date, timeZoneIdentifier: "Europe/London", normalizedCode: "M", title: "HMI Day 1")
        #expect(a.dedupKeyInput == b.dedupKeyInput) // title is not part of identity
        #expect(a.dedupKeyInput == "2026-06-14|Europe/London|M")
    }
}
