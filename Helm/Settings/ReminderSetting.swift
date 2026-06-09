//
//  ReminderSetting.swift
//  Helm
//
//  The default shift reminder, applied to written calendar events as an EKAlarm
//  (and to exported .ics VALARMs). Stored in UserDefaults so non-View code
//  (RosterSyncEngine) can read it; the Settings UI binds the same key via @AppStorage.
//

import Foundation

enum ReminderSetting {
    static let key = "reminderMinutesBefore"
    /// Sentinel for "no reminder".
    static let none = -1
    /// Default when the user hasn't chosen yet: 1 hour before.
    static let fallback = 60

    static let presets: [(label: String, minutes: Int)] = [
        ("None", none),
        ("At start of shift", 0),
        ("30 minutes before", 30),
        ("1 hour before", 60),
        ("2 hours before", 120),
        ("12 hours before", 720),
    ]

    /// Current selection (minutes before start), honouring the fallback when unset.
    static var minutesBefore: Int {
        UserDefaults.standard.object(forKey: key) == nil
            ? fallback
            : UserDefaults.standard.integer(forKey: key)
    }

    /// Alarm offsets to stamp on events ([] when reminders are off).
    static var offsets: [Int] {
        let m = minutesBefore
        return m >= 0 ? [m] : []
    }

    static func label(for minutes: Int) -> String {
        presets.first { $0.minutes == minutes }?.label ?? "\(minutes) minutes before"
    }
}
