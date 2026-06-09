//
//  ScheduleExpanderTests.swift
//  HelmDomainTests
//

import Testing
import Foundation
@testable import HelmDomain

private let london = "Europe/London"
private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: london)!
    return cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
}
private let M = ShiftTypeSpec(id: "M", code: "M", label: "Morning", startMinuteOfDay: 390, endMinuteOfDay: 810, workKindRaw: "worked")
private let A = ShiftTypeSpec(id: "A", code: "A", label: "Afternoon", startMinuteOfDay: 810, endMinuteOfDay: 1320, workKindRaw: "worked")
private let scope = "sched1234extra" // prefix(8) = "sched123"

private func cyclic(_ slots: [SlotSpec], from: Date, to: Date, anchor: Date, len: Int, sortIndex: Int = 1, tz: String? = nil, loc: String? = nil) -> SegmentSpec {
    SegmentSpec(sortIndex: sortIndex, isExplicit: false, effectiveFrom: from, effectiveTo: to,
                timeZoneIdentifier: tz, locationName: loc, anchorDate: anchor, cycleLengthDays: len, slots: slots)
}

@Suite("ScheduleExpander")
struct ScheduleExpanderTests {
    // A 4-day cycle M,M,A,OFF anchored 1 Jun 2026.
    private func baseSpec() -> ScheduleSpec {
        let slots = [SlotSpec(sortIndex: 0, shiftType: M), SlotSpec(sortIndex: 1, shiftType: M),
                     SlotSpec(sortIndex: 2, shiftType: A), SlotSpec(sortIndex: 3, isOff: true)]
        let seg = cyclic(slots, from: day(2026, 6, 1), to: day(2026, 6, 30), anchor: day(2026, 6, 1), len: 4)
        return ScheduleSpec(scope: scope, defaultTimeZoneIdentifier: london, segments: [seg])
    }

    @Test("Cycle expands with namespaced keys; OFF slots are non-writable")
    func basicCycle() {
        let days = ScheduleExpander.expand(baseSpec(), horizon: day(2026, 6, 1)...day(2026, 6, 8))
        #expect(days.count == 8)
        #expect(days.filter(\.isWritable).count == 6) // OFF on the 4th and 8th
        #expect(days[0].code == "g:sched123:M")
        #expect(days[0].dedupKey == "2026-06-01|Europe/London|g:sched123:M")
        #expect(days[2].code == "g:sched123:A")
        #expect(days[3].isWritable == false) // OFF
    }

    @Test("Generated keys are disjoint from imported keys (no g: prefix collision)")
    func namespacedDisjoint() {
        let gen = ScheduleExpander.expand(baseSpec(), horizon: day(2026, 6, 1)...day(2026, 6, 1))[0]
        let imported = ParsedShift(localDate: day(2026, 6, 1), timeZoneIdentifier: london, normalizedCode: "M").dedupKeyInput
        #expect(gen.dedupKey != imported)
        #expect(gen.dedupKey.contains("|g:"))
        #expect(!imported.contains("|g:"))
    }

    @Test("Re-expanding the same spec/horizon is identical (deterministic)")
    func deterministic() {
        let a = ScheduleExpander.expand(baseSpec(), horizon: day(2026, 6, 1)...day(2026, 6, 30))
        let b = ScheduleExpander.expand(baseSpec(), horizon: day(2026, 6, 1)...day(2026, 6, 30))
        #expect(a == b)
    }

