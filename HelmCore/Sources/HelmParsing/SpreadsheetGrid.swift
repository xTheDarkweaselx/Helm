//
//  SpreadsheetGrid.swift
//  HelmParsing
//
//  The normalized tabular form every source format (xlsx/csv/…) is decoded into,
//  so roster interpretation is decoupled from brittle format parsing (ADR-7).
//  Cells are indexed by reference (not array position) so blank cells never
//  misalign the grid (DEVELOPMENT_PLAN.md §4 step 3).
//

import Foundation

/// Zero-based cell coordinate with A1-notation conversion.
public struct CellReference: Sendable, Hashable, Comparable {
    public let column: Int // 0-based (A = 0)
    public let row: Int    // 0-based (row 1 = 0)

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }

    public static func < (lhs: CellReference, rhs: CellReference) -> Bool {
        (lhs.row, lhs.column) < (rhs.row, rhs.column)
    }

    /// A1 notation, e.g. (0,0) → "A1", (26,0) → "AA1".
    public var a1: String { "\(Self.columnLetters(column))\(row + 1)" }

    /// Parse A1 notation, e.g. "B3" → (column: 1, row: 2). Returns nil if malformed.
    public init?(a1: String) {
        let s = a1.uppercased()
        guard let firstDigit = s.firstIndex(where: { $0.isNumber }) else { return nil }
        let letters = s[s.startIndex..<firstDigit]
        let digits = s[firstDigit...]
        guard !letters.isEmpty, let rowNumber = Int(digits), rowNumber >= 1 else { return nil }
        var col = 0
        for ch in letters {
            guard let v = ch.asciiValue, (65...90).contains(v) else { return nil }
            col = col * 26 + Int(v - 64)
        }
        self.init(column: col - 1, row: rowNumber - 1)
    }

    /// 0-based column index → letters (0 → "A", 25 → "Z", 26 → "AA").
    public static func columnLetters(_ index: Int) -> String {
        var n = index + 1
        var result = ""
        while n > 0 {
            let rem = (n - 1) % 26
            result = String(UnicodeScalar(65 + rem)!) + result
            n = (n - 1) / 26
        }
        return result
    }
}

/// A single decoded cell. `text` is always the display string; `number`/`isDate`
/// preserve typing so the date resolver and detectors can reason about content.
public struct RawCell: Sendable, Equatable {
    public let reference: CellReference
    public let text: String
    public let number: Double?
    public let isDate: Bool

    public init(reference: CellReference, text: String, number: Double? = nil, isDate: Bool = false) {
        self.reference = reference
        self.text = text
        self.number = number
        self.isDate = isDate
    }
}

public struct Sheet: Sendable {
    public let name: String
    /// Sparse: only non-empty cells are stored.
    public let cells: [CellReference: RawCell]
    public let rowCount: Int
    public let columnCount: Int

    public init(name: String, cells: [CellReference: RawCell]) {
        self.name = name
        self.cells = cells
        self.rowCount = (cells.keys.map(\.row).max() ?? -1) + 1
        self.columnCount = (cells.keys.map(\.column).max() ?? -1) + 1
    }

    public func cell(_ reference: CellReference) -> RawCell? { cells[reference] }
    public func row(_ row: Int) -> [RawCell] {
        cells.values.filter { $0.reference.row == row }.sorted { $0.reference < $1.reference }
    }
    public func column(_ column: Int) -> [RawCell] {
        cells.values.filter { $0.reference.column == column }.sorted { $0.reference < $1.reference }
    }
}

public struct SpreadsheetGrid: Sendable {
    public let sheets: [Sheet]
    public init(sheets: [Sheet]) { self.sheets = sheets }
}
