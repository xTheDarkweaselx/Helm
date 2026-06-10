//
//  OtherEventsReader.swift
//  Helm
//
//  Reads the user's OTHER calendar events (any account in the system Calendar:
//  iCloud, Google, Exchange…) for the calendar view, excluding everything Helm
//  itself wrote. Synchronous on the main actor by design: a ±1-month
//  predicateForEvents fetch is milliseconds, runs from .task (off the body
//  path), and keeps non-Sendable EKEvents from ever crossing isolation —
//  they're mapped to EventItem values in the same pass.
//

import Foundation
import EventKit
import HelmDomain

/// Which system calendars the user has hidden in the Calendar tab (v4).
nonisolated enum CalendarSourceFilter {
    static let key = "calendarHiddenCalendarIDs"

    static var hiddenIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    static func setHidden(_ hidden: Bool, id: String) {
        var ids = hiddenIDs
        if hidden { ids.insert(id) } else { ids.remove(id) }
        UserDefaults.standard.set(Array(ids).sorted(), forKey: key)
    }
}

/// A toggleable calendar source shown in the filter menu.
nonisolated struct CalendarChoice: Identifiable, Hashable, Sendable {
    let id: String          // calendarIdentifier
    let title: String
    let sourceTitle: String // account: "iCloud", "Google", "On My Mac", …
    let color: EventItem.RGBA?
}

@MainActor
final class OtherEventsReader {
    /// Created lazily only AFTER full access is granted: a store created while
    /// undetermined/denied can keep returning empty results post-grant.
    private var store: EKEventStore?
    private var needsSourceRefresh = false

    var accessState: EventAccessState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .fullAccess
        case .notDetermined: .notDetermined
        default: .unavailable
        }
    }

    /// Ask for access if undetermined (same full-access request the write path
    /// already uses — whichever side asks first settles it for both).
    func ensureAccess() async -> EventAccessState {
        if case .notDetermined = accessState {
            let requestStore = EKEventStore()
            _ = try? await requestStore.requestFullAccessToEvents()
        }
        return accessState
    }

    /// Note an EKEventStoreChanged so the next load refreshes sources.
    func noteStoreChanged() {
        needsSourceRefresh = true
    }

    private func activeStore() -> EKEventStore {
        let store = self.store ?? {
            let s = EKEventStore()
            self.store = s
            return s
        }()
        if needsSourceRefresh {
            store.refreshSourcesIfNecessary()
            needsSourceRefresh = false
        }
        return store
    }

    private nonisolated func rgba(from cgColor: CGColor?) -> EventItem.RGBA? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let components = cgColor?.converted(to: srgb, intent: .defaultIntent, options: nil)?.components,
              components.count >= 4
        else { return nil }
        return EventItem.RGBA(r: components[0], g: components[1], b: components[2], a: components[3])
    }

    /// Every calendar the filter menu can toggle (non-Helm), grouped-ready
    /// (sorted by account then title).
    func availableCalendars() -> [CalendarChoice] {
        guard case .fullAccess = accessState else { return [] }
        let store = activeStore()
        return store.calendars(for: .event)
            .filter { $0.title != HelmEventSignature.calendarTitle }
            .map { cal in
                CalendarChoice(
                    id: cal.calendarIdentifier,
                    title: cal.title,
                    sourceTitle: cal.source?.title ?? "Other",
                    color: rgba(from: cal.cgColor)
                )
            }
            .sorted { ($0.sourceTitle, $0.title) < ($1.sourceTitle, $1.title) }
    }

    /// All non-Helm, non-hidden events intersecting [from, to], mapped to values.
    func load(from: Date, to: Date) -> [EventItem] {
        guard case .fullAccess = accessState else { return [] }
        let store = activeStore()

        // Skip Helm's own calendar(s) and user-hidden calendars up front;
        // catch strays per-event below.
        let hidden = CalendarSourceFilter.hiddenIDs
        let calendars = store.calendars(for: .event)
            .filter { $0.title != HelmEventSignature.calendarTitle && !hidden.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }

        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
        return store.events(matching: predicate).compactMap { event in
            if HelmEventSignature.isHelmAuthored(
                calendarTitle: event.calendar?.title,
                urlScheme: event.url?.scheme,
                notes: event.notes
            ) {
                return nil
            }
            guard let start = event.startDate, let end = event.endDate else { return nil }
            let color = rgba(from: event.calendar?.cgColor)
            return EventItem(
                id: "\(event.eventIdentifier ?? event.calendarItemIdentifier)#\(start.timeIntervalSinceReferenceDate)",
                title: event.title ?? "Event",
                start: start,
                end: end,
                isAllDay: event.isAllDay,
                calendarTitle: event.calendar?.title ?? "",
                color: color
            )
        }
    }
}
