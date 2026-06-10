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

    /// All non-Helm events intersecting [from, to], mapped to values.
    func load(from: Date, to: Date) -> [EventItem] {
        guard case .fullAccess = accessState else { return [] }
        let store = self.store ?? {
            let s = EKEventStore()
            self.store = s
            return s
        }()
        if needsSourceRefresh {
            store.refreshSourcesIfNecessary()
            needsSourceRefresh = false
        }

        // Skip Helm's own calendar(s) up front; catch strays per-event below.
        let calendars = store.calendars(for: .event)
            .filter { $0.title != HelmEventSignature.calendarTitle }
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
            let color: EventItem.RGBA? = (event.calendar?.cgColor?.converted(
                to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil
            )?.components).flatMap { c in
                c.count >= 4 ? EventItem.RGBA(r: c[0], g: c[1], b: c[2], a: c[3]) : nil
            }
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
