//
//  CalendarTargetProvider.swift
//  Helm
//
//  The access seam: coordinators ask for an AUTHORIZED `any CalendarTarget` for
//  a destination instead of constructing ShiftCalendarWriter directly. EventKit
//  "access" is the system prompt; Google "access" is a signed-in OAuth session.
//  Typed errors give each failure a actionable, user-facing message.
//

import Foundation
import HelmCalendar

enum CalendarAccessError: LocalizedError, Equatable {
    case eventKitDenied
    case googleNotConfigured
    case googleSignInRequired

    var errorDescription: String? {
        switch self {
        case .eventKitDenied:
            "Helm needs calendar access. Enable it for Helm in Settings, then try again."
        case .googleNotConfigured:
            "Google Calendar isn't set up. Paste your Google OAuth client ID in Helm's Settings first."
        case .googleSignInRequired:
            "Sign in to Google in Helm's Settings, then try again."
        }
    }
}

@MainActor
enum CalendarTargetProvider {
    /// Authorized targets for ALL the user's current destinations (v5: writes
    /// can fan out to Apple AND Google). Throws on the first unauthorized one
    /// — an apply must be all-or-nothing across destinations.
    static func authorizedTargets() async throws -> [any CalendarTarget] {
        try await authorizedTargets(for: CalendarDestinationSetting.current)
    }

    static func authorizedTargets(for kinds: Set<CalendarTargetKind>) async throws -> [any CalendarTarget] {
        var targets: [any CalendarTarget] = []
        for kind in kinds.sorted(by: { $0.rawValue < $1.rawValue }) {
            targets.append(try await authorizedTarget(for: kind))
        }
        return targets
    }

    static func authorizedTarget(for kind: CalendarTargetKind) async throws -> any CalendarTarget {
        switch kind {
        case .eventkit, .ics: // .ics is an export format, not a write destination
            let writer = ShiftCalendarWriter()
            guard await writer.requestAccess() else { throw CalendarAccessError.eventKitDenied }
            return writer
        case .google:
            guard GoogleConfig.isConfigured else { throw CalendarAccessError.googleNotConfigured }
            guard await GoogleAuthService.shared.isSignedIn() else { throw CalendarAccessError.googleSignInRequired }
            return GoogleCalendarTarget(tokens: GoogleAuthService.shared)
        }
    }
}
