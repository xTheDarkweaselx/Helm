//
//  ReminderOffsets.swift
//  HelmDomain
//
//  v4: multiple reminders. Offsets (minutes before start) round-trip through a
//  CSV string — UserDefaults for the global default, an optional model field
//  for per-roster overrides (nil = inherit, "" = explicitly none).
//

import Foundation

public enum ReminderOffsets {
    /// EventKit is unbounded but Google caps at 5 overrides; one shared cap
    /// keeps every destination's behavior identical.
    public static let maxCount = 5
    /// Google's minutes bound (28 days); fine for EventKit/ICS too.
    public static let maxMinutes = 40_320

    /// "720,60" → [60, 720] — sorted ascending, deduplicated, clamped, capped.
    public static func parse(_ csv: String) -> [Int] {
        let values = csv.split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .map { min(max($0, 0), maxMinutes) }
        return Array(Set(values)).sorted().prefix(maxCount).map { $0 }
    }

    /// Canonical encoding (sorted, deduplicated): [720, 60] → "60,720".
    public static func encode(_ offsets: [Int]) -> String {
        Array(Set(offsets.map { min(max($0, 0), maxMinutes) }))
            .sorted().prefix(maxCount)
            .map(String.init).joined(separator: ",")
    }
}

/// Half-open interval overlap, the rota convention: a shift ending 13:30 does
/// NOT conflict with an event starting 13:30.
public enum IntervalOverlap {
    public static func intersects(_ aStart: Date, _ aEnd: Date, _ bStart: Date, _ bEnd: Date) -> Bool {
        aStart < bEnd && bStart < aEnd
    }
}
