//
//  ListLayoutDetectorTests.swift
//  HelmParsingTests
//

import Testing
@testable import HelmParsing

@Suite("ListLayoutDetector")
struct ListLayoutDetectorTests {

    private let sampleCSV = """
    DATE,Day of the Week,Course Title,Location,Day #,SHIFT
    14/06/2026,Sunday,HMI Day 1,D2,1,M
    20/06/2026,Saturday,OFF,-,7,OFF
    """

    @Test("Detects date/shift/title/location columns and header row from the sample")
    func detectsSample() throws {
        let grid = CSVParser.parse(sampleCSV)
        let mapping = try #require(ListLayoutDetector.detect(sheet: grid.sheets[0]))
        #expect(mapping.dateColumn == 0)     // DATE
        #expect(mapping.codeColumn == 5)     // SHIFT
        #expect(mapping.titleColumn == 2)    // Course Title
        #expect(mapping.locationColumn == 3) // Location
        #expect(mapping.headerRowCount == 1) // header is row 0
    }

    @Test("Returns nil when there is no date or shift column")
    func failsGracefully() {
        let grid = CSVParser.parse("Name,Notes\nAlice,hi")
        #expect(ListLayoutDetector.detect(sheet: grid.sheets[0]) == nil)
    }

    @Test("Finds a header row that isn't the first row")
    func headerNotFirstRow() throws {
        let csv = "My Roster June 2026,,,\nDate,Shift,Activity,Place\n14/06/2026,M,HMI,D2"
        let grid = CSVParser.parse(csv)
        let mapping = try #require(ListLayoutDetector.detect(sheet: grid.sheets[0]))
        #expect(mapping.headerRowCount == 2) // title row + header row
        #expect(mapping.dateColumn == 0)
        #expect(mapping.codeColumn == 1)
    }
}
