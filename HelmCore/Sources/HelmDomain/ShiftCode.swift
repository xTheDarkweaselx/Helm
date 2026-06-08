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

    /// Sentinels that mean "no shift / no event" in observed rosters.
    public static let offSentinels: Set<String> = ["OFF", "-", "", "0", "REST", "RD", "X"]

    /// Sentinels that mean "shift exists but time is unknown".
    public static let tentativeSentinels: Set<String> = ["TBC", "TBD", "?"]

    public static func isOff(_ normalizedCode: String) -> Bool { offSentinels.contains(normalizedCode) }
    public static func isTentative(_ normalizedCode: String) -> Bool { tentativeSentinels.contains(normalizedCode) }
}

/// A start/end time parsed inline from a cell, in minutes-of-day.
public struct InlineTimeRange: Sendable, Equatable {
    public let startMinuteOfDay: Int
    public let endMinuteOfDay: Int

    public init(startMinuteOfDay: Int, endMinuteOfDay: Int) {
        self.startMinuteOfDay = startMinuteOfDay
        self.endMinuteOfDay = endMinuteOfDay
    }

    /// Parse ranges like "0900-1700", "09:00-17:00", "0930 - 1500", "2200–0600"
    /// (hyphen, en/em dash, optional colons and spaces). Returns nil if not a range.
    public static func parse(_ raw: String) -> InlineTimeRange? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Two time tokens separated by a dash-like character.
        let pattern = #"^(\d{1,2}):?(\d{2})\s*[-–—to]+\s*(\d{1,2}):?(\d{2})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let m = regex.firstMatch(in: s, options: [], range: range) else { return nil }

        func intAt(_ i: Int) -> Int? {
            guard let r = Range(m.range(at: i), in: s) else { return nil }
            return Int(s[r])
        }
        guard
            let sh = intAt(1), let sm = intAt(2), let eh = intAt(3), let em = intAt(4),
            (0...23).contains(sh), (0...59).contains(sm), (0...23).contains(eh), (0...59).contains(em)
        else { return nil }

        return InlineTimeRange(startMinuteOfDay: sh * 60 + sm, endMinuteOfDay: eh * 60 + em)
    }
}
