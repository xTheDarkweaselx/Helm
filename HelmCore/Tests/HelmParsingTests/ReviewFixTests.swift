//
//  ReviewFixTests.swift
//  HelmParsingTests
//
//  Regression tests for issues found by the v1.0 adversarial review.
//

import Testing
import Foundation
import HelmDomain
@testable import HelmParsing

private let london = "Europe/London"

@Suite("Review fixes — date resolver hardening")
struct DateResolverHardeningTests {
    @Test("Out-of-range / non-finite serials return nil instead of trapping")
    func serialBounds() {
        for bad in [Double.infinity, -.infinity, .nan, 1e300, -1e300, 1e18] {
            #expect(HelmDateResolver.date(serial: bad, date1904: false, dateOnly: true, timeZoneIdentifier: london) == nil)
        }
        // A valid serial still resolves.
        #expect(HelmDateResolver.date(serial: 46167, date1904: false, dateOnly: true, timeZoneIdentifier: london) != nil)
    }

    @Test("'General' and realistic number/text codes are NOT dates")
    func generalNotDate() {
        // 'General' contains no d/m/y/h/s — previously misclassified because a bare
        // 'a' was wrongly treated as an AM/PM marker.
        #expect(!HelmDateResolver.isDateFormat(numFmtId: 165, customFormatCode: "General"))
        #expect(!HelmDateResolver.isDateFormat(numFmtId: 166, customFormatCode: "#,##0.00"))
        #expect(!HelmDateResolver.isDateFormat(numFmtId: 167, customFormatCode: "0.0%"))
        #expect(!HelmDateResolver.isDateFormat(numFmtId: 168, customFormatCode: "@"))
        #expect(!HelmDateResolver.isDateFormat(numFmtId: 169, customFormatCode: "$#,##0"))
        // A quoted 'd' literal is still ignored.
        #expect(!HelmDateResolver.isDateFormat(numFmtId: 170, customFormatCode: "0\" days\""))
    }

    @Test("Genuine AM/PM time formats are still detected")
    func amPmStillDetected() {
        let r = HelmDateResolver.formatCodeIsDateTime("h:mm AM/PM")
        #expect(r.isDate)
        #expect(r.hasTime)
    }
}

@Suite("Review fixes — dedup key")
struct DedupKeyTests {
    @Test("Inline-time shifts are keyed by their times, not collapsed to date|tz|")
    func inlineKeyed() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: london)!
        let date = cal.date(from: DateComponents(year: 2026, month: 6, day: 26, hour: 12))!
        let a = ParsedShift(localDate: date, timeZoneIdentifier: london, normalizedCode: "",
                            inlineTimes: InlineTimeRange(startMinuteOfDay: 540, endMinuteOfDay: 1020))
        let b = ParsedShift(localDate: date, timeZoneIdentifier: london, normalizedCode: "",
                            inlineTimes: InlineTimeRange(startMinuteOfDay: 570, endMinuteOfDay: 900))
        #expect(a.dedupKeyInput == "2026-06-26|Europe/London|540-1020")
        #expect(a.dedupKeyInput != b.dedupKeyInput) // two inline shifts same day don't collide
    }
}

@Suite("Review fixes — messy .xlsx (rich text, omitted count, col w/o width, General custom)")
struct MessyXLSXTests {
    private func grid() throws -> SpreadsheetGrid {
        let url = try #require(Bundle.module.url(forResource: "sample-messy", withExtension: "xlsx", subdirectory: "Fixtures"))
        return try XLSXGridLoader.load(data: try Data(contentsOf: url), timeZoneIdentifier: london)
    }

    @Test("Parses despite omitted count attrs, a width-less <col>, mru-only <colors>, and no sheetId")
    func parses() throws {
        let g = try grid()
        #expect(g.sheets.first?.name == "Messy")
    }

    @Test("Rich-text shared string is concatenated, not dropped")
    func richText() throws {
        let c2 = try #require(try grid().sheets.first?.cell(CellReference(a1: "C2")!))
        #expect(c2.text == "Part1 Part2")
    }

    @Test("A 'General' custom-format numeric is NOT a date")
    func generalNumeric() throws {
        let d2 = try #require(try grid().sheets.first?.cell(CellReference(a1: "D2")!))
        #expect(!d2.isDate)
        #expect(d2.text == "5")
    }

    @Test("Date cell still resolves and the roster interprets")
    func dateAndInterpret() throws {
        let sheet = try #require(try grid().sheets.first)
        #expect(sheet.cell(CellReference(a1: "A2")!)?.text == "25/05/2026")
        let mapping = try #require(ListLayoutDetector.detect(sheet: sheet))
        let shifts = ListLayoutInterpreter.interpret(sheet: sheet, mapping: mapping, timeZoneIdentifier: london, dateOrder: .dayFirst)
        #expect(shifts.count == 1)
        #expect(shifts.first?.normalizedCode == "M")
    }
}
