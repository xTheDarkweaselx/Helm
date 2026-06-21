//
//  CalendarDestinationSetting.swift
//  Helm
//
//  Which calendars new/updated shifts are written to. v5: a SET — Apple and
//  Google can both be selected and every apply writes to all of them. Google
//  membership is gated on actually being usable (configured + signed in) so a
//  write is never stranded behind a signed-out account. Each roster remembers
//  its own destination set (ImportProfile.targets) so lifecycle operations
//  clean up every calendar its events actually live in.
//

import Foundation

nonisolated enum CalendarDestinationSetting {
    /// Legacy single-destination key (v2.3–v4); migrated on first read.
    static let legacyKey = "calendarDestination"
    /// v5 multi-destination key: CSV of CalendarTargetKind raw values.
    static let key = "calendarDestinations"

    static func parse(_ csv: String) -> Set<CalendarTargetKind> {
        Set(csv.split(separator: ",").compactMap { CalendarTargetKind(rawValue: String($0)) })
    }

    static func encode(_ kinds: Set<CalendarTargetKind>) -> String {
        kinds.map(\.rawValue).sorted().joined(separator: ",")
    }

    /// What the user picked (members may be temporarily unusable). Never empty.
    static var chosenKinds: Set<CalendarTargetKind> {
        let defaults = UserDefaults.standard
        if let csv = defaults.string(forKey: key) {
            let kinds = parse(csv)
            return kinds.isEmpty ? [.eventkit] : kinds
        }
        // Migrate the legacy single value.
        if let raw = defaults.string(forKey: legacyKey), let kind = CalendarTargetKind(rawValue: raw) {
            defaults.set(encode([kind]), forKey: key)
            return [kind]
        }
        return [.eventkit]
    }

    static func setChosen(_ kinds: Set<CalendarTargetKind>) {
        UserDefaults.standard.set(encode(kinds.isEmpty ? [.eventkit] : kinds), forKey: key)
    }

    /// The destinations writes actually go to right now (Google dropped while
    /// signed out; falls back to Apple rather than nowhere).
    static var current: Set<CalendarTargetKind> {
        var kinds = chosenKinds
        if kinds.contains(.google), !(GoogleConfig.isConfigured && GoogleConfig.isSignedIn) {
            kinds.remove(.google)
        }
        return kinds.isEmpty ? [.eventkit] : kinds
    }
}
