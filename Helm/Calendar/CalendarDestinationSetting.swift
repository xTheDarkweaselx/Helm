//
//  CalendarDestinationSetting.swift
//  Helm
//
//  Which calendar new/updated shifts are written to (mirrors ReminderSetting's
//  UserDefaults pattern). Apple Calendar unless the user chose Google AND Google
//  is actually usable right now — never strand a write behind a signed-out
//  account. Each roster also remembers its own destination (ImportProfile.target)
//  so lifecycle operations clean up the calendar the shifts actually live in.
//

import Foundation

enum CalendarDestinationSetting {
    static let key = "calendarDestination"

    /// What the user picked (may be temporarily unusable).
    static var chosen: CalendarTargetKind {
        UserDefaults.standard.string(forKey: key)
            .flatMap(CalendarTargetKind.init(rawValue:)) ?? .eventkit
    }

    /// The destination writes actually go to right now.
    static var current: CalendarTargetKind {
        let kind = chosen
        if kind == .google, !(GoogleConfig.isConfigured && GoogleConfig.isSignedIn) {
            return .eventkit
        }
        return kind
    }
}
