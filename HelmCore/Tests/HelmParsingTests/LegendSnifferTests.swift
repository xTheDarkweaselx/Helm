//
//  LegendSnifferTests.swift
//  HelmParsingTests
//
//  v9 Auto-Learn Codes: sniffing a file's own legend/key block.
//

import Testing
import Foundation
@testable import HelmParsing
import HelmDomain

struct LegendSnifferTests {
    /// Build a one-sheet grid from rows of cell text ("" = empty cell).
    private func grid(_ rows: [[String]], name: String = "Sheet1") -> SpreadsheetGrid {
        var cells: [CellReference: RawCell] = [:]
        for (r, row) in rows.enumerated() {
            for (c, text) in row.enumerated() where !text.isEmpty {
                let ref = CellReference(column: c, row: r)
                cells[ref] = RawCell(reference: ref, text: text)
            }
        }
        return SpreadsheetGrid(sheets: [Sheet(name: name, cells: cells)])
    }

    @Test func sniffsCodeLabelTimeBlock() {
        let g = grid([
            ["Key"],                                  // sparse but no time → ignored
            ["E", "Early", "07:00-15:00"],
            ["L", "Late", "14:00-22:00"],
            ["N", "Night", "22:00-06:00"],
        ])
        let entries = LegendSniffer.sniff(grid: g)
        #expect(entries.map(\.code) == ["E", "L", "N"])
        let e = entries.first { $0.code == "E" }!
        #expect(e.times == InlineTimeRange(startMinuteOfDay: 7 * 60, endMinuteOfDay: 15 * 60))
        #expect(e.label == "Early")
        let n = entries.first { $0.code == "N" }!
        #expect(n.times == InlineTimeRange(startMinuteOfDay: 22 * 60, endMinuteOfDay: 6 * 60)) // overnight
    }

    @Test func sniffsCodeAndTimeWithoutSeparateLabel() {
        let entries = LegendSniffer.sniff(grid: grid([["LD", "08:00-20:00"]]))
        #expect(entries.count == 1)
        #expect(entries[0].code == "LD")
        #expect(entries[0].times == InlineTimeRange(startMinuteOfDay: 8 * 60, endMinuteOfDay: 20 * 60))
    }

    @Test func sniffsLabelAndTimeInOneCell() {
        let entries = LegendSniffer.sniff(grid: grid([["E", "Early 07:00-15:00"]]))
        #expect(entries.count == 1)
        #expect(entries[0].label == "Early")
        #expect(entries[0].times == InlineTimeRange(startMinuteOfDay: 7 * 60, endMinuteOfDay: 15 * 60))
    }

    @Test func ignoresFullRosterDataRows() {
        // A week-wide data row (8 cells) is not a legend row.
        let g = grid([["Mon 1", "M", "T", "W", "T", "F", "S", "S"]])
        #expect(LegendSniffer.sniff(grid: g).isEmpty)
    }

    @Test func ignoresOffAndTentativeCodes() {
        let g = grid([
            ["OFF", "Rest", "00:00-08:00"],
            ["TBC", "To confirm", "09:00-17:00"],
        ])
        // OFF/TBC are sentinels, never auto-learned as shift types.
        #expect(LegendSniffer.sniff(grid: g).isEmpty)
    }

    @Test func findsLegendOnASeparateSheet() {
        var cells: [CellReference: RawCell] = [:]
        let ref = CellReference(column: 0, row: 0)
        cells[ref] = RawCell(reference: ref, text: "Some roster data")
        let dataSheet = Sheet(name: "Roster", cells: cells)
        var keyCells: [CellReference: RawCell] = [:]
        for (c, t) in ["D", "Day", "09:00-17:00"].enumerated() {
            let r = CellReference(column: c, row: 0)
            keyCells[r] = RawCell(reference: r, text: t)
        }
        let keySheet = Sheet(name: "Key", cells: keyCells)
        let entries = LegendSniffer.sniff(grid: SpreadsheetGrid(sheets: [dataSheet, keySheet]))
        #expect(entries.map(\.code) == ["D"])
    }
}
