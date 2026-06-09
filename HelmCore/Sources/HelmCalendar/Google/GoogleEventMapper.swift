//
//  GoogleEventMapper.swift
//  HelmCalendar
//
//  Pure CalendarEventDraft → GoogleEvent mapping, including Helm's idempotency
//  scheme for Google: a DETERMINISTIC event id derived from the dedupKey
//  ("helm" + base32hex(SHA-256(key))), so an upsert is a single insert-or-update
//  at a known URL — no list+match round-trip, no duplicate events on re-import.
//  The raw dedupKey is also stamped into extendedProperties.private and the
//  description tag as a recovery channel (mirrors the EventKit adapter's notes tag).
//

import Foundation
import CryptoKit

public enum GoogleEventMapper {
    /// extendedProperties.private marker present on every Helm-written event,
    /// used by removeAll()/recovery to find them: privateExtendedProperty=helmSource%3Dhelm.
    public static let sourceMarkerKey = "helmSource"
    public static let sourceMarkerValue = "helm"
    /// extendedProperties.private key carrying the raw dedupKey.
    public static let dedupKeyProperty = "helmKey"

    /// Google event ids only allow base32hex (a–v, 0–9), 5–1024 chars. dedupKeys
    /// contain '|', ':' etc, so hash: "helm" + base32hex(SHA-256(key)) = 56 chars.
    public static func eventID(for dedupKey: String) -> String {
        let digest = SHA256.hash(data: Data(dedupKey.utf8))
        return "helm" + base32hex(Data(digest))
    }

    public static func event(for draft: CalendarEventDraft) -> GoogleEvent {
        let start: GoogleEvent.Time
        let end: GoogleEvent.Time
        if draft.isAllDay {
            // Google's all-day end date is EXCLUSIVE. Helm's internal convention
            // (shared with ICSExporter) is an inclusive end day interpreted in
            // UTC, so mirror ICSExporter exactly: day-of(start), day-of(end)+1.
            start = .init(date: dateOnly(draft.start))
            end = .init(date: dateOnly(allDayEndExclusive(draft.end)))
        } else {
            // A UTC "Z" instant plus the IANA zone: the instant fixes the time,
            // the zone fixes how Google renders and DST-adjusts it.
            start = .init(dateTime: rfc3339(draft.start), timeZone: draft.timeZoneIdentifier)
            end = .init(dateTime: rfc3339(draft.end), timeZone: draft.timeZoneIdentifier)
        }

        // Google allows at most 5 overrides, minutes clamped to 0...40320.
        let overrides = draft.alarmOffsetsMinutes.prefix(5).map {
            GoogleEvent.ReminderOverride(method: "popup", minutes: min(max($0, 0), 40320))
        }

        return GoogleEvent(
            id: eventID(for: draft.dedupKey),
            status: "confirmed", // resurrects a cancelled id when re-applied after delete
            summary: draft.title,
            location: draft.location,
            description: draft.notes ?? "Imported by Helm. Do not edit the tag.\n[helm:\(draft.dedupKey)]",
            start: start,
            end: end,
            reminders: .init(useDefault: false, overrides: overrides.isEmpty ? nil : Array(overrides)),
            extendedProperties: .init(private: [
                sourceMarkerKey: sourceMarkerValue,
                dedupKeyProperty: draft.dedupKey,
            ])
        )
    }

    // MARK: - Encoding helpers

    /// RFC 4648 §7 base32hex (lowercase, no padding): the only alphabet Google
    /// event ids accept (0–9, a–v).
    static func base32hex(_ data: Data) -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuv")
        var out = String()
        out.reserveCapacity((data.count * 8 + 4) / 5)
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(buffer >> bits) & 0x1F])
            }
        }
        if bits > 0 {
            out.append(alphabet[(buffer << (5 - bits)) & 0x1F])
        }
        return out
    }

    static func rfc3339(_ date: Date) -> String {
        rfc3339Formatter.string(from: date)
    }

    static func dateOnly(_ date: Date) -> String {
        dateOnlyFormatter.string(from: date)
    }

    /// The exclusive all-day end: the day AFTER the inclusive end day (UTC),
    /// byte-for-byte the same convention as ICSExporter.allDayEndExclusive.
    static func allDayEndExclusive(_ end: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: end)) ?? end
    }

    private static let rfc3339Formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
