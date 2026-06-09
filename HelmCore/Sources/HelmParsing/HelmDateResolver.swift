//
//  HelmDateResolver.swift
//  HelmParsing
//
//  Helm-owned Excel serial-date handling (DEVELOPMENT_PLAN.md ADR-7, Spike 2).
//  NEVER use CoreXLSX's Cell.dateValue: it hardcodes the 1899-12-30 epoch
//  (ignores date1904), uses TimeZone.autoupdatingCurrent (non-deterministic per
//  device), and converts ANY number to a date (no number-format gating). This
//  resolver gates on the cell's number format, honours the workbook date system,
//  and is deterministic.
//

import Foundation

public enum HelmDateResolver {

    /// Built-in OOXML date/time numFmtIds (ECMA-376 §18.8.30) — these carry no
    /// explicit <numFmt> entry. Includes the common date/time ids, the [..] /
    /// AM-PM ids (45–47), and the locale-specific date/time blocks (27–36, 50–58).
    static let builtinDateTimeIDs: Set<Int> =
        Set([14, 15, 16, 17, 18, 19, 20, 21, 22, 45, 46, 47])
            .union(27...36)
            .union(50...58)

    /// Whether a cell with this number format is date/time-typed.
    /// - numFmtId 0 = General → never a date.
    /// - numFmtId < 164 (built-in) → membership test.
    /// - numFmtId >= 164 (custom) → scan the supplied formatCode.
    public static func isDateFormat(numFmtId: Int, customFormatCode: String?) -> Bool {
        if numFmtId == 0 { return false }
        if builtinDateTimeIDs.contains(numFmtId) { return true }
        guard let code = customFormatCode else { return false }
        return formatCodeIsDateTime(code).isDate
    }

    /// Scan a custom format code for date/time tokens, ignoring quoted literals
    /// ("..."), backslash escapes (\x), and non-elapsed bracket sections
    /// ([Red], [$-409], [>0]) while honouring elapsed [h]/[m]/[s]. The m=minute
    /// vs m=month distinction is irrelevant for *typing* (both imply date/time).
    /// `isDate` is true if any date OR time token is present.
    static func formatCodeIsDateTime(_ code: String) -> (isDate: Bool, hasTime: Bool) {
        var foundDate = false
        var foundTime = false
        let s = Array(code)
        var i = 0
        var inQuote = false
        while i < s.count {
            let c = s[i]
            if inQuote {
                if c == "\"" { inQuote = false }
                i += 1
                continue
            }
            switch c {
            case "\"":
                inQuote = true; i += 1
            case "\\":
                i += 2 // escaped literal char — skip it
            case "[":
                var j = i + 1
                var content = ""
                while j < s.count && s[j] != "]" { content.append(s[j]); j += 1 }
                switch content.lowercased() {
                case "h", "hh", "m", "mm", "s", "ss": foundTime = true // elapsed time
                default: break // colour / locale / condition — ignore
                }
                i = (j < s.count) ? j + 1 : j
            case "d", "D", "y", "Y":
                foundDate = true; i += 1
            case "m", "M":
                foundDate = true; i += 1 // month or minute — either way temporal
            case "h", "H", "s", "S":
                foundTime = true; i += 1
            // NOTE: a bare unquoted a/A/p/P is a literal, NOT an AM/PM marker — a
            // real AM/PM token ("AM/PM", "A/P") is always paired with h/hh, which
            // already sets foundTime. Treating lone letters as time wrongly flags
            // codes like "General"/"Standard" (they contain 'a') as dates.
            default:
                i += 1
            }
        }
        return (foundDate || foundTime, foundTime)
    }

    /// Convert an Excel serial number to a deterministic Date.
    /// - 1900 system: epoch 1899-12-30. This convention matches Excel for serials
    ///   >= 61 (i.e. 1900-03-01 onward, which covers every real roster); serials
    ///   1–59 land one day earlier than Excel and serial 60 is Excel's phantom
    ///   1900-02-29 — none of which occur in shift data.
    /// - 1904 system: epoch 1904-01-01.
    /// `dateOnly` anchors at NOON in `timeZoneIdentifier` (matching
    /// RosterDateParser, which builds at hour 12) so only y/m/d is meaningful.
    public static func date(
        serial: Double,
        date1904: Bool,
        dateOnly: Bool,
        timeZoneIdentifier: String
    ) -> Date? {
        // Bound the serial BEFORE Int(floor()) — Int(.infinity)/Int(.nan)/Int(1e300)
        // are fatal traps. A malformed/overflow numeric cell in a date-styled column
        // returns nil here and is kept as a plain number, not crashed on.
        // 2_958_466 ≈ Excel's max date (9999-12-31) + slack.
        guard serial.isFinite, serial >= -3_000_000, serial <= 2_958_466 else { return nil }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .gmt

        let epochComponents = date1904
            ? DateComponents(year: 1904, month: 1, day: 1)
            : DateComponents(year: 1899, month: 12, day: 30)
        guard let epoch = cal.date(from: epochComponents) else { return nil }

        var wholeDays = Int(floor(serial))
        var seconds = dateOnly
            ? 0
            : Int((serial.truncatingRemainder(dividingBy: 1) * 86400).rounded(.toNearestOrAwayFromZero))
        if seconds == 86400 { wholeDays += 1; seconds = 0 } // never roll to hour 24

        guard let day = cal.date(byAdding: .day, value: wholeDays, to: epoch) else { return nil }
        if dateOnly {
            return cal.date(bySettingHour: 12, minute: 0, second: 0, of: day)
        }
        return cal.date(byAdding: .second, value: seconds, to: day)
    }

    /// The date text written into `RawCell.text`. Emits `dd/MM/yyyy` via a fixed
    /// gregorian/POSIX formatter so the existing list interpreter (.dayFirst)
    /// re-parses it unchanged.
    public static func displayString(for date: Date, timeZoneIdentifier: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .gmt
        f.dateFormat = "dd/MM/yyyy"
        return f.string(from: date)
    }
}
