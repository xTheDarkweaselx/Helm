//
//  ImportIntelligenceTests.swift
//  HelmDomainTests
//
//  v8.1 Smarter import: richer inline-time parsing, annotation/leave vocab,
//  and unknown-code time suggestions.
//

import Testing
import Foundation
@testable import HelmDomain

@Suite("InlineTimeRange — human formats")
struct InlineTimeRangeHumanTests {
    private func r(_ s: Int, _ e: Int) -> InlineTimeRange { InlineTimeRange(startMinuteOfDay: s, endMinuteOfDay: e) }

    @Test("Still parses the machine formats")
    func backwardCompatible() {
        #expect(InlineTimeRange.parse("0900-1700") == r(540, 1020))
        #expect(InlineTimeRange.parse("09:00-17:00") == r(540, 1020))
        #expect(InlineTimeRange.parse("0930 - 1500") == r(570, 900))
        #expect(InlineTimeRange.parse("2200–0600") == r(1320, 360)) // en dash, overnight
    }

    @Test("Parses am/pm meridiem")
    func meridiem() {
        #expect(InlineTimeRange.parse("9am-5pm") == r(540, 1020))
        #expect(InlineTimeRange.parse("9:30am-5:30pm") == r(570, 1050))
        #expect(InlineTimeRange.parse("9 AM - 5 PM") == r(540, 1020))
        #expect(InlineTimeRange.parse("12am-12pm") == r(0, 720))   // midnight → noon
        #expect(InlineTimeRange.parse("9am to 5pm") == r(540, 1020)) // 'to' separator
    }

    @Test("Parses dot separators")
    func dotSeparator() {
        #expect(InlineTimeRange.parse("9.30-15.00") == r(570, 900))
        #expect(InlineTimeRange.parse("09.00-17.00") == r(540, 1020))
    }

    @Test("Strips trailing notes")
    func trailingNotes() {
        #expect(InlineTimeRange.parse("0900-1700 (training)") == r(540, 1020))
        #expect(InlineTimeRange.parse("0900-1700*") == r(540, 1020))
        #expect(InlineTimeRange.parse("09:00-17:00 (TBC)") == r(540, 1020))
    }

    @Test("Rejects ambiguous bare-hour ranges rather than guessing")
    func ambiguousRejected() {
        #expect(InlineTimeRange.parse("9-5") == nil)   // could be 9→5am or 9→5pm
        #expect(InlineTimeRange.parse("9-17") == nil)  // bare hours, no minutes/meridiem
        #expect(InlineTimeRange.parse("M-A") == nil)
        #expect(InlineTimeRange.parse("M/A") == nil)   // '/' is not a range separator
        #expect(InlineTimeRange.parse("AM") == nil)
        #expect(InlineTimeRange.parse("2500-0600") == nil) // invalid hour
    }

    @Test("Rejects decimal-hours / 1-digit-minute notation (would silently mis-time)")
    func decimalHoursRejected() {
        // "8.5-16.5" is decimal hours (08:30–16:30), NOT 08:05–16:05 — must fall
        // through to the legend rather than write a confidently-wrong time.
        #expect(InlineTimeRange.parse("8.5-16.5") == nil)
        #expect(InlineTimeRange.parse("9.5-17.5") == nil)
        #expect(InlineTimeRange.parse("9:5-17:5") == nil)   // sloppy 1-digit minutes
        // But genuine zero-padded minutes still parse.
        #expect(InlineTimeRange.parse("9.30-15.00") == r(570, 900))
        #expect(InlineTimeRange.parse("09:05-17:05") == r(545, 1025))
    }
}

@Suite("ShiftCodeNormalizer — annotations, off, leave")
struct ShiftCodeVocabTests {
    @Test("Strips parenthetical / asterisk annotations only")
    func stripAnnotation() {
        #expect(ShiftCodeNormalizer.stripAnnotation("M (TRAINING)") == "M")
        #expect(ShiftCodeNormalizer.stripAnnotation("A*") == "A")
        #expect(ShiftCodeNormalizer.stripAnnotation("L †") == "L")
        #expect(ShiftCodeNormalizer.stripAnnotation("M/A") == "M/A") // composites untouched
        #expect(ShiftCodeNormalizer.stripAnnotation("OFF (covered)") == "OFF")
    }

