//
//  CalendarItems.swift
//  Helm
//
//  Sendable value types feeding the calendar views. EKEvent and ShiftInstance
//  never cross into view code — they're mapped to these immediately at load,
//  on the main actor, so nothing non-Sendable ever crosses isolation.
//  All nonisolated: pure data under the app target's default-MainActor mode.
//

import Foundation
import HelmDomain

/// A Helm shift, flattened for display.
nonisolated struct ShiftItem: Identifiable, Hashable, Sendable {
    let id: String                // ShiftInstance.id
    let dedupKey: String?
    let title: String
    let start: Date?
    let end: Date?
    let colorHex: String?
    let location: String?
    let endsOnLaterDay: Bool      // overnight → "+1" tag
    /// Paid hours if the source computed them (falls back to duration in UI).
    let paidHours: Double?
    /// Tentative (TBC) shifts are all-day events.
    let isAllDay: Bool
    /// v7: tags inherited from the shift type (for pills + search).
    var tags: [String] = []
    /// v7: free-text note (editable inline; searchable).
    var note: String? = nil
    /// The shift's own IANA zone (for tz-correct availability conflict math).
    var timeZoneIdentifier: String = TimeZone.current.identifier
}

/// Which provider's events the Calendar tab shows (v4.1: the view switcher).
nonisolated enum CalendarScope: String, CaseIterable, Sendable {
    case all, apple, google

    var label: String {
        switch self {
        case .all: "All"
        case .apple: "Apple"
        case .google: "Google"
        }
    }

    func includes(isGoogleSource: Bool) -> Bool {
        switch self {
        case .all: true
        case .apple: !isGoogleSource
        case .google: isGoogleSource
        }
    }
}

/// Someone-else's event (any non-Helm calendar), flattened for display.
nonisolated struct EventItem: Identifiable, Hashable, Sendable {
    struct RGBA: Hashable, Sendable {
        var r: Double, g: Double, b: Double, a: Double
    }

    /// Occurrence-unique: recurring events share eventIdentifier across occurrences.
    let id: String                // "\(eventIdentifier)#\(start.timeIntervalSinceReferenceDate)"
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarTitle: String
    let color: RGBA?
    /// From a Google account added to the system Calendar (scope switching).
    let isGoogleSource: Bool
}

/// A would-be shift from a pending import/schedule plan.
nonisolated struct PreviewItem: Identifiable, Hashable, Sendable {
    enum Status: Hashable, Sendable {
        case added, updated, removed
    }

    let id: String                // dedupKey + "#preview"
    let dedupKey: String
    let title: String
    let start: Date?
    let end: Date?
    let colorHex: String?
    let endsOnLaterDay: Bool
    let status: Status
    let isAllDay: Bool
}

/// One merged, day-bucketed feed entry.
nonisolated enum CalendarDayItem: Identifiable, Hashable, Sendable {
    case shift(ShiftItem)
    case event(EventItem)
    case preview(PreviewItem)

    var id: String {
        switch self {
        case let .shift(s): "s:\(s.id)"
        case let .event(e): "e:\(e.id)"
        case let .preview(p): "p:\(p.id)"
        }
    }

    var sortKey: CalendarItemSort.SortKey {
        switch self {
        case let .shift(s):
            CalendarItemSort.SortKey(isAllDay: s.isAllDay, start: s.start ?? .distantPast, title: s.title)
        case let .event(e):
            CalendarItemSort.SortKey(isAllDay: e.isAllDay, start: e.start, title: e.title)
        case let .preview(p):
            CalendarItemSort.SortKey(isAllDay: p.isAllDay, start: p.start ?? .distantPast, title: p.title)
        }
    }
}

/// Everything a pending Plan contributes to the calendar, prebuilt once.
nonisolated struct PreviewOverlay: Sendable {
    /// Items keyed by their display day.
    let itemsByDay: [DayKey: [PreviewItem]]
    /// Live ShiftItems with these dedupKeys are hidden while previewing
    /// (their replacement/removal is rendered by the overlay instead).
    /// = diff.updated ∪ diff.removed. Unchanged shifts stay live.
    let suppressedShiftKeys: Set<String>
    /// Where the calendar should open: the first day with a change.
    let firstChangedDay: DayKey?
}

/// How the calendar is being used.
nonisolated enum CalendarMode {
    /// The sidebar's Calendar destination: live shifts + other events.
    case live
    /// Import/schedule preview: live feed plus the plan's diff overlay.
    case preview(PreviewOverlay)

    var overlay: PreviewOverlay? {
        if case let .preview(o) = self { return o }
        return nil
    }
}

/// Month grid | hour-axis week | hour-axis day (v6).
nonisolated enum CalendarDisplayMode: String, CaseIterable, Sendable {
    case month, week, day

    var label: String {
        switch self {
        case .month: "Month"
        case .week: "Week"
        case .day: "Day"
        }
    }
}

nonisolated enum EventAccessState: Sendable {
    case notDetermined
    case fullAccess
    /// Denied, restricted, or write-only — other events can't be shown.
    case unavailable
}
