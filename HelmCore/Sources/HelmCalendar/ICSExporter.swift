//
//  ICSExporter.swift
//  HelmCalendar
//
//  Provider-agnostic iCalendar (.ics / RFC 5545) export so a roster can be shared
//  with any calendar app (Android, Outlook, web). Pure & deterministic: times are
//  emitted in UTC (…Z) — no VTIMEZONE needed, and overnight shifts are correct
//  because DTEND is the real UTC end. UID = the shift's dedupKey, so a recipient's
//  calendar can update on re-import (where it honours UID).
//

import Foundation

public enum ICSExporter {
    public static let productID = "-//Fusion Studios//Helm//EN"

    /// Build an RFC 5545 calendar string. `generatedAt` is the DTSTAMP (injected
    /// for determinism/testing).
    public static func export(
        _ drafts: [CalendarEventDraft],
        calendarName: String,
        generatedAt: Date
    ) -> String {
        var lines: [String] = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:\(productID)",
            "CALSCALE:GREGORIAN",
            "METHOD:PUBLISH",
            "X-WR-CALNAME:\(escape(calendarName))",
        ]
        let stamp = utc(generatedAt)
        for draft in drafts {
            lines.append("BEGIN:VEVENT")
            lines.append("UID:\(uid(for: draft.dedupKey))")
            lines.append("DTSTAMP:\(stamp)")
            if draft.isAllDay {
                // RFC 5545: all-day DTEND is EXCLUSIVE (the day after the last day).
                lines.append("DTSTART;VALUE=DATE:\(dateOnly(draft.start))")
                lines.append("DTEND;VALUE=DATE:\(dateOnly(allDayEndExclusive(draft.end)))")
            } else {
                lines.append("DTSTART:\(utc(draft.start))")
                lines.append("DTEND:\(utc(draft.end))")
            }
            lines.append("SUMMARY:\(escape(draft.title))")
            if let location = draft.location, !location.isEmpty {
                lines.append("LOCATION:\(escape(location))")
            }
            if let notes = draft.notes, !notes.isEmpty {
                lines.append("DESCRIPTION:\(escape(notes))")
            }
            for offset in draft.alarmOffsetsMinutes.sorted() {
                lines.append("BEGIN:VALARM")
                lines.append("ACTION:DISPLAY")
                lines.append("DESCRIPTION:\(escape(draft.title))")
                lines.append("TRIGGER:\(trigger(minutesBefore: offset))")
                lines.append("END:VALARM")
            }
            lines.append("END:VEVENT")
        }
        lines.append("END:VCALENDAR")

        // RFC 5545: lines are CRLF-terminated and folded at 75 octets.
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - Pieces

    static func uid(for dedupKey: String) -> String {
        // Percent-encode (injective) so distinct keys never collide to one UID —
        // matching ShiftCalendarWriter's eventURL so both dedup paths agree.
        let safe = dedupKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? dedupKey
        return safe + "@helm.fusion-studios"
    }

    /// Escape TEXT per RFC 5545 §3.3.11: backslash, semicolon, comma, and newlines.
    /// CRLF and lone CR are normalised to a newline first so no separator is lost.
    static func escape(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var out = ""
        out.reserveCapacity(normalized.count)
        for ch in normalized {
            switch ch {
            case "\\": out += "\\\\"
            case ";": out += "\\;"
            case ",": out += "\\,"
            case "\n": out += "\\n"
            default: out.append(ch)
            }
        }
        return out
    }

    private static let utcFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    static func utc(_ date: Date) -> String { utcFormatter.string(from: date) }
    static func dateOnly(_ date: Date) -> String { dateOnlyFormatter.string(from: date) }

    /// The exclusive all-day end: the day AFTER the inclusive end day (UTC).
    static func allDayEndExclusive(_ end: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: end)) ?? end
    }

    /// A negative-duration TRIGGER, e.g. 60 → "-PT1H", 90 → "-PT1H30M", 0 → "PT0S".
    static func trigger(minutesBefore minutes: Int) -> String {
        if minutes <= 0 { return "PT0S" }
        let h = minutes / 60
        let m = minutes % 60
        var dur = "-PT"
        if h > 0 { dur += "\(h)H" }
        if m > 0 { dur += "\(m)M" }
        return dur
    }

    /// Fold a content line to ≤75 octets (UTF-8), continuations begin with a space.
    static func fold(_ line: String) -> String {
        let bytes = Array(line.utf8)
        guard bytes.count > 75 else { return line }
        var result = ""
        var index = 0
        var isFirst = true
        while index < bytes.count {
            // Leave room for the leading space on continuation lines.
            let limit = isFirst ? 75 : 74
            var end = min(index + limit, bytes.count)
            // Don't split inside a UTF-8 multibyte sequence (continuation bytes are 10xxxxxx).
            while end > index && end < bytes.count && (bytes[end] & 0xC0) == 0x80 { end -= 1 }
            let chunk = String(decoding: bytes[index..<end], as: UTF8.self)
            result += isFirst ? chunk : "\r\n " + chunk
            index = end
            isFirst = false
        }
        return result
    }
}
