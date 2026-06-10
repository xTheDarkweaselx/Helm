//
//  V6CoreTests.swift
//  HelmDomainTests
//
//  v6 pure cores: the three-tier merged legend, composite codes, import
//  health, the timeline layout engine, and the single insights/hours engine.
//

import Foundation
import Testing
@testable import HelmDomain

private func ukCal() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.locale = Locale(identifier: "en_GB")
    cal.firstWeekday = 2
    cal.timeZone = TimeZone(identifier: "Europe/London")!
    return cal
}

// MARK: - LegendMerger

@Suite struct LegendMergerTests {
    private let nightType = LegendMerger.GlobalType(
        code: "N", label: "Night", startMinuteOfDay: 22 * 60, endMinuteOfDay: 6 * 60 + 30,
        endDayOffset: 1, breakMinutes: 30, shiftTypeID: "night-1"
    )

    @Test func tiersShadowInOrder() {
        let learned = LegendMerger.Learned(
            code: "M", action: .timed, label: "My Morning", startMinute: 420, endMinute: 900, id: "map-1"
        )
        let merged = LegendMerger.merge(globalTypes: [nightType], learned: [learned])
        // Built-in M overridden by the learned mapping.
        guard case let .timed(m)? = merged.resolution(for: "M") else { Issue.record("M missing"); return }
        #expect(m.label == "My Morning" && m.startMinute == 420)
        // Global N arrives with the offset applied.
        guard case let .timed(n)? = merged.resolution(for: "N") else { Issue.record("N missing"); return }
        #expect(n.startMinute == 1320 && n.endMinute == 1830 && n.shiftTypeID == "night-1")
        // Untouched built-in survives.
        guard case let .timed(a)? = merged.resolution(for: "A") else { Issue.record("A missing"); return }
        #expect(a.label == "Afternoon")
    }

    @Test func sentinelAndDegenerateGlobalsAreFiltered() {
        let offType = LegendMerger.GlobalType(code: "OFF", label: "Sneaky", startMinuteOfDay: 0, endMinuteOfDay: 600, endDayOffset: 0, breakMinutes: 0, shiftTypeID: "x")
        let tbc = LegendMerger.GlobalType(code: "TBC", label: "Nope", startMinuteOfDay: 0, endMinuteOfDay: 600, endDayOffset: 0, breakMinutes: 0, shiftTypeID: "y")
        let degenerate = LegendMerger.GlobalType(code: "Z", label: nil, startMinuteOfDay: 540, endMinuteOfDay: 540, endDayOffset: 0, breakMinutes: 0, shiftTypeID: "z")
        let merged = LegendMerger.merge(globalTypes: [offType, tbc, degenerate], learned: [])
        #expect(merged.resolution(for: "OFF") == nil)
        #expect(merged.resolution(for: "TBC") == nil)
        #expect(merged.resolution(for: "Z") == nil)
    }

    @Test func ambiguousGlobalCodeDropsOut_equalDuplicatesKeepOne() {
        let l1 = LegendMerger.GlobalType(code: "L", label: "Late", startMinuteOfDay: 720, endMinuteOfDay: 1200, endDayOffset: 0, breakMinutes: 0, shiftTypeID: "a")
        let l2 = LegendMerger.GlobalType(code: "L", label: "Later", startMinuteOfDay: 800, endMinuteOfDay: 1300, endDayOffset: 0, breakMinutes: 0, shiftTypeID: "b")
        #expect(LegendMerger.merge(globalTypes: [l1, l2], learned: []).resolution(for: "L") == nil)

        let dup = LegendMerger.GlobalType(code: "L", label: "Late", startMinuteOfDay: 720, endMinuteOfDay: 1200, endDayOffset: 0, breakMinutes: 0, shiftTypeID: "c")
        guard case let .timed(entry)? = LegendMerger.merge(globalTypes: [l1, dup], learned: []).resolution(for: "L") else {
            Issue.record("equal duplicates should keep one"); return
        }
        #expect(entry.shiftTypeID == "a") // deterministic: lowest id
    }

