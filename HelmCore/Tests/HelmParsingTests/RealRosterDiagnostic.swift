//
//  RealRosterDiagnostic.swift
//  HelmParsingTests
//
//  Diagnostic over the user's REAL roster (gitignored; auto-skips when the
//  file is absent, so CI/other machines are unaffected). Prints every row's
//  parse outcome so silent skips become visible.
//

import Foundation
import Testing
@testable import HelmParsing
@testable import HelmDomain

@Suite struct RealRosterDiagnostic {
    private static let path = "/Users/adam/Library/CloudStorage/GoogleDrive-weaselzonefan1234@gmail.com/My Drive/Programming/Xcode/Helm/Helm/Fixtures/Rosters/UEC34 LKS NSE Jun 26 SATC Read Only Programme.xlsx"

    @Test func dumpAllRowOutcomes() throws {
        guard FileManager.default.fileExists(atPath: Self.path) else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.path))
        let grid = try XLSXGridLoader.load(data: data, timeZoneIdentifier: "Europe/London")

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!

        for sheet in grid.sheets {
            guard let mapping = ListLayoutDetector.detect(sheet: sheet) else {
                print("DIAG sheet '\(sheet.name)': NO MAPPING DETECTED")
                continue
            }
            print("DIAG sheet '\(sheet.name)': mapping date=\(mapping.dateColumn) code=\(mapping.codeColumn) title=\(String(describing: mapping.titleColumn)) loc=\(String(describing: mapping.locationColumn)) headerRows=\(mapping.headerRowCount)")

            // What the interpreter produces…
            let parsed = ListLayoutInterpreter.interpret(
                sheet: sheet, mapping: mapping,
                timeZoneIdentifier: "Europe/London", dateOrder: .dayFirst
            )
            var parsedRows = Set(parsed.compactMap(\.sourceRow))
            for shift in parsed {
                let c = cal.dateComponents([.year, .month, .day], from: shift.localDate)
                let day = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
                print("DIAG row \(shift.sourceRow ?? -1) \(day) | code='\(shift.normalizedCode)' inline=\(shift.inlineTimes.map { "\($0.startMinuteOfDay)-\($0.endMinuteOfDay)" } ?? "nil") title='\(shift.title ?? "")' loc='\(shift.location ?? "")'")
            }

            // …and every row the interpreter DROPPED (no parseable date), with
            // its raw cell texts, so silent skips become visible.
            for row in mapping.headerRowCount..<sheet.rowCount {
                guard !parsedRows.contains(row) else { continue }
                let dateText = sheet.cell(CellReference(column: mapping.dateColumn, row: row))?.text ?? ""
                let codeText = sheet.cell(CellReference(column: mapping.codeColumn, row: row))?.text ?? ""
                let titleText = mapping.titleColumn.flatMap { sheet.cell(CellReference(column: $0, row: row))?.text } ?? ""
                if dateText.isEmpty && codeText.isEmpty && titleText.isEmpty { continue } // truly blank
                print("DIAG DROPPED row \(row): date='\(dateText)' code='\(codeText)' title='\(titleText)'")
            }
            parsedRows.removeAll()
        }
    }
}
