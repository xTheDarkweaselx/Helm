//
//  ReminderSetting.swift
//  Helm
//
//  Default shift reminders, applied to written calendar events as EKAlarms /
//  Google reminder overrides / .ics VALARMs. v4: MULTIPLE offsets (CSV in
//  UserDefaults), with per-roster overrides on Roster.reminderOffsetsRaw
//  (nil = inherit this global default, "" = explicitly none).
//  Stored via UserDefaults so non-View code (RosterSyncEngine) can read it.
//

import Foundation
import HelmDomain

nonisolated enum ReminderSetting {
    /// Legacy single-value key (v2.1–v3); migrated on first read.
    static let legacyKey = "reminderMinutesBefore"
    /// v4 multi-value key (canonical CSV, "" = none).
    static let offsetsKey = "reminderOffsetsCSV"
    /// Default when the user never chose: 1 hour before.
    static let fallback = [60]

    static let presets: [(label: String, minutes: Int)] = [
        ("At start of shift", 0),
        ("30 minutes before", 30),
        ("1 hour before", 60),
        ("2 hours before", 120),
        ("12 hours before", 720),
        ("1 day before", 1440),
    ]

    /// The global default offsets (minutes before start), [] = no reminders.
    static var offsets: [Int] {
        let defaults = UserDefaults.standard
        if let csv = defaults.string(forKey: offsetsKey) {
            return ReminderOffsets.parse(csv)
        }
        // Migrate the legacy single value (-1 was the "None" sentinel).
        if defaults.object(forKey: legacyKey) != nil {
            let legacy = defaults.integer(forKey: legacyKey)
            let migrated = legacy >= 0 ? [legacy] : []
            defaults.set(ReminderOffsets.encode(migrated), forKey: offsetsKey)
            return migrated
        }
        return fallback
    }

    static func setOffsets(_ offsets: [Int]) {
        UserDefaults.standard.set(ReminderOffsets.encode(offsets), forKey: offsetsKey)
    }

    static func label(for minutes: Int) -> String {
        presets.first { $0.minutes == minutes }?.label ?? "\(minutes) minutes before"
    }

    /// Short summary for UI rows: "1 hour + 12 hours before", "None".
    static func summary(for offsets: [Int]) -> String {
        guard !offsets.isEmpty else { return "None" }
        return offsets.sorted().map { compactLabel(for: $0) }.joined(separator: " + ") + " before"
    }

    private static func compactLabel(for minutes: Int) -> String {
        switch minutes {
        case 0: "at start"
        case let m where m % 1440 == 0: "\(m / 1440) day\(m == 1440 ? "" : "s")"
        case let m where m % 60 == 0: "\(m / 60) hour\(m == 60 ? "" : "s")"
        default: "\(minutes) min"
        }
    }
}