    @Test func builtinPreservationPreventsTitleChurn() {
        // Engine-synthesized library type: code M, same minutes, nil label.
        let synth = LegendMerger.GlobalType(code: "M", label: nil, startMinuteOfDay: 390, endMinuteOfDay: 810, endDayOffset: 0, breakMinutes: 0, shiftTypeID: "synth")
        let merged = LegendMerger.merge(globalTypes: [synth], learned: [])
        guard case let .timed(m)? = merged.resolution(for: "M") else { Issue.record("M missing"); return }
        #expect(m.label == "Morning") // byte-identical to the built-in label
        #expect(m.shiftTypeID == "synth") // but the real type still flows through
    }

    @Test func learnedActionsAndDedupe() {
        let ignore = LegendMerger.Learned(code: "X", action: .ignore, id: "i1")
        let allDay = LegendMerger.Learned(code: "AL", action: .allDay, label: "Annual Leave", id: "a1")
        let older = LegendMerger.Learned(code: "L", action: .timed, label: "Old", startMinute: 700, endMinute: 1100, lastUsedAt: Date(timeIntervalSince1970: 1000), id: "z")
        let newer = LegendMerger.Learned(code: "L", action: .timed, label: "New", startMinute: 720, endMinute: 1200, lastUsedAt: Date(timeIntervalSince1970: 2000), id: "a")
        let dangling = LegendMerger.Learned(code: "Q", action: .timed, label: "Gone", startMinute: nil, endMinute: nil, id: "d")
        let merged = LegendMerger.merge(globalTypes: [], learned: [ignore, allDay, older, newer, dangling])
        #expect(merged.resolution(for: "X") == .ignore)
        #expect(merged.resolution(for: "AL") == .allDay(label: "Annual Leave"))
        guard case let .timed(l)? = merged.resolution(for: "L") else { Issue.record("L missing"); return }
        #expect(l.label == "New")
        #expect(merged.resolution(for: "Q") == nil) // dangling falls through
    }
}

// MARK: - CompositeShiftCode + ImportHealth

@Suite struct CompositeAndHealthTests {
    @Test func splitRecognisesSeparators() {
        #expect(CompositeShiftCode.split("M/A") == ["M", "A"])
        #expect(CompositeShiftCode.split("M+A") == ["M", "A"])
        #expect(CompositeShiftCode.split("M & A") == ["M", "A"])
        #expect(CompositeShiftCode.split("M").isEmpty)
        #expect(CompositeShiftCode.split("").isEmpty)
    }

    @Test func spanningSuggestionCoversBothParts() {
        let m = ShiftLegendEntry(code: "M", label: "Morning", startMinute: 390, endMinute: 810)
        let a = ShiftLegendEntry(code: "A", label: "Afternoon", startMinute: 810, endMinute: 1320)
        let span = CompositeShiftCode.spanningSuggestion(parts: [m, a])
        #expect(span?.startMinute == 390 && span?.endMinute == 1320)
        #expect(CompositeShiftCode.spanningSuggestion(parts: [m]) == nil)
    }

    @Test func healthSummaryReadsHonestly() {
        let health = ImportHealth(written: 26, allDay: 2, off: 4, byRule: 0, unknown: 1, unknownCodes: ["L"])
        #expect(health.summary == "26 shifts · 2 all-day · 4 off · 1 unknown (L)")
        #expect(health.hasUnknown)
        let clean = ImportHealth(written: 1, allDay: 0, off: 0, byRule: 2, unknown: 0, unknownCodes: [])
        #expect(clean.summary == "1 shift · 2 ignored by your rules")
    }
}

// MARK: - TimelineLayoutEngine

@Suite struct TimelineLayoutEngineTests {
    private let cal = ukCal()
    private let day = DayKey(year: 2026, month: 6, day: 9)

