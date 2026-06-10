//
//  V7CoreTests.swift
//  HelmDomainTests
//
//  v7 pure cores: the theme catalog, shift tags + colours, colour presets, the
//  leave accumulator, the availability merger, and the shared app-group
//  snapshot + next-shift rule.
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

private func date(_ y: Int, _ m: Int, _ d: Int, _ hour: Int = 0, _ minute: Int = 0, cal: Calendar) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour, minute: minute)) ?? .distantPast
}

private func isHex6(_ s: String) -> Bool {
    s.count == 6 && s.allSatisfy(\.isHexDigit)
}

// MARK: - Theme catalog

@Suite struct ThemeCatalogTests {
    @Test func idsAreUnique() {
        let ids = ThemeCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func atLeastSixThemes() {
        #expect(ThemeCatalog.all.count >= 6) // default + 5 floor
    }

    @Test func everyHexParses() {
        for theme in ThemeCatalog.all {
            if let a = theme.accentHex { #expect(isHex6(a), "bad accent \(theme.id)") }
            if let s = theme.secondaryHex { #expect(isHex6(s), "bad secondary \(theme.id)") }
            if let g = theme.glassTintHex { #expect(isHex6(g), "bad glass \(theme.id)") }
        }
    }

    @Test func defaultIsSystemAndNeutral() {
        let d = ThemeCatalog.default
        #expect(d.id == "default")
        #expect(d.accentHex == nil)        // falls through to system accent
        #expect(d.scheme == .system)
        #expect(d.glassTintHex == nil)
    }

    @Test func unknownAndNilResolveToDefault() {
        #expect(ThemeCatalog.palette(id: "nope").id == "default")
        #expect(ThemeCatalog.palette(id: nil).id == "default")
    }

    @Test func allRequestedVibesPresent() {
        let vibes = Set(ThemeCatalog.all.map(\.vibe))
        #expect(vibes.isSuperset(of: [.classic, .professional, .vibrant, .dark, .seasonal]))
    }

    @Test func groupedIsVibeOrdered() {
        let order = ThemeCatalog.grouped.map(\.vibe.sortOrder)
        #expect(order == order.sorted())
    }
}

// MARK: - Shift tags

@Suite struct ShiftTagsTests {
    @Test func parseTrimsDropsEmptiesAndDedupesCaseInsensitive() {
        let tags = ShiftTags.parse("  Night , night ,, Senior , SENIOR ,Cover ")
        #expect(tags == ["Night", "Senior", "Cover"]) // first spelling kept
    }

    @Test func parseStripsDelimitersAndCaps() {
        let tags = ShiftTags.parse("a|b,c")        // '|' becomes a space inside a cell
        #expect(tags == ["a b", "c"])
        let many = (1...20).map { "t\($0)" }.joined(separator: ",")
        #expect(ShiftTags.parse(many).count == ShiftTags.maxCount)
    }

    @Test func longTagClampedToMaxLength() {
        let long = String(repeating: "x", count: 50)
        #expect(ShiftTags.parse(long).first?.count == ShiftTags.maxLength)
    }

    @Test func encodeIsIdempotent() {
        let once = ShiftTags.encode(["Night", "night", "Cover"])
        #expect(once == "Night,Cover")
        #expect(ShiftTags.encode(ShiftTags.parse(once)) == once)
    }

    @Test func colorsRoundTripAndDropMissing() {
        let raw = "Night|3A4A5E,Senior|FF7A1A"
        let map = ShiftTags.parseColors(raw)
        #expect(map["night"] == "3A4A5E")
        #expect(map["senior"] == "FF7A1A")
        // encode restricted to surviving tags (Senior deleted) and normalised order
        let encoded = ShiftTags.encodeColors(map, among: ["Night"])
        #expect(encoded == "Night|3A4A5E")
    }

    @Test func colorForTagPrefersCustomThenDeterministicPalette() {
        let custom = ["night": "112233"]
        #expect(ShiftTags.colorHex(for: "Night", customColors: custom) == "112233")
        // No custom colour → deterministic + stable across calls.
        let a = ShiftTags.colorHex(for: "Cover", customColors: [:])
        let b = ShiftTags.colorHex(for: "cover", customColors: [:])
        #expect(a == b)
        #expect(isHex6(a))
    }

    @Test func normalizedHexValidation() {
        #expect(ShiftTags.normalizedHex("#abcdef") == "ABCDEF")
        #expect(ShiftTags.normalizedHex("abcdef") == "ABCDEF")
        #expect(ShiftTags.normalizedHex("xyz") == nil)
        #expect(ShiftTags.normalizedHex("12345") == nil)
        #expect(ShiftTags.normalizedHex("ＡＢＣＤＥＦ") == nil) // fullwidth, not ASCII hex
        #expect(ShiftTags.normalizedHex("１２３４５６") == nil)
    }
}

@Suite struct ShiftColorPresetsTests {
    @Test func presetsAreValidAndUnique() {
        #expect(ShiftColorPresets.all.allSatisfy(isHex6))
        #expect(Set(ShiftColorPresets.all).count == ShiftColorPresets.all.count)
        #expect(ShiftColorPresets.tagPalette.allSatisfy(isHex6))
        #expect(!ShiftColorPresets.tagPalette.isEmpty)
    }
}

// MARK: - Leave accumulator

@Suite struct LeaveAccumulatorTests {
    private let cal = ukCal()

    @Test func inclusiveDayCount() {
        let e = LeaveEntry(id: "1", start: DayKey(year: 2026, month: 6, day: 1), end: DayKey(year: 2026, month: 6, day: 5), kind: .annual, paid: true)
        #expect(LeaveAccumulator.days(in: e, calendar: cal) == 5)
    }

    @Test func invertedRangeTolerated() {
        let e = LeaveEntry(id: "1", start: DayKey(year: 2026, month: 6, day: 5), end: DayKey(year: 2026, month: 6, day: 1), kind: .annual, paid: true)
        #expect(e.start < e.end)
        #expect(LeaveAccumulator.days(in: e, calendar: cal) == 5)
    }

    @Test func daysClampToRange() {
        let e = LeaveEntry(id: "1", start: DayKey(year: 2026, month: 5, day: 28), end: DayKey(year: 2026, month: 6, day: 4), kind: .annual, paid: true)
        let june = DayKey(year: 2026, month: 6, day: 1)...DayKey(year: 2026, month: 6, day: 30)
        #expect(LeaveAccumulator.days(in: e, clampedTo: june, calendar: cal) == 4) // Jun 1–4
    }

    @Test func entriesCovering() {
        let e = LeaveEntry(id: "1", start: DayKey(year: 2026, month: 6, day: 1), end: DayKey(year: 2026, month: 6, day: 3), kind: .sick, paid: false)
        #expect(LeaveAccumulator.entriesCovering(DayKey(year: 2026, month: 6, day: 2), in: [e]).count == 1)
        #expect(LeaveAccumulator.entriesCovering(DayKey(year: 2026, month: 6, day: 4), in: [e]).isEmpty)
    }

    @Test func summaryAggregates() {
        let entries = [
            LeaveEntry(id: "a", start: DayKey(year: 2026, month: 6, day: 1), end: DayKey(year: 2026, month: 6, day: 3), kind: .annual, paid: true, hoursPerDay: 7.5),
            LeaveEntry(id: "b", start: DayKey(year: 2026, month: 6, day: 10), end: DayKey(year: 2026, month: 6, day: 10), kind: .sick, paid: false),
        ]
        let range = DayKey(year: 2026, month: 6, day: 1)...DayKey(year: 2026, month: 6, day: 30)
        let s = LeaveAccumulator.summary(entries, in: range, calendar: cal)
        #expect(s.totalDays == 4)
        #expect(s.paidDays == 3)
        #expect(s.unpaidDays == 1)
        #expect(abs(s.hours - 22.5) < 0.001)  // 3 × 7.5
        #expect(s.byKind.first?.kind == .annual) // largest first
    }
}

// MARK: - Availability merger

@Suite struct AvailabilityMergerTests {
    private let cal = ukCal()
    // 2026-06-08 is a Monday (Foundation weekday 2).
    private let monday = DayKey(year: 2026, month: 6, day: 8)
    private let tuesday = DayKey(year: 2026, month: 6, day: 9)

    @Test func recurringRuleExpandsOnMatchingWeekdayOnly() {
        let rule = AvailabilityRuleSpec(id: "r", kind: .unavailable, weekdays: [2], startMinute: 0, endMinute: 12 * 60) // Mon mornings
        #expect(AvailabilityMerger.bands(on: monday, rules: [rule], windows: [], calendar: cal).count == 1)
        #expect(AvailabilityMerger.bands(on: tuesday, rules: [rule], windows: [], calendar: cal).isEmpty)
    }

    @Test func effectiveRangeBoundsRule() {
        let rule = AvailabilityRuleSpec(id: "r", kind: .unavailable, weekdays: [2], startMinute: 0, endMinute: 720,
                                        effectiveFrom: DayKey(year: 2026, month: 6, day: 15))
        #expect(AvailabilityMerger.bands(on: monday, rules: [rule], windows: [], calendar: cal).isEmpty) // before from
    }

    @Test func oneOffWindowsIncludedAndMarked() {
        let w = AvailabilityWindowSpec(id: "w", kind: .unavailable, day: tuesday, allDay: true)
        let bands = AvailabilityMerger.bands(on: tuesday, rules: [], windows: [w], calendar: cal)
        #expect(bands.count == 1)
        #expect(bands.first?.isOneOff == true)
        #expect(bands.first?.endMinute == 1440)
    }

    @Test func shiftOverlappingUnavailableBandConflicts() {
        let rule = AvailabilityRuleSpec(id: "r", kind: .unavailable, weekdays: [2], startMinute: 6 * 60, endMinute: 12 * 60)
        let overlapping = AvailabilityShift(id: "s1", day: monday, startMinute: 8 * 60, endMinute: 16 * 60, isAllDay: false)
        let after = AvailabilityShift(id: "s2", day: monday, startMinute: 12 * 60, endMinute: 20 * 60, isAllDay: false) // back-to-back, half-open
        let conflicts = AvailabilityMerger.conflictingShiftIDs(shifts: [overlapping, after], rules: [rule], windows: [], calendar: cal)
        #expect(conflicts == ["s1"])
    }

    @Test func availableBandNeverConflicts() {
        let rule = AvailabilityRuleSpec(id: "r", kind: .available, weekdays: [2], startMinute: 0, endMinute: 1440)
        let shift = AvailabilityShift(id: "s", day: monday, startMinute: 8 * 60, endMinute: 16 * 60, isAllDay: false)
        #expect(AvailabilityMerger.conflictingShiftIDs(shifts: [shift], rules: [rule], windows: [], calendar: cal).isEmpty)
    }

    @Test func overnightTailChecksNextDay() {
        // Unavailable Tuesday 00:00–06:00; a Monday-night shift 22:00→02:00 (endMinute 1560).
        let rule = AvailabilityRuleSpec(id: "r", kind: .unavailable, weekdays: [3], startMinute: 0, endMinute: 6 * 60) // Tue
        let overnight = AvailabilityShift(id: "n", day: monday, startMinute: 22 * 60, endMinute: 26 * 60, isAllDay: false)
        #expect(AvailabilityMerger.conflictingShiftIDs(shifts: [overnight], rules: [rule], windows: [], calendar: cal) == ["n"])
    }

    @Test func allDayShiftSkipped() {
        let rule = AvailabilityRuleSpec(id: "r", kind: .unavailable, weekdays: [2], startMinute: 0, endMinute: 1440)
        let allDay = AvailabilityShift(id: "s", day: monday, startMinute: 0, endMinute: 0, isAllDay: true)
        #expect(AvailabilityMerger.conflictingShiftIDs(shifts: [allDay], rules: [rule], windows: [], calendar: cal).isEmpty)
    }

    // Overnight rule "Unavailable Mondays 22:00 → 06:00" (end ≤ start).
    private var overnightMondayRule: AvailabilityRuleSpec {
        AvailabilityRuleSpec(id: "r", kind: .unavailable, weekdays: [2], startMinute: 22 * 60, endMinute: 6 * 60)
    }

    @Test func overnightRuleSplitsAcrossMidnight() {
        // Monday gets the evening tail [22:00, 24:00); Tuesday gets [00:00, 06:00).
        let mon = AvailabilityMerger.bands(on: monday, rules: [overnightMondayRule], windows: [], calendar: cal)
        #expect(mon.count == 1 && mon[0].startMinute == 1320 && mon[0].endMinute == 1440)
        let tue = AvailabilityMerger.bands(on: tuesday, rules: [overnightMondayRule], windows: [], calendar: cal)
        #expect(tue.count == 1 && tue[0].startMinute == 0 && tue[0].endMinute == 360)
    }

    @Test func overnightRuleFlagsNightShiftsNotDaytime() {
        let rule = overnightMondayRule
        let monNight = AvailabilityShift(id: "n", day: monday, startMinute: 23 * 60, endMinute: 24 * 60, isAllDay: false)
        let tueEarly = AvailabilityShift(id: "e", day: tuesday, startMinute: 0, endMinute: 5 * 60, isAllDay: false)
        let monDay = AvailabilityShift(id: "d", day: monday, startMinute: 12 * 60, endMinute: 16 * 60, isAllDay: false)
        let conflicts = AvailabilityMerger.conflictingShiftIDs(shifts: [monNight, tueEarly, monDay], rules: [rule], windows: [], calendar: cal)
        #expect(conflicts == ["n", "e"])
    }

    @Test func effectiveRangeBoundsAreInclusive() {
        let from = monday
        let to = monday.advanced(by: 7, in: cal) // the next Monday
        let rule = AvailabilityRuleSpec(id: "r", kind: .unavailable, weekdays: [2], startMinute: 0, endMinute: 720, effectiveFrom: from, effectiveTo: to)
        #expect(!AvailabilityMerger.bands(on: from, rules: [rule], windows: [], calendar: cal).isEmpty)   // on effectiveFrom
        #expect(!AvailabilityMerger.bands(on: to, rules: [rule], windows: [], calendar: cal).isEmpty)     // on effectiveTo (inclusive)
        let afterTo = to.advanced(by: 7, in: cal)
        #expect(AvailabilityMerger.bands(on: afterTo, rules: [rule], windows: [], calendar: cal).isEmpty) // past effectiveTo
    }
}

// MARK: - Snapshot + next-shift rule

@Suite struct SearchMatchTests {
    @Test func tokenAndCaseAndDiacriticInsensitive() {
        #expect(SearchMatch.matches("Morning Shift — Café", query: "cafe"))
        #expect(SearchMatch.matches("Morning Shift at Base 12", query: "base morning"))
        #expect(!SearchMatch.matches("Morning Shift", query: "morning night")) // AND
    }

    @Test func emptyQueryNeverMatches() {
        #expect(!SearchMatch.matches("anything", query: "   "))
        #expect(!SearchMatch.matches("anything", query: ""))
    }
}

@Suite struct SnapshotTests {
    private let cal = ukCal()

    @Test func nextRulePrefersStrictlyEarlierAllDay() {
        let now = date(2026, 6, 8, 9, 0, cal: cal) // Mon 09:00
        // All-day TODAY vs timed TOMORROW → all-day's civil day is earlier → all-day wins.
        let allDayToday = NextShiftRule.Candidate(id: "ad", isAllDay: true, start: nil, localDate: date(2026, 6, 8, 0, 0, cal: cal))
        let timedTomorrow = NextShiftRule.Candidate(id: "t", isAllDay: false, start: date(2026, 6, 9, 8, 0, cal: cal), localDate: nil)
        #expect(NextShiftRule.nextID(in: [timedTomorrow, allDayToday], now: now, calendar: cal) == "ad")
    }

    @Test func sameDayTimedBeatsAllDay() {
        let now = date(2026, 6, 8, 6, 0, cal: cal)
        let allDayToday = NextShiftRule.Candidate(id: "ad", isAllDay: true, start: nil, localDate: date(2026, 6, 8, 0, 0, cal: cal))
        let timedToday = NextShiftRule.Candidate(id: "t", isAllDay: false, start: date(2026, 6, 8, 8, 0, cal: cal), localDate: nil)
        #expect(NextShiftRule.nextID(in: [allDayToday, timedToday], now: now, calendar: cal) == "t")
    }

    @Test func pastTimedExcluded() {
        let now = date(2026, 6, 8, 12, 0, cal: cal)
        let past = NextShiftRule.Candidate(id: "p", isAllDay: false, start: date(2026, 6, 8, 8, 0, cal: cal), localDate: nil)
        let future = NextShiftRule.Candidate(id: "f", isAllDay: false, start: date(2026, 6, 8, 14, 0, cal: cal), localDate: nil)
        #expect(NextShiftRule.nextID(in: [past, future], now: now, calendar: cal) == "f")
    }

    @Test func emptyIsNil() {
        #expect(NextShiftRule.nextID(in: [], now: date(2026, 6, 8, cal: cal), calendar: cal) == nil)
    }

    @Test func builderFindsNextTodayAndCurrent() {
        let now = date(2026, 6, 8, 10, 0, cal: cal) // mid-shift
        let onNow = SnapshotInputShift(id: "now", title: "Morning", location: "Base", colorHex: nil,
                                       start: date(2026, 6, 8, 6, 30, cal: cal), end: date(2026, 6, 8, 13, 30, cal: cal),
                                       localDate: date(2026, 6, 8, 0, 0, cal: cal), isAllDay: false, paidHours: 7)
        let later = SnapshotInputShift(id: "later", title: "Late", location: nil, colorHex: nil,
                                       start: date(2026, 6, 9, 13, 30, cal: cal), end: date(2026, 6, 9, 22, 0, cal: cal),
                                       localDate: date(2026, 6, 9, 0, 0, cal: cal), isAllDay: false, paidHours: 8)
        let snap = HelmSnapshotBuilder.build(shifts: [onNow, later], now: now, calendar: cal)
        #expect(snap.current?.id == "now")
        #expect(snap.next?.id == "later")          // next FUTURE shift
        #expect(snap.today.map(\.id) == ["now"])
        #expect(snap.weekShiftCount == 2)
        #expect(abs(snap.weekHours - 15) < 0.001)  // 7 + 8
    }

    @Test func snapshotCodableRoundTrips() throws {
        let snap = HelmSnapshot(generatedAt: date(2026, 6, 8, 9, 0, cal: cal),
                                next: SnapshotShift(id: "x", title: "T", location: nil, colorHex: "FF0000", start: date(2026, 6, 9, 8, 0, cal: cal), end: nil, isAllDay: false),
                                today: [], weekHours: 12.5, weekShiftCount: 2, current: nil)
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(HelmSnapshot.self, from: data)
        #expect(back == snap)
    }
}