    @Test("Expanded off / rest sentinels")
    func offVariants() {
        for c in ["OFF", "RDO", "REST DAY", "DAY OFF", "—", "NIL", "-"] {
            #expect(ShiftCodeNormalizer.isOff(c), "expected \(c) to be off")
        }
        #expect(!ShiftCodeNormalizer.isOff("M"))
        #expect(!ShiftCodeNormalizer.isOff("O")) // bare "O" is too ambiguous to mean off
        #expect(ShiftCodeNormalizer.isTentative("TBA"))
    }

    @Test("Leave/holiday codes map to a label (exact + stripped)")
    func leaveLabels() {
        #expect(ShiftCodeNormalizer.leaveLabel("A/L") == "Annual leave")
        #expect(ShiftCodeNormalizer.leaveLabel("SICK") == "Sick")
        #expect(ShiftCodeNormalizer.leaveLabel("B/H") == "Bank holiday")
        #expect(ShiftCodeNormalizer.leaveLabel("AL (booked)") == "Annual leave") // via strip
        #expect(ShiftCodeNormalizer.leaveLabel("M") == nil)
    }
}

@Suite("UnknownCodeSuggester")
struct UnknownCodeSuggesterTests {
    private var legend: MergedLegend { LegendMerger.merge(globalTypes: [], learned: []) } // builtin M/A

    @Test("Common starter code → its typical hours, medium confidence")
    func starterCode() {
        let s = UnknownCodeSuggester.suggest(for: "N", legend: legend)
        #expect(s.startMinute == 22 * 60 && s.endMinute == 6 * 60 + 1440) // overnight night
        #expect(s.label == "Night" && s.confidence == .medium)
    }

    @Test("Composite of known parts → spanning range, high confidence")
    func compositeSpan() {
        let s = UnknownCodeSuggester.suggest(for: "E/L", legend: legend) // E 06–14, L 14–22 (starter)
        #expect(s.startMinute == 6 * 60 && s.endMinute == 22 * 60)
        #expect(s.confidence == .high && s.label == "E + L")
    }

    @Test("Composite using the real legend's M and A")
    func compositeFromLegend() {
        let s = UnknownCodeSuggester.suggest(for: "M/A", legend: legend) // M 06:30–13:30, A 13:30–22:00
        #expect(s.startMinute == 6 * 60 + 30 && s.endMinute == 22 * 60)
        #expect(s.confidence == .high)
    }

    @Test("Semantic hint for an unrecognised but suggestive code")
    func semanticHint() {
        let s = UnknownCodeSuggester.suggest(for: "NIGHTS", legend: legend)
        #expect(s.startMinute == 22 * 60 && s.label == "Night" && s.confidence == .low)
    }

    @Test("Truly unknown code → flagged 9–5 default")
    func fallback() {
        let s = UnknownCodeSuggester.suggest(for: "XQZ", legend: legend)
        #expect(s.startMinute == 9 * 60 && s.endMinute == 17 * 60)
        #expect(s.confidence == .low && s.label == nil)
    }

    @Test("AM maps to morning, not afternoon (prefix-match inversion fixed)")
    func amIsMorning() {
        let s = UnknownCodeSuggester.suggest(for: "AM", legend: legend)
        #expect(s.label == "Morning" && s.startMinute == 6 * 60 + 30)
    }

    @Test("Codes that merely start with a hint letter no longer mis-fire")
    func noPrefixMisfire() {
        for code in ["EXTRA", "ADMIN", "ANNUAL", "MEETING"] {
            let s = UnknownCodeSuggester.suggest(for: code, legend: legend)
            #expect(s.confidence == .low && s.startMinute == 9 * 60, "‘\(code)’ should fall to the 9–5 default")
        }
    }

    @Test("Early + night composite does NOT yield a confident 24-hour shift")
    func earlyNightNotConfident24h() {
        let s = UnknownCodeSuggester.suggest(for: "E/N", legend: legend)
        #expect(s.confidence != .high)
        #expect(s.endMinute - s.startMinute <= 16 * 60) // not a 24h block
    }
}
