//
//  DateOrderInferenceTests.swift
//  HelmParsingTests
//
//  v8.1 Smarter import: infer a date column's true order so US mm/dd and ISO
//  files stop silently landing on the wrong day. Conservative — only departs
//  from the UK day-first default when the column shows positive evidence.
//

import Testing
import Foundation
@testable import HelmParsing

@Suite("RosterDateParser.inferOrder")
struct DateOrderInferenceTests {
    @Test("UK day-first when a first part exceeds 12")
    func dayFirst() {
        #expect(RosterDateParser.inferOrder(from: ["14/06/2026", "03/06/2026", "21/06/2026"]) == .dayFirst)
    }

    @Test("US month-first when several second parts exceed 12")
    func monthFirst() {
        #expect(RosterDateParser.inferOrder(from: ["06/14/2026", "06/03/2026", "07/21/2026"]) == .monthFirst)
    }

    @Test("One anomalous/typo cell does NOT flip a day-first column")
    func typoDoesNotFlip() {
        // dd/MM column with a single bad "06/14/2026" — must stay day-first, not
        // reinterpret the whole column as US (May↔June corruption).
        #expect(RosterDateParser.inferOrder(from: ["14/06/2026", "03/06/2026", "06/14/2026"]) == .dayFirst)
        // A lone month-first-looking cell with no quorum stays day-first.
        #expect(RosterDateParser.inferOrder(from: ["01/02/2026", "06/14/2026"]) == .dayFirst)
        // A lone ISO-looking cell can't win on a tie either.
        #expect(RosterDateParser.inferOrder(from: ["14/06/2026", "2026/06/14"]) == .dayFirst)
    }

    @Test("Stray non-date cells (times/totals) don't vote")
    func straysIgnored() {
        // "06.30.00" parses to 3 ints but its year part isn't 4 digits → ignored.
        #expect(RosterDateParser.inferOrder(from: ["14/06/2026", "06.30.00", "06.30.00"]) == .dayFirst)
    }

    @Test("ISO when a first part exceeds 31 (4-digit year)")
    func iso() {
        #expect(RosterDateParser.inferOrder(from: ["2026-06-14", "2026-06-03"]) == .iso)
    }

    @Test("Ambiguous column (all parts ≤ 12) defaults to day-first")
    func ambiguousDefaultsDayFirst() {
        #expect(RosterDateParser.inferOrder(from: ["03/04/2026", "05/06/2026"]) == .dayFirst)
        #expect(RosterDateParser.inferOrder(from: []) == .dayFirst)
        #expect(RosterDateParser.inferOrder(from: ["not a date", "Monday"]) == .dayFirst)
    }

    @Test("Inferred order parses to the correct calendar day end-to-end")
    func endToEnd() {
        let order = RosterDateParser.inferOrder(from: ["06/14/2026", "06/15/2026"]) // quorum of 2
        #expect(order == .monthFirst)
        let date = RosterDateParser.parse("06/14/2026", order: order, timeZoneIdentifier: "Europe/London")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        let comps = cal.dateComponents([.year, .month, .day], from: date!)
        #expect(comps.month == 6 && comps.day == 14)
    }
}
