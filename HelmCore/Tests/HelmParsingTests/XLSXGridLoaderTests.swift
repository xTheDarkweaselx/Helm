//
//  XLSXGridLoaderTests.swift
//  HelmParsingTests
//
//  Integration: vendored CoreXLSX fork -> SpreadsheetGrid, against committed
//  synthetic .xlsx fixtures. Exercises the lenient SchemaType (the fixtures carry
//  Microsoft classificationlabels + sheetMetadata rels), date detection via the
//  style->numFmt chain, the General-0 "dateValue trap", leading-zero codes, and
//  the 1904 date system — then runs the full detect+interpret pipeline.
//

import Testing
import Foundation
import HelmDomain
@testable import HelmParsing

private let london = "Europe/London"

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "xlsx", subdirectory: "Fixtures"),
                           "missing fixture \(name).xlsx")
    return try Data(contentsOf: url)
}

private func cell(_ grid: SpreadsheetGrid, _ a1: String) -> RawCell? {
    grid.sheets.first?.cell(CellReference(a1: a1)!)
}

@Suite("XLSXGridLoader — sample-roster.xlsx (1900 system)")
struct XLSXSampleTests {
    private func grid() throws -> SpreadsheetGrid {
        try XLSXGridLoader.load(data: try fixture("sample-roster"), timeZoneIdentifier: london)
    }

    @Test("Parses despite classificationlabels + sheetMetadata relationships")
    func parsesRealWorldRels() throws {
        let g = try grid()
        #expect(g.sheets.count == 1)
        #expect(g.sheets.first?.name == "Sheet1")
    }

    @Test("A date cell resolves via the style→numFmt chain (not Cell.dateValue)")
    func dateCell() throws {
        let a2 = try #require(cell(try grid(), "A2"))
        #expect(a2.isDate)
        #expect(a2.text == "25/05/2026")
        #expect(a2.number == 46167)
    }

    @Test("The General-0 counter is NOT mistaken for a date (the dateValue trap)")
    func generalZeroNotDate() throws {
        let e2 = try #require(cell(try grid(), "E2"))
        #expect(!e2.isDate)
        #expect(e2.text == "0")
    }

    @Test("Header and string cells stay strings")
    func strings() throws {
        let g = try grid()
        #expect(cell(g, "A1")?.text == "DATE")
        #expect(cell(g, "A1")?.isDate == false)
        #expect(cell(g, "C2")?.text == "HMI Day 1")
    }

    @Test("Leading-zero shift code keeps its zeros")
    func leadingZeroCode() throws {
        #expect(cell(try grid(), "F5")?.text == "0900-1700")
        #expect(cell(try grid(), "F2")?.text == "M")
    }

    @Test("End-to-end: detect + interpret yields resolved shifts")
    func endToEnd() throws {
        let g = try grid()
        let sheet = try #require(g.sheets.first)
        let mapping = try #require(ListLayoutDetector.detect(sheet: sheet))
        #expect(mapping.dateColumn == 0)
        #expect(mapping.codeColumn == 5)
        #expect(mapping.titleColumn == 2)
        #expect(mapping.locationColumn == 3)

        let shifts = ListLayoutInterpreter.interpret(sheet: sheet, mapping: mapping, timeZoneIdentifier: london, dateOrder: .dayFirst)
        #expect(shifts.count == 4)
        #expect(shifts[0].normalizedCode == "M")
        #expect(shifts[0].dedupKeyInput == "2026-05-25|Europe/London|M")
        #expect(shifts[1].normalizedCode == "A")
        #expect(shifts[2].normalizedCode == "OFF")
        #expect(shifts[3].inlineTimes == InlineTimeRange(startMinuteOfDay: 540, endMinuteOfDay: 1020))
    }
}

@Suite("XLSXGridLoader — sample-1904.xlsx (1904 system)")
struct XLSX1904Tests {
    @Test("date1904 epoch shift is honoured")
    func date1904() throws {
        let g = try XLSXGridLoader.load(data: try fixture("sample-1904"), timeZoneIdentifier: london)
        let a2 = try #require(cell(g, "A2"))
        #expect(a2.isDate)
        #expect(a2.text == "25/05/2026") // serial 44705 in the 1904 system
    }
}
