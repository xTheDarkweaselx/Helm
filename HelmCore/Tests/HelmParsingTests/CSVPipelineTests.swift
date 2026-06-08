//
//  CSVPipelineTests.swift
//  HelmParsingTests
//
//  End-to-end v0 pipeline: CSV text → grid → [ParsedShift], mirroring the first
//  real sample's columns (DATE, Day, Course Title, Location, Day#, SHIFT).
//

import Testing
import Foundation
import HelmDomain
@testable import HelmParsing

@Suite("CSV parsing")
struct CSVParsingTests {
    @Test("Splits rows and fields")
    func basic() {
        let rows = CSVParser.parseRows("a,b,c\n1,2,3\n")
        #expect(rows == [["a", "b", "c"], ["1", "2", "3"]])
    }

    @Test("Handles quoted fields with embedded commas and quotes")
    func quoting() {
        let rows = CSVParser.parseRows("\"Medway, PTT\",\"say \"\"hi\"\"\",x")
        #expect(rows == [["Medway, PTT", "say \"hi\"", "x"]])
    }

    @Test("Handles CRLF line endings")
    func crlf() {
        let rows = CSVParser.parseRows("a,b\r\n1,2\r\n")
        #expect(rows == [["a", "b"], ["1", "2"]])
    }
}

@Suite("List-layout interpretation")
struct ListInterpretationTests {

    private let sampleCSV = """
    DATE,Day of the Week,Course Title,Location,Day #,SHIFT
    14/06/2026,Sunday,HMI Day 1,D2,1,M
    15/06/2026,Monday,HMI Day 2,D2,2,M
    17/06/2026,Wednesday,HMI Day 4,D2,4,A
    20/06/2026,Saturday,OFF,-,7,OFF
    26/06/2026,Friday,"Medway Intro Day, PTT",PTT,13,0930-1500
    15/12/2026,Tuesday,UEC ART Classroom Day,-,185,TBC
    """

    private func interpret() -> [ParsedShift] {
        let grid = CSVParser.parse(sampleCSV)
        let sheet = grid.sheets[0]
        let mapping = ListColumnMapping(dateColumn: 0, codeColumn: 5, titleColumn: 2, locationColumn: 3, headerRowCount: 1)
        return ListLayoutInterpreter.interpret(sheet: sheet, mapping: mapping, timeZoneIdentifier: "Europe/London", dateOrder: .dayFirst)
    }

    @Test("Produces one shift per day row")
    func count() {
        #expect(interpret().count == 6)
    }

    @Test("Maps codes, inline times, titles and locations")
    func mapping() {
        let shifts = interpret()
        #expect(shifts[0].normalizedCode == "M")
        #expect(shifts[0].title == "HMI Day 1")
        #expect(shifts[0].location == "D2")

        #expect(shifts[2].normalizedCode == "A")

        // OFF day: code preserved (materializer decides to skip), location "-" → nil
        #expect(shifts[3].normalizedCode == "OFF")
        #expect(shifts[3].location == nil)
        #expect(ShiftCodeNormalizer.isOff(shifts[3].normalizedCode))

        // Inline-time cell: no code, explicit times parsed; title kept its embedded comma
        #expect(shifts[4].normalizedCode == "")
        #expect(shifts[4].inlineTimes == InlineTimeRange(startMinuteOfDay: 570, endMinuteOfDay: 900))
        #expect(shifts[4].title == "Medway Intro Day, PTT")

        // TBC day: tentative code preserved, location "-" → nil
        #expect(shifts[5].normalizedCode == "TBC")
        #expect(ShiftCodeNormalizer.isTentative(shifts[5].normalizedCode))
    }

    @Test("Parses UK day-first dates onto the correct calendar day")
    func dates() {
        let shifts = interpret()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        let first = cal.dateComponents([.year, .month, .day], from: shifts[0].localDate)
        #expect(first.year == 2026 && first.month == 6 && first.day == 14)
        #expect(shifts[0].dedupKeyInput == "2026-06-14|Europe/London|M")
    }
}
