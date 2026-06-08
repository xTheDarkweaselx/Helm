//
//  ShiftCalendarWriter.swift
//  Helm
//
//  v0 EventKit write path (DEVELOPMENT_PLAN.md Phase v0). Requests FULL calendar
//  access (ADR-2), writes shifts into a dedicated "Helm Shifts" calendar, and
//  upserts idempotently keyed by a helm:// URL stamped on each event (ADR-3), so
//  re-import updates in place instead of duplicating. Batched commit for speed.
//
//  This is the concrete EventKit adapter; it will be adapted to the HelmCalendar
//  `CalendarTarget` protocol once the HelmCore package is linked into the app.
//

import Foundation
import EventKit
import OSLog

@MainActor
final class ShiftCalendarWriter {
    enum WriterError: LocalizedError {
        case accessDenied
        case noWritableSource

        var errorDescription: String? {
            switch self {
            case .accessDenied: "Helm needs full calendar access to add and update your shifts."
            case .noWritableSource: "No writable calendar account was found on this device."
            }
        }
    }

    struct Summary: Sendable, Equatable {
        var added = 0
        var updated = 0
        var skipped = 0
    }

    static let calendarTitle = "Helm Shifts"
    static let urlScheme = "helm"

    private let store = EKEventStore()
    private let log = Logger(subsystem: "Fusion-Studios.Helm", category: "Calendar")

    /// Request full access (needed to read back our events for idempotent re-import).
    func requestAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            log.error("Calendar access request failed: \(error, privacy: .public)")
            return false
        }
    }

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// Find or create the dedicated "Helm Shifts" calendar on a writable source
    /// (prefer iCloud so it syncs, else local).
    func ensureHelmCalendar() throws -> EKCalendar {
        if let existing = store.calendars(for: .event).first(where: {
            $0.title == Self.calendarTitle && $0.allowsContentModifications
        }) {
            return existing
        }

        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = Self.calendarTitle

        let sources = store.sources
        let source = sources.first(where: { $0.sourceType == .calDAV && $0.title.lowercased().contains("icloud") })
            ?? sources.first(where: { $0.sourceType == .local })
            ?? store.defaultCalendarForNewEvents?.source
        guard let source else { throw WriterError.noWritableSource }
        calendar.source = source

        try store.saveCalendar(calendar, commit: true)
        return calendar
    }

    /// Idempotently upsert the given instances into the Helm calendar.
    @discardableResult
    func upsert(_ instances: [ShiftInstance]) throws -> Summary {
        guard authorizationStatus == .fullAccess else { throw WriterError.accessDenied }

        let calendar = try ensureHelmCalendar()
        var summary = Summary()

        // Only instances with a resolved time window and a key can be written.
        let writable = instances.filter { $0.startUTC != nil && $0.endUTC != nil && key(for: $0) != nil }
        summary.skipped = instances.count - writable.count
        guard !writable.isEmpty else { return summary }

        // Pre-fetch existing Helm events across the span and index by our URL.
        let minStart = writable.compactMap(\.startUTC).min()!
        let maxEnd = writable.compactMap(\.endUTC).max()!
        let cal = Calendar.current
        let predicate = store.predicateForEvents(
            withStart: cal.date(byAdding: .day, value: -1, to: minStart) ?? minStart,
            end: cal.date(byAdding: .day, value: 1, to: maxEnd) ?? maxEnd,
            calendars: [calendar]
        )
        var existingByURL: [String: EKEvent] = [:]
        for event in store.events(matching: predicate) {
            if let urlString = event.url?.absoluteString, urlString.hasPrefix("\(Self.urlScheme):") {
                existingByURL[urlString] = event
            }
        }

        for instance in writable {
            guard let dedup = key(for: instance),
                  let start = instance.startUTC, let end = instance.endUTC else { continue }
            let url = eventURL(for: dedup)

            let event: EKEvent
            if let existing = existingByURL[url.absoluteString] {
                event = existing
                summary.updated += 1
            } else {
                event = EKEvent(eventStore: store)
                summary.added += 1
            }

            event.calendar = calendar
            event.title = instance.title ?? instance.shiftType?.label ?? instance.shiftType?.code ?? "Shift"
            event.location = instance.locationName
            event.notes = "Imported by Helm. Do not edit the URL tag.\n[\(Self.urlScheme):\(dedup)]"
            event.startDate = start
            event.endDate = end
            event.timeZone = TimeZone(identifier: instance.timeZoneIdentifier)
            event.url = url
            event.alarms = (instance.shiftType?.defaultAlarmOffsets ?? []).map {
                EKAlarm(relativeOffset: TimeInterval(-$0 * 60))
            }

            try store.save(event, span: .thisEvent, commit: false)
        }

        try store.commit()
        return summary
    }

    /// Remove every event Helm created in its calendar (the "remove all Helm shifts" affordance).
    @discardableResult
    func removeAllHelmShifts() throws -> Int {
        guard authorizationStatus == .fullAccess else { throw WriterError.accessDenied }
        guard let calendar = store.calendars(for: .event).first(where: { $0.title == Self.calendarTitle }) else { return 0 }
        let cal = Calendar.current
        let now = Date.now
        let predicate = store.predicateForEvents(
            withStart: cal.date(byAdding: .year, value: -5, to: now)!,
            end: cal.date(byAdding: .year, value: 5, to: now)!,
            calendars: [calendar]
        )
        var removed = 0
        for event in store.events(matching: predicate) {
            try store.remove(event, span: .thisEvent, commit: false)
            removed += 1
        }
        try store.commit()
        return removed
    }

    // MARK: - Keys

    private func key(for instance: ShiftInstance) -> String? {
        instance.dedupKey ?? (instance.localDate != nil ? instance.id : nil)
    }

    private func eventURL(for dedupKey: String) -> URL {
        let encoded = dedupKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? dedupKey
        return URL(string: "\(Self.urlScheme)://shift/\(encoded)")!
    }
}
