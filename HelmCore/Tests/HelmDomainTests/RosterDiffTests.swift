//
//  RosterDiffTests.swift
//  HelmDomainTests
//

import Testing
import Foundation
@testable import HelmDomain

@Suite("RosterDiffer")
struct RosterDifferTests {
    @Test("First import: everything is added")
    func firstImport() {
        let diff = RosterDiffer.diff(existing: [:], incoming: ["a": "h1", "b": "h2"])
        #expect(diff.added == ["a", "b"])
        #expect(diff.updated.isEmpty && diff.removed.isEmpty && diff.unchanged.isEmpty)
        #expect(diff.hasChanges)
    }

    @Test("Re-import of an identical roster: all unchanged, no changes")
    func identicalReimport() {
        let existing = ["a": ExistingShift(contentHash: "h1", isUserAuthored: false),
                        "b": ExistingShift(contentHash: "h2", isUserAuthored: false)]
        let diff = RosterDiffer.diff(existing: existing, incoming: ["a": "h1", "b": "h2"])
        #expect(diff.unchanged == ["a", "b"])
        #expect(!diff.hasChanges)
    }

    @Test("Classifies add / update / remove together")
    func mixed() {
        let existing = ["keep": ExistingShift(contentHash: "h", isUserAuthored: false),
                        "change": ExistingShift(contentHash: "old", isUserAuthored: false),
                        "gone": ExistingShift(contentHash: "h", isUserAuthored: false)]
        let diff = RosterDiffer.diff(existing: existing, incoming: ["keep": "h", "change": "new", "fresh": "h"])
        #expect(diff.added == ["fresh"])
        #expect(diff.updated == ["change"])
        #expect(diff.removed == ["gone"])
        #expect(diff.unchanged == ["keep"])
    }

    @Test("User-authored instances are never updated or removed")
    func preservesUserEdits() {
        let existing = ["edited": ExistingShift(contentHash: "old", isUserAuthored: true),
                        "userAdded": ExistingShift(contentHash: "x", isUserAuthored: true)]
        // 'edited' has a changed incoming hash; 'userAdded' is absent from the import.
        let diff = RosterDiffer.diff(existing: existing, incoming: ["edited": "new"])
        #expect(diff.updated.isEmpty)
        #expect(diff.removed.isEmpty)
        #expect(diff.unchanged.sorted() == ["edited", "userAdded"])
    }
}

@Suite("ShiftContentHash")
struct ShiftContentHashTests {
    private let tz = "Europe/London"
    private let start = Date(timeIntervalSince1970: 1_780_000_000)
    private let end = Date(timeIntervalSince1970: 1_780_025_200)

    @Test("Deterministic for identical content")
    func deterministic() {
        let a = ShiftContentHash.make(title: "M", startUTC: start, endUTC: end, location: "D2", timeZoneIdentifier: tz)
        let b = ShiftContentHash.make(title: "M", startUTC: start, endUTC: end, location: "D2", timeZoneIdentifier: tz)
        #expect(a == b)
    }

    @Test("Sensitive to each field")
    func sensitive() {
        let base = ShiftContentHash.make(title: "M", startUTC: start, endUTC: end, location: "D2", timeZoneIdentifier: tz)
        #expect(base != ShiftContentHash.make(title: "A", startUTC: start, endUTC: end, location: "D2", timeZoneIdentifier: tz))
        #expect(base != ShiftContentHash.make(title: "M", startUTC: end, endUTC: end, location: "D2", timeZoneIdentifier: tz))
        #expect(base != ShiftContentHash.make(title: "M", startUTC: start, endUTC: end, location: "PTT", timeZoneIdentifier: tz))
        #expect(base != ShiftContentHash.make(title: "M", startUTC: start, endUTC: end, location: "D2", timeZoneIdentifier: "UTC"))
        #expect(base != ShiftContentHash.make(title: "M", startUTC: start, endUTC: end, location: "D2", timeZoneIdentifier: tz, alarmOffsetsMinutes: [60]))
    }
}
