//
//  ListLayoutInterpreter.swift
//  HelmParsing
//
//  Turns a list-layout sheet (one row per day, dates down a column) into
//  [ParsedShift]. This is the interpreter for the first real sample format
//  (Fixtures/Rosters/README.md). Matrix layout is a separate interpreter (v1.0).
//

import Foundation
import HelmDomain

/// Which columns hold what, plus how many header rows to skip. Columns are 0-based.
public struct ListColumnMapping: Sendable, Equatable {
    public var dateColumn: Int
    public var codeColumn: Int
    public var titleColumn: Int?
    public var locationColumn: Int?
    public var headerRowCount: Int

    public init(dateColumn: Int, codeColumn: Int, titleColumn: Int? = nil, locationColumn: Int? = nil, headerRowCount: Int = 1) {
        self.dateColumn = dateColumn
        self.codeColumn = codeColumn
        self.titleColumn = titleColumn
        self.locationColumn = locationColumn
        self.headerRowCount = headerRowCount
    }
}

public enum ListLayoutInterpreter {

    /// Values that mean "no meaningful content" in a title/location cell.
    private static let blankSentinels: Set<String> = ["-", "0", "", "TBC", "N/A"]

    public static func interpret(
        sheet: Sheet,
        mapping: ListColumnMapping,
        timeZoneIdentifier: String,
        dateOrder: RosterDateParser.Order = .dayFirst
    ) -> [ParsedShift] {
        var shifts: [ParsedShift] = []
        let lastRow = sheet.rowCount - 1
        guard lastRow >= mapping.headerRowCount else { return shifts }

        for row in mapping.headerRowCount...lastRow {
            guard let dateCell = sheet.cell(CellReference(column: mapping.dateColumn, row: row)),
                  let date = RosterDateParser.parse(dateCell.text, order: dateOrder, timeZoneIdentifier: timeZoneIdentifier)
            else { continue } // no parseable date → not a day row

            let codeText = sheet.cell(CellReference(column: mapping.codeColumn, row: row))?.text ?? ""

            let inlineTimes = InlineTimeRange.parse(codeText)
            let normalizedCode = inlineTimes == nil ? ShiftCodeNormalizer.normalize(codeText) : ""

            shifts.append(ParsedShift(
                localDate: date,
                timeZoneIdentifier: timeZoneIdentifier,
                normalizedCode: normalizedCode,
                inlineTimes: inlineTimes,
                title: cleanText(mapping.titleColumn, row: row, sheet: sheet),
                location: cleanText(mapping.locationColumn, row: row, sheet: sheet),
                sourceRow: row
            ))
        }
        return shifts
    }

    private static func cleanText(_ column: Int?, row: Int, sheet: Sheet) -> String? {
        guard let column, let text = sheet.cell(CellReference(column: column, row: row))?.text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if blankSentinels.contains(trimmed.uppercased()) { return nil }
        return trimmed.isEmpty ? nil : trimmed
    }
}
