//
//  SpreadsheetGridTests.swift
//  HelmParsingTests
//

import Testing
import Foundation
@testable import HelmParsing

@Suite("CellReference A1 conversion")
struct CellReferenceTests {
    @Test("Index → A1")
    func toA1() {
        #expect(CellReference(column: 0, row: 0).a1 == "A1")
        #expect(CellReference(column: 5, row: 0).a1 == "F1")   // the SHIFT column in sample #1
        #expect(CellReference(column: 25, row: 0).a1 == "Z1")
        #expect(CellReference(column: 26, row: 0).a1 == "AA1")
        #expect(CellReference(column: 1, row: 2).a1 == "B3")
    }

    @Test("A1 → index round-trips")
    func fromA1() {
        #expect(CellReference(a1: "A1") == CellReference(column: 0, row: 0))
        #expect(CellReference(a1: "F1") == CellReference(column: 5, row: 0))
        #expect(CellReference(a1: "AA1") == CellReference(column: 26, row: 0))
        #expect(CellReference(a1: "B3") == CellReference(column: 1, row: 2))
        #expect(CellReference(a1: "nonsense") == nil)
        #expect(CellReference(a1: "A0") == nil) // rows are 1-based
    }

    @Test("Column letters")
    func columnLetters() {
        #expect(CellReference.columnLetters(0) == "A")
        #expect(CellReference.columnLetters(25) == "Z")
        #expect(CellReference.columnLetters(26) == "AA")
        #expect(CellReference.columnLetters(701) == "ZZ")
    }
}

@Suite("Sheet")
struct SheetTests {
    private func makeSheet() -> Sheet {
        // A tiny list-layout sheet resembling sample #1: header row + two day rows.
        var cells: [CellReference: RawCell] = [:]
        func put(_ a1: String, _ text: String) {
            let ref = CellReference(a1: a1)!
            cells[ref] = RawCell(reference: ref, text: text)
        }
        put("A1", "DATE"); put("F1", "SHIFT")
        put("A2", "14/06/2026"); put("C2", "HMI Day 1"); put("F2", "M")
        put("A3", "17/06/2026"); put("C3", "HMI Day 4"); put("F3", "A")
        return Sheet(name: "Sheet1", cells: cells)
    }

    @Test("Reports dimensions from sparse cells")
    func dimensions() {
        let sheet = makeSheet()
        #expect(sheet.rowCount == 3)
        #expect(sheet.columnCount == 6) // through column F
    }

    @Test("Row and column access is sorted")
    func access() {
        let sheet = makeSheet()
        let header = sheet.row(0).map(\.text)
        #expect(header == ["DATE", "SHIFT"])
        let shiftColumn = sheet.column(5).map(\.text)
        #expect(shiftColumn == ["SHIFT", "M", "A"])
        #expect(sheet.cell(CellReference(a1: "C2")!)?.text == "HMI Day 1")
    }
}
