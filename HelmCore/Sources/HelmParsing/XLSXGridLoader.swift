//
//  XLSXGridLoader.swift
//  HelmParsing
//
//  Adapts the vendored CoreXLSX fork into Helm's normalized SpreadsheetGrid, so
//  the SAME ListLayoutDetector / ListLayoutInterpreter pipeline the CSV path uses
//  works for .xlsx (DEVELOPMENT_PLAN.md ADR-7, Phase v1.0). Date-ness is decided
//  via the cell's style -> numFmt chain and HelmDateResolver — never CoreXLSX's
//  Cell.dateValue. Run off the main actor: XLSXFile is a non-Sendable class; only
//  the Sendable SpreadsheetGrid escapes.
//

import Foundation
import CoreXLSX

public enum XLSXGridLoader {
    public enum LoadError: Error, Equatable {
        case notReadable
        case noWorkbook
    }

    /// Load from in-memory file data (preferred from the app: read the
    /// security-scoped URL into Data, then call this).
    public static func load(data: Data, timeZoneIdentifier: String) throws -> SpreadsheetGrid {
        let file: XLSXFile
        do { file = try XLSXFile(data: data) } catch { throw LoadError.notReadable }
        return try build(from: file, timeZoneIdentifier: timeZoneIdentifier)
    }

    /// Load from a filesystem path.
    public static func load(filePath: String, timeZoneIdentifier: String) throws -> SpreadsheetGrid {
        guard let file = XLSXFile(filepath: filePath) else { throw LoadError.notReadable }
        return try build(from: file, timeZoneIdentifier: timeZoneIdentifier)
    }

    // MARK: - Core

    private static func build(from file: XLSXFile, timeZoneIdentifier tz: String) throws -> SpreadsheetGrid {
        guard let workbook = try file.parseWorkbooks().first else { throw LoadError.noWorkbook }
        let date1904 = workbook.date1904
        let styles = try file.parseStyles()
        let shared = try file.parseSharedStrings()
        let pathsAndNames = try file.parseWorksheetPathsAndNames(workbook: workbook)

        var sheets: [Sheet] = []
        for (name, path) in pathsAndNames {
            let worksheet = try file.parseWorksheet(at: path)
            var cells: [HelmParsing.CellReference: RawCell] = [:]
            for row in worksheet.data?.rows ?? [] {
                for cell in row.cells {
                    if let rc = rawCell(from: cell, styles: styles, shared: shared, date1904: date1904, tz: tz) {
                        cells[rc.reference] = rc
                    }
                }
            }
            propagateMerges(worksheet.mergeCells, into: &cells)
            sheets.append(Sheet(name: name ?? "Sheet", cells: cells))
        }
        return SpreadsheetGrid(sheets: sheets)
    }

    private static func rawCell(
        from cell: Cell,
        styles: Styles,
        shared: SharedStrings?,
        date1904: Bool,
        tz: String
    ) -> RawCell? {
        guard let ref = HelmParsing.CellReference(a1: cell.reference.description) else { return nil }

        // Resolve the cell's number format id (bounds-checked; the stock
        // format(in:) helper uses an UNCHECKED subscript that would crash).
        var numFmtId = 0
        if let s = cell.styleIndex, let xfs = styles.cellFormats?.items, xfs.indices.contains(s) {
            numFmtId = xfs[s].numberFormatId
        }
        let customCode: String? = numFmtId >= 164
            ? styles.numberFormats?.items.first(where: { $0.id == numFmtId })?.formatCode
            : nil

        switch cell.type {
        case .sharedString:
            guard let idx = cell.value.flatMap(Int.init),
                  let items = shared?.items, items.indices.contains(idx),
                  let text = items[idx].text, !text.isEmpty
            else { return nil }
            return RawCell(reference: ref, text: text)

        case .inlineStr:
            guard let text = cell.inlineString?.text, !text.isEmpty else { return nil }
            return RawCell(reference: ref, text: text)

        case .string: // cached formula string result (t="str")
            guard let text = cell.value, !text.isEmpty else { return nil }
            return RawCell(reference: ref, text: text)

        case .bool:
            return RawCell(reference: ref, text: cell.value == "1" ? "TRUE" : "FALSE")

        case .none, .number, .date, .error, .unknown:
            // Numeric branch (also covers typeless cells, the common date case).
            if let num = cell.value.flatMap(Double.init) {
                if HelmDateResolver.isDateFormat(numFmtId: numFmtId, customFormatCode: customCode),
                   let date = HelmDateResolver.date(serial: num, date1904: date1904, dateOnly: true, timeZoneIdentifier: tz) {
                    return RawCell(
                        reference: ref,
                        text: HelmDateResolver.displayString(for: date, timeZoneIdentifier: tz),
                        number: num,
                        isDate: true
                    )
                }
                return RawCell(reference: ref, text: numberDisplay(num, raw: cell.value), number: num, isDate: false)
            }
            // Non-numeric, untyped (e.g. error text) — keep any literal value.
            guard let text = cell.value, !text.isEmpty else { return nil }
            return RawCell(reference: ref, text: text)
        }
    }

    /// Integer-valued numbers render without a decimal (so a "0" counter stays
    /// "0", not "0.0"); otherwise keep the original token.
    private static func numberDisplay(_ num: Double, raw: String?) -> String {
        if num.rounded() == num, abs(num) < 1e15 { return String(Int(num)) }
        return raw ?? String(num)
    }

    /// Copy each merged range's top-left value into the covered (currently empty) cells.
    private static func propagateMerges(_ merges: MergeCells?, into cells: inout [HelmParsing.CellReference: RawCell]) {
        guard let items = merges?.items else { return }
        for merge in items {
            let parts = merge.reference.split(separator: ":")
            guard parts.count == 2,
                  let topLeft = HelmParsing.CellReference(a1: String(parts[0])),
                  let bottomRight = HelmParsing.CellReference(a1: String(parts[1])),
                  let source = cells[topLeft]
            else { continue }
            for r in topLeft.row...bottomRight.row {
                for c in topLeft.column...bottomRight.column {
                    let target = HelmParsing.CellReference(column: c, row: r)
                    if cells[target] == nil {
                        cells[target] = RawCell(reference: target, text: source.text, number: source.number, isDate: source.isDate)
                    }
                }
            }
        }
    }
}
