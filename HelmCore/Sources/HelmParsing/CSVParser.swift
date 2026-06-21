//
//  CSVParser.swift
//  HelmParsing
//
//  A small, dependency-free RFC 4180-ish CSV reader → SpreadsheetGrid. Handles
//  quoted fields, escaped quotes (""), embedded commas/newlines, and CR/LF/CRLF.
//  This is the v0 walking-skeleton intake (DEVELOPMENT_PLAN.md Phase v0); the
//  .xlsx reader arrives in v1.0.
//

import Foundation

public enum CSVParser {

    /// Parse CSV text into a single-sheet `SpreadsheetGrid`.
    /// - Parameters:
    ///   - text: the CSV contents.
    ///   - delimiter: field separator (default comma; pass "\t" for TSV).
    ///   - sheetName: name to give the produced sheet.
    public static func parse(_ text: String, delimiter: Character = ",", sheetName: String = "CSV") -> SpreadsheetGrid {
        let rows = parseRows(text, delimiter: delimiter)
        var cells: [CellReference: RawCell] = [:]
        for (r, row) in rows.enumerated() {
            for (c, field) in row.enumerated() {
                let trimmed = field
                if trimmed.isEmpty { continue }
                let ref = CellReference(column: c, row: r)
                let number = Double(trimmed.replacingOccurrences(of: ",", with: ""))
                cells[ref] = RawCell(reference: ref, text: trimmed, number: number, isDate: false)
            }
        }
        return SpreadsheetGrid(sheets: [Sheet(name: sheetName, cells: cells)])
    }

    /// Tokenize CSV into rows of fields. Exposed for testing.
    ///
    /// Parses over Unicode scalars (not `Character`s) so a CRLF — which Swift
    /// merges into a single `Character` grapheme — is seen as `\r` then `\n`.
    public static func parseRows(_ text: String, delimiter: Character = ",") -> [[String]] {
        let quote: Unicode.Scalar = "\""
        let cr: Unicode.Scalar = "\r"
        let lf: Unicode.Scalar = "\n"
        let sep = delimiter.unicodeScalars.first!

        var rows: [[String]] = []
        var field = String.UnicodeScalarView()
        var record: [String] = []
        var inQuotes = false
        var sawAny = false

        let scalars = Array(text.unicodeScalars)
        var i = 0
        func endField() { record.append(String(field)); field = String.UnicodeScalarView() }
        func endRecord() {
            endField()
            // Skip a spurious trailing empty record from a final newline.
            if !(record.count == 1 && record[0].isEmpty && !sawAny) {
                rows.append(record)
            }
            record = []
            sawAny = false
        }

        while i < scalars.count {
            let ch = scalars[i]
            if inQuotes {
                if ch == quote {
                    if i + 1 < scalars.count && scalars[i + 1] == quote {
                        field.append(quote); i += 2; continue
                    } else {
                        inQuotes = false; i += 1; continue
                    }
                } else {
                    field.append(ch); i += 1; continue
                }
            } else {
                switch ch {
                case quote:
                    inQuotes = true; sawAny = true; i += 1
                case sep:
                    sawAny = true; endField(); i += 1
                case cr:
                    // CRLF or lone CR ends the record.
                    endRecord()
                    if i + 1 < scalars.count && scalars[i + 1] == lf { i += 2 } else { i += 1 }
                case lf:
                    endRecord(); i += 1
                default:
                    sawAny = true; field.append(ch); i += 1
                }
            }
        }
        // Flush the last record if the file didn't end in a newline.
        if sawAny || !field.isEmpty || !record.isEmpty {
            endField()
            rows.append(record)
        }
        return rows
    }
}
