//
//  HelmDataExportTests.swift
//  HelmDomainTests
//
//  v8.2 GDPR data export: the portable JSON document encodes stably and round-trips.
//

import Testing
import Foundation
@testable import HelmDomain

struct HelmDataExportTests {
    private func sample() -> HelmDataExport {
        // Fractional seconds on purpose: real timestamps are sub-second, so this
        // guards the round-trip against the whole-second .iso8601 truncation.
        let when = Date(timeIntervalSince1970: 1_780_000_000.527)
        let type = ExportedShiftType(code: "M", label: "Morning", startMinuteOfDay: 390,
                                     endMinuteOfDay: 810, endDayOffset: 0, breakMinutes: 30,
                                     paid: true, paidHoursOverride: 6.5, workKind: "worked",
                                     colorHex: "2E7D5B", location: "D2", tags: ["Senior"])
        let shift = ExportedShift(date: when, start: when, end: when.addingTimeInterval(7 * 3600),
                                  isAllDay: false, timeZone: "Europe/London", paidHours: 7,
                                  shiftCode: "M", title: "HMI Day 1", location: "D2", note: nil)
        let roster = ExportedRoster(title: "June", createdAt: when, reminderOffsetsMinutes: [60], shifts: [shift])
        return HelmDataExport(exportedAt: when, app: "Helm 8.2",
                              shiftTypes: [type], rosters: [roster],
                              settings: ExportedSettings(hourlyRate: 15, taxYearPreset: "uk"))
    }

    @Test func encodesAndRoundTrips() throws {
        let export = sample()
        let data = try export.jsonData()
        let back = try HelmDataExport.decode(from: data)
        #expect(back == export) // every DTO is Equatable, incl. fractional-second dates
        #expect(back.exportedAt == export.exportedAt) // not truncated to whole seconds
        #expect(back.schemaVersion == HelmDataExport.currentSchemaVersion)
    }

    @Test func jsonIsStableAndReadable() throws {
        let export = sample()
        let a = try export.jsonString()
        let b = try export.jsonString()
        #expect(a == b) // sorted keys → byte-identical
        #expect(a.contains("\"schemaVersion\""))
        #expect(a.contains("\"shiftCode\" : \"M\""))
        #expect(a.contains("2026")) // ISO-8601 date, not a raw timestamp
        #expect(!a.contains("\\/")) // slashes not escaped
    }

    @Test func itemSummaryCountsShifts() {
        #expect(sample().itemSummary == "1 roster (1 shift) · 1 shift type")
        let empty = HelmDataExport(exportedAt: Date(timeIntervalSince1970: 0), app: "Helm")
        #expect(empty.itemSummary == "No data yet")
    }

    // A legitimately-empty store must still produce a REAL, valid file — not the
    // empty string the old `try?`-swallowing path silently saved.
    @Test func emptyStoreEncodesToRealFile() throws {
        let empty = HelmDataExport(exportedAt: Date(timeIntervalSince1970: 0), app: "Helm")
        let json = try empty.jsonString()
        #expect(!json.isEmpty)
        #expect(json.contains("\"schemaVersion\""))
        let back = try HelmDataExport.decode(from: Data(json.utf8))
        #expect(back == empty) // round-trips, so an empty store is distinguishable from a failure
    }

    // A stray non-finite Double (a corrupt paid-hours/rate) must NOT make encode
    // throw — that throw was what the old `try?` turned into a 0-byte file.
    @Test func nonFiniteDoublesDoNotBreakEncode() throws {
        let export = HelmDataExport(
            exportedAt: Date(timeIntervalSince1970: 0), app: "Helm",
            settings: ExportedSettings(hourlyRate: .nan, overtimeMultiplier: .infinity))
        let data = try export.jsonData() // does not throw
        #expect(!data.isEmpty)
        let back = try HelmDataExport.decode(from: data) // round-trips without throwing
        #expect(back.settings.hourlyRate?.isNaN == true)
        #expect(back.settings.overtimeMultiplier == .infinity)
    }
}