    @Test("Morning shift resolves to 06:30 local even on the spring-forward day")
    func dstStableStart() throws {
        let seg = cyclic([SlotSpec(sortIndex: 0, shiftType: M)], from: day(2026, 3, 23), to: day(2026, 4, 5),
                         anchor: day(2026, 3, 23), len: 1)
        let spec = ScheduleSpec(scope: scope, defaultTimeZoneIdentifier: london, segments: [seg])
        let days = ScheduleExpander.expand(spec, horizon: day(2026, 3, 29)...day(2026, 3, 29))
        let start = try #require(days.first?.start)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: london)!
        #expect(cal.component(.hour, from: start) == 6)
        #expect(cal.component(.minute, from: start) == 30)
        // cyclePosition: 23 Mar -> 29 Mar = 6 days, length 1 -> 0
        #expect(ScheduleExpander.cyclePosition(anchor: day(2026, 3, 23), day: day(2026, 3, 29), dayOffset: 0, cycleLength: 1, tz: TimeZone(identifier: london)!) == 0)
    }

    @Test("Overlapping segments — higher sortIndex wins")
    func overlapPrecedence() {
        let low = cyclic([SlotSpec(sortIndex: 0, shiftType: M)], from: day(2026, 6, 1), to: day(2026, 6, 30), anchor: day(2026, 6, 1), len: 1, sortIndex: 1)
        let high = cyclic([SlotSpec(sortIndex: 0, shiftType: A)], from: day(2026, 6, 1), to: day(2026, 6, 30), anchor: day(2026, 6, 1), len: 1, sortIndex: 2)
        let spec = ScheduleSpec(scope: scope, defaultTimeZoneIdentifier: london, segments: [low, high])
        let d1 = ScheduleExpander.expand(spec, horizon: day(2026, 6, 10)...day(2026, 6, 10))[0]
        #expect(d1.code == "g:sched123:A")
    }

    @Test("Days outside any segment emit nothing (gap)")
    func gap() {
        let days = ScheduleExpander.expand(baseSpec(), horizon: day(2026, 5, 25)...day(2026, 5, 31))
        #expect(days.isEmpty) // segment starts 1 Jun
    }

    @Test("Exception: cancelled makes the day OFF; added emits on a gap day")
    func exceptions() {
        var spec = baseSpec()
        spec = ScheduleSpec(scope: scope, defaultTimeZoneIdentifier: london, segments: spec.segments, exceptions: [
            ExceptionSpec(localDate: day(2026, 6, 1), kindRaw: "cancelled"),                 // 1 Jun was M
            ExceptionSpec(localDate: day(2026, 5, 30), kindRaw: "added", shiftType: A),       // 30 May is a gap day
        ])
        let days = ScheduleExpander.expand(spec, horizon: day(2026, 5, 29)...day(2026, 6, 2))
        let jun1 = days.first { $0.dedupKey.hasPrefix("2026-06-01") }
        #expect(jun1?.isWritable == false) // cancelled
        let may30 = days.first { $0.dedupKey.hasPrefix("2026-05-30") }
        #expect(may30?.isWritable == true && may30?.code == "g:sched123:A") // added on a gap day
    }

    @Test("Explicit segment with inline times + OFF days")
    func explicitSegment() {
        let ed = [
            ExplicitDaySpec(localDate: day(2026, 7, 1), inlineStartMinute: 540, inlineEndMinute: 1020, title: "Course"),
            ExplicitDaySpec(localDate: day(2026, 7, 2), isOff: true),
        ]
        let seg = SegmentSpec(sortIndex: 0, isExplicit: true, effectiveFrom: day(2026, 7, 1), effectiveTo: day(2026, 7, 3), explicitDays: ed)
        let spec = ScheduleSpec(scope: scope, defaultTimeZoneIdentifier: london, segments: [seg])
        let days = ScheduleExpander.expand(spec, horizon: day(2026, 7, 1)...day(2026, 7, 3))
        #expect(days.count == 2) // 1 Jul (inline) + 2 Jul (off); 3 Jul has no entry → gap
        let d1 = days.first { $0.dedupKey.hasPrefix("2026-07-01") }
        #expect(d1?.isWritable == true)
        #expect(d1?.code == "g:sched123:inline:540-1020")
        #expect(days.first { $0.dedupKey.hasPrefix("2026-07-02") }?.isWritable == false)
    }
}