    private func date(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        ukCal().date(from: DateComponents(year: 2026, month: 6, day: d, hour: h, minute: m))!
    }

    @Test func backToBackShiftsStayFullWidth() {
        let spans = [
            TimelineLayoutEngine.Span(id: "M", start: date(9, 6, 30), end: date(9, 13, 30)),
            TimelineLayoutEngine.Span(id: "A", start: date(9, 13, 30), end: date(9, 22, 0)),
        ]
        let placed = TimelineLayoutEngine.layout(spans: spans, day: day, calendar: cal)
        #expect(placed.count == 2)
        #expect(placed.allSatisfy { $0.columnCount == 1 && $0.column == 0 })
    }

    @Test func overlappingSpansSplitColumns() {
        let spans = [
            TimelineLayoutEngine.Span(id: "a", start: date(9, 9), end: date(9, 12)),
            TimelineLayoutEngine.Span(id: "b", start: date(9, 10), end: date(9, 13)),
        ]
        let placed = TimelineLayoutEngine.layout(spans: spans, day: day, calendar: cal)
        #expect(Set(placed.map(\.column)) == [0, 1])
        #expect(placed.allSatisfy { $0.columnCount == 2 })
    }

    @Test func chainClusterSharesWidthAndReusesColumns() {
        // a(9-11) overlaps b(10-12); b overlaps c(11-13); a and c don't overlap →
        // one cluster, two columns, c reuses column 0.
        let spans = [
            TimelineLayoutEngine.Span(id: "a", start: date(9, 9), end: date(9, 11)),
            TimelineLayoutEngine.Span(id: "b", start: date(9, 10), end: date(9, 12)),
            TimelineLayoutEngine.Span(id: "c", start: date(9, 11), end: date(9, 13)),
        ]
        let placed = TimelineLayoutEngine.layout(spans: spans, day: day, calendar: cal)
        let byID = Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0) })
        #expect(placed.allSatisfy { $0.columnCount == 2 })
        #expect(byID["a"]?.column == 0)
        #expect(byID["b"]?.column == 1)
        #expect(byID["c"]?.column == 0)
    }

    @Test func overnightShiftClipsWithContinuationFlags() {
        let span = TimelineLayoutEngine.Span(id: "n", start: date(9, 22), end: date(10, 6))
        let onStartDay = TimelineLayoutEngine.layout(spans: [span], day: day, calendar: cal)
        #expect(onStartDay.count == 1)
        #expect(onStartDay[0].startMinute == 22 * 60)
        #expect(onStartDay[0].endMinute == 24 * 60)
        #expect(onStartDay[0].continuesAfter && !onStartDay[0].continuesBefore)

        let nextDay = TimelineLayoutEngine.layout(spans: [span], day: day.advanced(by: 1, in: cal), calendar: cal)
        #expect(nextDay[0].startMinute == 0)
        #expect(nextDay[0].endMinute == 6 * 60)
        #expect(nextDay[0].continuesBefore && !nextDay[0].continuesAfter)
    }

    @Test func dstDayHasShortAxis() {
        // UK spring-forward: 29 Mar 2026 is a 23-hour day.
        let dst = DayKey(year: 2026, month: 3, day: 29)
        #expect(TimelineLayoutEngine.dayLengthMinutes(day: dst, calendar: cal) == 1380)
        #expect(TimelineLayoutEngine.dayLengthMinutes(day: day, calendar: cal) == 1440)
    }

    @Test func nonIntersectingSpansAreDropped() {
        let span = TimelineLayoutEngine.Span(id: "x", start: date(11, 9), end: date(11, 17))
        #expect(TimelineLayoutEngine.layout(spans: [span], day: day, calendar: cal).isEmpty)
    }
}

// MARK: - InsightsMath

@Suite struct InsightsMathTests {
    private let cal = ukCal()

