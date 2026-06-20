//
//  LegendSniffer.swift
//  HelmParsing
//
//  v9 Auto-Learn Codes: many rosters embed their own KEY/legend — a small block
//  (or a separate "Key" sheet) pairing each shift code with its times, e.g.
//  "E   Early   07:00-15:00". This sniffs those rows out of the grid so the
//  importer can resolve those codes from the file itself instead of asking the
//  user to teach every one. Pure; the app decides how to apply the result (it
//  only fills codes that are otherwise unknown, so a stray match can't override
//  a real mapping).
//

import Foundation
import HelmDomain

/// One code→meaning pair read from a file's own legend.
public struct SniffedLegendEntry: Sendable, Equatable {
    public let code: String          // normalized
    public let label: String?
    public let times: InlineTimeRange?

    public init(code: String, label: String?, times: InlineTimeRange?) {
        self.code = code
        self.label = label
        self.times = times
    }
}

public enum LegendSniffer {

    /// Scan every sheet for legend rows pairing a short shift code with a time
    /// range (and optional label). Returns one TIMED entry per code, code-sorted.
    public static func sniff(grid: SpreadsheetGrid) -> [SniffedLegendEntry] {
        var byCode: [String: SniffedLegendEntry] = [:]
        for sheet in grid.sheets {
            guard sheet.rowCount > 0, sheet.columnCount > 0 else { continue }
            for row in 0..<sheet.rowCount {
                var cells: [(col: Int, text: String)] = []
                for col in 0..<sheet.columnCount {
                    if let raw = sheet.cell(CellReference(column: col, row: row))?.text {
                        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !t.isEmpty { cells.append((col, t)) }
                    }
                }
                // A legend row is SPARSE — a code + its meaning, not a full week
                // of shifts. That alone rules most roster-data rows out.
                guard (2...4).contains(cells.count) else { continue }
                if let entry = legendEntry(in: cells), byCode[entry.code] == nil {
                    byCode[entry.code] = entry
                }
            }
        }
        return byCode.values.sorted { $0.code < $1.code }
    }

    private static func legendEntry(in cells: [(col: Int, text: String)]) -> SniffedLegendEntry? {
        // Prefer the SHORTEST code-like token as the code ("E" over "Early").
        let codeCandidates = cells
            .filter { isCodeLike($0.text) && InlineTimeRange.parse($0.text) == nil }
            .sorted { $0.text.count < $1.text.count }

        for codeCell in codeCandidates {
            let code = ShiftCodeNormalizer.normalize(codeCell.text)
            guard !code.isEmpty,
                  !ShiftCodeNormalizer.isOff(code),
                  !ShiftCodeNormalizer.isTentative(code) else { continue }
            for meaning in cells where meaning.col != codeCell.col {
                guard let times = extractTimes(from: meaning.text) else { continue }
                let label = labelCell(in: cells, excluding: [codeCell.col, meaning.col])
                    ?? labelPrefix(of: meaning.text)
                return SniffedLegendEntry(code: code, label: label, times: times)
            }
        }
        return nil
    }

    /// A short alphanumeric token that could be a code (must contain a letter, so
    /// a bare number isn't mistaken for one).
    private static func isCodeLike(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard (1...5).contains(t.count), t.allSatisfy({ $0.isLetter || $0.isNumber }),
              t.contains(where: \.isLetter) else { return false }
        return true
    }

    /// A time range somewhere in `text`, even with a leading label
    /// ("Early 07:00-15:00" → 07:00-15:00).
    private static func extractTimes(from text: String) -> InlineTimeRange? {
        if let t = InlineTimeRange.parse(text) { return t }
        if let firstDigit = text.firstIndex(where: \.isNumber) {
            return InlineTimeRange.parse(String(text[firstDigit...]))
        }
        return nil
    }

    /// A separate label cell (neither code nor time) in the same row.
    private static func labelCell(in cells: [(col: Int, text: String)], excluding: Set<Int>) -> String? {
        for c in cells where !excluding.contains(c.col) {
            if extractTimes(from: c.text) == nil, c.text.count >= 2 { return c.text }
        }
        return nil
    }

    /// Leading non-time words of the meaning cell ("Early 07:00-15:00" → "Early").
    private static func labelPrefix(of text: String) -> String? {
        guard let firstDigit = text.firstIndex(where: \.isNumber) else { return nil }
        let strip = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—:=()|"))
        let prefix = text[..<firstDigit].trimmingCharacters(in: strip)
        return prefix.isEmpty ? nil : prefix
    }
}
