//
//  ICSExporterTests.swift
//  HelmCalendarTests
//

import Testing
import Foundation
@testable import HelmCalendar

@Suite("ICSExporter")
struct ICSExporterTests {
    private let stamp = Date(timeIntervalSince1970: 1_780_000_000) // 2026-05-28T...Z

    private func draft(
        key: String = "2026-06-15|Europe/London|M",
        title: String = "HMI Day 2",
        location: String? = "D2",
        start: Date = Date(timeIntervalSince1970: 1_781_000_000),
        end: Date = Date(timeIntervalSince1970: 1_781_025_200),
        alarms: [Int] = []
    ) -> CalendarEventDraft {
        CalendarEventDraft(dedupKey: key, title: title, location: location,
                           start: start, end: end, timeZoneIdentifier: "Europe/London",
                           alarmOffsetsMinutes: alarms, contentHash: "h")
    }

    @Test("Produces a well-formed VCALENDAR/VEVENT with CRLF and UTC times")
    func wellFormed() {
        let ics = ICSExporter.export([draft()], calendarName: "Helm Shifts", generatedAt: stamp)
        #expect(ics.hasPrefix("BEGIN:VCALENDAR\r\n"))
        #expect(ics.hasSuffix("END:VCALENDAR\r\n"))
        #expect(ics.contains("\r\nVERSION:2.0\r\n"))
        #expect(ics.contains("\r\nBEGIN:VEVENT\r\n"))
        #expect(ics.contains("\r\nUID:2026-06-15-Europe-London-M@helm.fusion-studios\r\n"))
        #expect(ics.contains("\r\nSUMMARY:HMI Day 2\r\n"))
        #expect(ics.contains("\r\nLOCATION:D2\r\n"))
        #expect(ics.contains("\r\nDTSTART:")) // UTC form
        #expect(ics.contains("Z\r\n"))        // …Z time
    }

    @Test("Escapes TEXT special characters")
    func escaping() {
        let ics = ICSExporter.export([draft(title: "Late, swap; note\\x", location: "A,B")],
                                     calendarName: "X", generatedAt: stamp)
        #expect(ics.contains("SUMMARY:Late\\, swap\\; note\\\\x"))
        #expect(ics.contains("LOCATION:A\\,B"))
    }

    @Test("VALARM trigger formats")
    func alarms() {
        #expect(ICSExporter.trigger(minutesBefore: 60) == "-PT1H")
        #expect(ICSExporter.trigger(minutesBefore: 90) == "-PT1H30M")
        #expect(ICSExporter.trigger(minutesBefore: 30) == "-PT30M")
        #expect(ICSExporter.trigger(minutesBefore: 0) == "PT0S")
        let ics = ICSExporter.export([draft(alarms: [60])], calendarName: "X", generatedAt: stamp)
        #expect(ics.contains("BEGIN:VALARM\r\nACTION:DISPLAY"))
        #expect(ics.contains("TRIGGER:-PT1H"))
    }

    @Test("Folds long lines at 75 octets with a leading space")
    func folding() {
        let long = String(repeating: "A", count: 200)
        let ics = ICSExporter.export([draft(title: long)], calendarName: "X", generatedAt: stamp)
        for line in ics.components(separatedBy: "\r\n") {
            #expect(line.utf8.count <= 75)
        }
        // Unfolding (remove CRLF+space) restores the summary.
        let unfolded = ics.replacingOccurrences(of: "\r\n ", with: "")
        #expect(unfolded.contains("SUMMARY:" + long))
    }

    @Test("Multibyte characters are not split across a fold boundary")
    func multibyteFold() {
        let ics = ICSExporter.export([draft(title: String(repeating: "é", count: 60))],
                                     calendarName: "X", generatedAt: stamp)
        // If a fold split a 2-byte é, decoding would have produced U+FFFD.
        #expect(!ics.contains("\u{FFFD}"))
    }
}
