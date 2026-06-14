//
//  ManualMappingTests.swift
//  HelmParsingTests
//
//  v8.1 "never dead-end": a sheet whose headers don't match Helm's keywords
//  must (a) fail auto-detection, and (b) still parse correctly once the user
//  supplies an explicit column mapping.
//

import Testing
import Foundation
import HelmDomain
@testable import HelmParsing

@Suite("Manual column mapping")
struct ManualMappingTests {
    // Non-English headers ("Jour"/"Quart"/"Endroit") — no date/shift keyword.
    private let csv = """
    Jour,Quart,Endroit
    14/06/2026,M,Site A
    15/06/2026,A,Site B
    16/06/2026,OFF,
    17/06/2026,0900-1700,Site C
    """

    private var sheet: Sheet { CSVParser.parse(csv, sheetName: "roster").sheets[0] }

    @Test("Auto-detection fails on non-keyword headers (the dead-end trigger)")
    func autoDetectFails() {
        #expect(ListLayoutDetector.detect(sheet: sheet) == nil)
    }

    @Test("An explicit mapping parses the same sheet correctly")
    func manualMappingParses() {
        let mapping = ListColumnMapping(dateColumn: 0, codeColumn: 1, titleColumn: nil,
                                        locationColumn: 2, headerRowCount: 1)
        let shifts = ListLayoutInterpreter.interpret(sheet: sheet, mapping: mapping,
                                                     timeZoneIdentifier: "Europe/London", dateOrder: .dayFirst)
        #expect(shifts.count == 4)
        #expect(shifts.map(\.normalizedCode) == ["M", "A", "OFF", ""]) // last is an inline range
        #expect(shifts[3].inlineTimes == InlineTimeRange(startMinuteOfDay: 540, endMinuteOfDay: 1020))
        #expect(shifts[0].location == "Site A")
    }
}
