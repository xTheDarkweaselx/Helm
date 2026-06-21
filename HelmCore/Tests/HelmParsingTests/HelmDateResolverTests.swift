//
//  HelmDateResolverTests.swift
//  HelmParsingTests
//
//  The #1 silent-corruption risk: Excel serial-date conversion + date-format
//  detection. Boundary cases incl. the 1900 leap-year bug and the 1904 system.
//

import Testing
import Foundation
@testable import HelmParsing

private let london = "Europe/London"

private func ymd(_ date: Date) -> (Int, Int, Int) {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: london)!
    let c = cal.dateComponents([.year, .month, .day], from: date)
    return (c.year!, c.month!, c.day!)
}

private func hour(_ date: Date) -> Int {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: london)!
    return cal.component(.hour, from: date)
}

@Suite("HelmDateResolver — serial conversion")
struct SerialConversionTests {
    @Test("D1: 1900-system 46167 → 2026-05-25")
    func d1() throws {
        let d = try #require(HelmDateResolver.date(serial: 46167, date1904: false, dateOnly: true, timeZoneIdentifier: london))
        #expect(ymd(d) == (2026, 5, 25))
    }

    @Test("D3: 1904-system 44705 → 2026-05-25 (== 46167 − 1462)")
    func d3() throws {
        let d = try #require(HelmDateResolver.date(serial: 44705, date1904: true, dateOnly: true, timeZoneIdentifier: london))
        #expect(ymd(d) == (2026, 5, 25))
    }

    @Test("D4: 1904-system 0 → 1904-01-01")
    func d4() throws {
        let d = try #require(HelmDateResolver.date(serial: 0, date1904: true, dateOnly: true, timeZoneIdentifier: london))
        #expect(ymd(d) == (1904, 1, 1))
    }

    @Test("D5: 1900-system 61 → 1900-03-01 (first serial past the phantom leap day)")
    func d5() throws {
        let d = try #require(HelmDateResolver.date(serial: 61, date1904: false, dateOnly: true, timeZoneIdentifier: london))
        #expect(ymd(d) == (1900, 3, 1))
    }

    @Test("D6: fractional 46167.75 → 18:00 with dateOnly=false")
    func d6() throws {
        let d = try #require(HelmDateResolver.date(serial: 46167.75, date1904: false, dateOnly: false, timeZoneIdentifier: london))
        #expect(ymd(d) == (2026, 5, 25))
        #expect(hour(d) == 18)
    }

    @Test("D7: 46167.9999999 carries to the next midnight, never hour 24")
    func d7() throws {
        let d = try #require(HelmDateResolver.date(serial: 46167.9999999, date1904: false, dateOnly: false, timeZoneIdentifier: london))
        #expect(ymd(d) == (2026, 5, 26))
        #expect(hour(d) == 0)
    }

    @Test("displayString emits dd/MM/yyyy")
    func display() throws {
        let d = try #require(HelmDateResolver.date(serial: 46167, date1904: false, dateOnly: true, timeZoneIdentifier: london))
        #expect(HelmDateResolver.displayString(for: d, timeZoneIdentifier: london) == "25/05/2026")
    }
}

@Suite("HelmDateResolver — format detection")
struct DateFormatDetectionTests {
    @Test("F1: custom dd/mm/yyyy;@ is a date")
    func f1() { #expect(HelmDateResolver.isDateFormat(numFmtId: 164, customFormatCode: "dd/mm/yyyy;@")) }

    @Test("F2: built-in id 14 is a date")
    func f2() { #expect(HelmDateResolver.isDateFormat(numFmtId: 14, customFormatCode: nil)) }

    @Test("F3: General (id 0) is not a date")
    func f3() { #expect(!HelmDateResolver.isDateFormat(numFmtId: 0, customFormatCode: nil)) }

    @Test("F4: custom number format is not a date")
    func f4() { #expect(!HelmDateResolver.isDateFormat(numFmtId: 165, customFormatCode: "#,##0.00")) }

    @Test("F5: a 'd' inside a quoted literal is not a date")
    func f5() { #expect(!HelmDateResolver.isDateFormat(numFmtId: 166, customFormatCode: "\"day \"0")) }

    @Test("Elapsed-time [h]:mm is detected as temporal (hasTime)")
    func elapsed() {
        let r = HelmDateResolver.formatCodeIsDateTime("[h]:mm")
        #expect(r.isDate)
        #expect(r.hasTime)
    }

    @Test("A pure date code has no time component")
    func noTime() {
        let r = HelmDateResolver.formatCodeIsDateTime("dd/mm/yyyy;@")
        #expect(r.isDate)
        #expect(!r.hasTime)
    }
}