    private func shift(_ day: DayKey, hours: Double? = nil, start: Date? = nil, end: Date? = nil, type: String = "M", allDay: Bool = false) -> InsightShift {
        InsightShift(day: day, start: start, end: end, paidHours: hours, typeKey: type, typeLabel: type, colorHex: nil, isAllDay: allDay)
    }

    @Test func hoursPreferPaidThenDurationAndAllDayIsNil() {
        let d = DayKey(year: 2026, month: 6, day: 9)
        let start = ukCal().date(from: DateComponents(year: 2026, month: 6, day: 9, hour: 6, minute: 30))!
        let end = ukCal().date(from: DateComponents(year: 2026, month: 6, day: 9, hour: 13, minute: 30))!
        #expect(InsightsMath.hours(for: shift(d, hours: 6.5, start: start, end: end)) == 6.5)
        #expect(InsightsMath.hours(for: shift(d, start: start, end: end)) == 7)
        #expect(InsightsMath.hours(for: shift(d, allDay: true)) == nil)
    }

    @Test func weeklyHoursZeroFillsAndRespectsWeekStart() {
        let today = DayKey(year: 2026, month: 6, day: 10) // Wednesday
        let monday = DayKey(year: 2026, month: 6, day: 8)
        let lastWeekTue = DayKey(year: 2026, month: 6, day: 2)
        let shifts = [
            shift(monday, hours: 7),
            shift(lastWeekTue, hours: 8.5),
            shift(DayKey(year: 2026, month: 6, day: 3), allDay: true), // tentative
        ]
        let buckets = InsightsMath.weeklyHours(shifts: shifts, weeks: 3, endingAt: today, calendar: cal)
        #expect(buckets.count == 3)
        #expect(buckets[0].hours == 0) // zero-filled empty week (25–31 May)
        #expect(buckets[1].weekStart == DayKey(year: 2026, month: 6, day: 1))
        #expect(buckets[1].hours == 8.5)
        #expect(buckets[1].tentativeCount == 1)
        #expect(buckets[2].weekStart == monday)
        #expect(buckets[2].hours == 7)

        // Sunday-start locale shifts the buckets.
        var us = cal
        us.firstWeekday = 1
        let usBuckets = InsightsMath.weeklyHours(shifts: shifts, weeks: 1, endingAt: today, calendar: us)
        #expect(usBuckets[0].weekStart == DayKey(year: 2026, month: 6, day: 7)) // Sunday
    }

    @Test func typeMixSortsByHours() {
        let d = DayKey(year: 2026, month: 6, day: 9)
        let mix = InsightsMath.typeMix(
            shifts: [shift(d, hours: 7, type: "M"), shift(d, hours: 8.5, type: "A"), shift(d, hours: 7, type: "M")],
            in: d...d
        )
        #expect(mix.first?.key == "M") // 14h beats 8.5h
        #expect(mix.first?.hours == 14)
        #expect(mix.last?.key == "A")
    }

    @Test func monthComparisonCrossesYearBoundary() {
        let dec = DayKey(year: 2025, month: 12, day: 31)
        let jan = DayKey(year: 2026, month: 1, day: 2)
        let result = InsightsMath.monthComparison(
            shifts: [shift(dec, hours: 8), shift(jan, hours: 6)],
            month: MonthKey(year: 2026, month: 1), calendar: cal
        )
        #expect(result.current == 6 && result.previous == 8)
    }

    @Test func streakCountsTentativeDaysAndStopsAtGaps() {
        let today = DayKey(year: 2026, month: 6, day: 10)
        let worked: Set<DayKey> = [
            today,
            DayKey(year: 2026, month: 6, day: 9),
            DayKey(year: 2026, month: 6, day: 8),
            // gap on the 7th
            DayKey(year: 2026, month: 6, day: 6),
        ]
        #expect(InsightsMath.currentStreak(endingAt: today, workedDays: worked, calendar: cal) == 3)
        #expect(InsightsMath.currentStreak(endingAt: DayKey(year: 2026, month: 6, day: 7), workedDays: worked, calendar: cal) == 0)
    }
}
