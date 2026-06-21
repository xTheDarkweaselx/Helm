//
//  ShiftCode.swift
//  HelmDomain
//
//  Normalizing raw spreadsheet shift codes and parsing inline time ranges.
//  Grounded in the first real sample (Fixtures/Rosters/README.md): codes like
//  "M"/"A"/"OFF"/"TBC" plus inline ranges like "0900-1700" and "0930-1500".
//

import Foundation

public enum ShiftCodeNormalizer {
    /// Canonical form for matching: trimmed, internal whitespace collapsed, uppercased.
    /// e.g. "  m " → "M", "off" → "OFF", "M / A" → "M/A".
    public static func normalize(_ raw: String) -> String {
        let collapsed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.uppercased()
    }

    /// Strip a trailing annotation from an already-normalized code so a human
    /// note doesn't turn a known code into an unknown one: "M (TRAINING)" → "M",
    /// "A*" → "A", "L †" → "L". Only parenthetical/asterisk/dagger notes are
    /// removed — never another word — so composite codes like "M/A" are untouched.
    public static func stripAnnotation(_ normalizedCode: String) -> String {
        var s = normalizedCode
        s = s.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[\*†‡\s]+$"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Sentinels that mean "no shift / no event" in observed rosters. Kept to
    /// UNAMBIGUOUS tokens — a bare "O" was dropped (too easily a real shift code);
    /// an explicit legend mapping now wins over any of these anyway (see
    /// RosterImporter.makeResult, which consults the legend first).
    public static let offSentinels: Set<String> = [
        "OFF", "-", "–", "—", "", "0", "REST", "REST DAY", "RD", "RDO",
        "DAY OFF", "OFF DAY", "X", "NIL",
    ]

    /// Sentinels that mean "shift exists but time is unknown".
    public static let tentativeSentinels: Set<String> = ["TBC", "TBD", "TBA", "?", "??"]

    /// Common codes that mean an all-day, non-worked entry (leave/sickness/
    /// holiday) → maps to a label. Applied only as a fallback when no explicit
    /// legend entry exists, so a user/employer mapping always wins.
    public static let leaveSentinels: [String: String] = [
        "A/L": "Annual leave", "AL": "Annual leave", "ANNUAL LEAVE": "Annual leave",
        "HOL": "Holiday", "HOLIDAY": "Holiday", "LEAVE": "Leave",
        "SICK": "Sick", "S/L": "Sick leave", "SL": "Sick leave",
        "B/H": "Bank holiday", "BH": "Bank holiday", "BANK HOLIDAY": "Bank holiday",
        "P/H": "Public holiday", "PH": "Public holiday",
        "TOIL": "TOIL", "STUDY": "Study leave", "TRAINING": "Training",
        "MAT": "Maternity leave", "PAT": "Paternity leave", "COMP": "Compassionate leave",
    ]

    public static func isOff(_ normalizedCode: String) -> Bool { offSentinels.contains(normalizedCode) }
    public static func isTentative(_ normalizedCode: String) -> Bool { tentativeSentinels.contains(normalizedCode) }
    /// The leave label for a code (exact, then annotation-stripped), or nil.
    public static func leaveLabel(_ normalizedCode: String) -> String? {
        leaveSentinels[normalizedCode] ?? leaveSentinels[stripAnnotation(normalizedCode)]
    }
}

/// A start/end time parsed inline from a cell, in minutes-of-day.
public struct InlineTimeRange: Sendable, Equatable {
    public let startMinuteOfDay: Int
    public let endMinuteOfDay: Int

    public init(startMinuteOfDay: Int, endMinuteOfDay: Int) {
        self.startMinuteOfDay = startMinuteOfDay
        self.endMinuteOfDay = endMinuteOfDay
    }

    /// Parse a two-time range written inline in a cell. Handles the machine
    /// formats — "0900-1700", "09:00-17:00", "0930 - 1500", "2200–0600" — and
    /// common human ones: "9.30-15.00" (dot separator), "9am-5pm", "9:30 AM - 5 PM",
    /// "0900-1700 (training)" / "0900-1700*" (trailing notes), and "9 to 5pm".
    /// Conservative on ambiguity: a BARE hour with neither minutes nor a meridiem
    /// (e.g. "9-5") is rejected rather than guessed, so it falls through to the
    /// legend instead of silently writing a wrong time. Returns nil if not a range.
    public static func parse(_ raw: String) -> InlineTimeRange? {
        let cleaned = stripTrailingNote(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !cleaned.isEmpty,
              let (lhs, rhs) = splitOnce(cleaned),
              let start = parseToken(lhs), let end = parseToken(rhs)
        else { return nil }
        return InlineTimeRange(startMinuteOfDay: start, endMinuteOfDay: end)
    }

    /// Drop a trailing parenthetical or asterisk/dagger note: "0900-1700 (TBC)*".
    private static func stripTrailingNote(_ s: String) -> String {
        var r = s.replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
        r = r.replacingOccurrences(of: #"[\*†‡\s]+$"#, with: "", options: .regularExpression)
        return r.trimmingCharacters(in: .whitespaces)
    }

    /// Split into exactly two tokens on the first dash-like separator or " to ".
    private static func splitOnce(_ s: String) -> (String, String)? {
        let normalized = s.replacingOccurrences(of: #"\s+to\s+"#, with: "-", options: [.regularExpression, .caseInsensitive])
        let parts = normalized.split(whereSeparator: { $0 == "-" || $0 == "–" || $0 == "—" })
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// A single time token → minute-of-day, or nil. Accepts H:MM / H.MM / HMM /
    /// HHMM / a bare hour, with an optional am/pm meridiem.
    private static func parseToken(_ token: String) -> Int? {
        var t = token.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return nil }

        var meridiem: Int? = nil // 0 = am, 1 = pm
        for suffix in ["a.m.", "p.m.", "am", "pm"] where t.hasSuffix(suffix) {
            meridiem = suffix.hasPrefix("p") ? 1 : 0
            t = String(t.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        t = t.replacingOccurrences(of: ".", with: ":")

        var hour: Int, minute: Int
        if t.contains(":") {
            // Require a zero-padded 2-digit minute. This is what makes the dot
            // form safe: "9.30" → "9:30" (minutes) is accepted, but DECIMAL HOURS
            // like "8.5" → "8:5" is rejected so it falls through to the legend /
            // unknown-code review instead of silently writing 08:05 for 08:30.
            let comps = t.split(separator: ":", omittingEmptySubsequences: false)
            guard comps.count == 2, !comps[0].isEmpty, comps[1].count == 2,
                  let h = Int(comps[0]), let m = Int(comps[1]) else { return nil }
            (hour, minute) = (h, m)
        } else {
            guard !t.isEmpty, t.allSatisfy(\.isNumber), let n = Int(t) else { return nil }
            switch t.count {
            case 1, 2:
                guard meridiem != nil else { return nil } // bare hour, no meridiem → ambiguous, reject
                (hour, minute) = (n, 0)
            case 3: (hour, minute) = (n / 100, n % 100)   // HMM
            case 4: (hour, minute) = (n / 100, n % 100)   // HHMM
            default: return nil
            }
        }

        if let mer = meridiem {
            guard (1...12).contains(hour) else { return nil }
            if mer == 1, hour != 12 { hour += 12 }   // pm
            if mer == 0, hour == 12 { hour = 0 }      // 12am → 00:00
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return hour * 60 + minute
    }
}
