//
//  ShiftCalendarWriter.swift
//  Helm
//
//  EventKit adapter for the HelmCalendar `CalendarTarget` protocol (ADR-1).
//  Requests FULL access (ADR-2), writes into a dedicated "Helm Shifts" calendar,
//  and upserts idempotently keyed by a helm:// URL stamped on each event (ADR-3)
//  so re-import updates in place; removals delete exactly the matching events.
//

import Foundation
import EventKit
import OSLog
import HelmCalendar

@MainActor
final class ShiftCalendarWriter: CalendarTarget {
    nonisolated let kind = "eventkit"

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

    static let calendarTitle = "Helm Shifts"
    static let urlScheme = "helm"

    private let store = EKEventStore()
    private let log = Logger(subsystem: "Fusion-Studios.Helm", category: "Calendar")

    // MARK: - Access

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
        if let existing = existingCalendar(writableOnly: true) { return existing }

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

    // MARK: - CalendarTarget

    @discardableResult
    func write(_ drafts: [CalendarEventDraft]) async throws -> [CalendarWriteResult] {
        guard authorizationStatus == .fullAccess else { throw WriterError.accessDenied }
        guard !drafts.isEmpty else { return [] }
        let calendar = try ensureHelmCalendar()

        var existingByURL = helmEvents(in: calendar,
                                       from: drafts.map(\.start).min()!,
                                       to: drafts.map(\.end).max()!)

        // v7.3: a single-draft EDIT can move a shift far outside the windowed
        // lookup (±1 day padding) — missing the old event would create a
        // DUPLICATE instead of moving it. For the single-draft path, fall back
        // once to the wide scan so the upsert always reattaches to the original
        // event. (Bulk imports write at source dates — always in-window — and
        // must not pay a wide scan per chunk.)
        if drafts.count == 1, let draft = drafts.first {
            let url = eventURL(for: draft.dedupKey).absoluteString
            if existingByURL[url] == nil {
                for event in allHelmEvents(in: calendar) {
                    if event.url?.absoluteString == url {
                        existingByURL[url] = event
                        break
                    }
                }
            }
        }

        var staged: [(key: String, action: CalendarWriteAction, event: EKEvent)] = []
        for draft in drafts {
            let url = eventURL(for: draft.dedupKey)
            let event: EKEvent
            let action: CalendarWriteAction
            if let existing = existingByURL[url.absoluteString] {
                event = existing; action = .updated
            } else {
                event = EKEvent(eventStore: store); action = .added
            }
            existingByURL[url.absoluteString] = event // guard in-batch key collisions

            event.calendar = calendar
            event.title = draft.title
            event.location = draft.location
            event.notes = draft.notes ?? "Imported by Helm. Do not edit the URL tag.\n[\(Self.urlScheme):\(draft.dedupKey)]"
            event.startDate = draft.start
            event.endDate = draft.end
            event.isAllDay = draft.isAllDay
            event.timeZone = TimeZone(identifier: draft.timeZoneIdentifier)
            event.url = url
            event.alarms = draft.alarmOffsetsMinutes.map { EKAlarm(relativeOffset: TimeInterval(-$0 * 60)) }

            try store.save(event, span: .thisEvent, commit: false)
            staged.append((draft.dedupKey, action, event))
        }
        try store.commit()

        return staged.map { CalendarWriteResult(dedupKey: $0.key, action: $0.action, eventIdentifier: $0.event.eventIdentifier) }
    }

    @discardableResult
    func remove(dedupKeys: [String]) async throws -> Int {
        guard authorizationStatus == .fullAccess else { throw WriterError.accessDenied }
        guard !dedupKeys.isEmpty, let calendar = existingCalendar() else { return 0 }
        let targets = Set(dedupKeys.map { eventURL(for: $0).absoluteString })
        var removed = 0
        for event in allHelmEvents(in: calendar) where event.url.map({ targets.contains($0.absoluteString) }) == true {
            try store.remove(event, span: .thisEvent, commit: false)
            removed += 1
        }
        if removed > 0 { try store.commit() }
        return removed
    }

    @discardableResult
    func removeAll() async throws -> Int {
        guard authorizationStatus == .fullAccess else { throw WriterError.accessDenied }
        guard let calendar = existingCalendar() else { return 0 }
        var removed = 0
        for event in allHelmEvents(in: calendar) {
            try store.remove(event, span: .thisEvent, commit: false)
            removed += 1
        }
        if removed > 0 { try store.commit() }
        return removed
    }

    // MARK: - Helpers

    private func existingCalendar(writableOnly: Bool = false) -> EKCalendar? {
        store.calendars(for: .event).first {
            $0.title == Self.calendarTitle && (!writableOnly || $0.allowsContentModifications)
        }
    }

    private func helmEvents(in calendar: EKCalendar, from start: Date, to end: Date) -> [String: EKEvent] {
        let cal = Calendar.current
        let predicate = store.predicateForEvents(
            withStart: cal.date(byAdding: .day, value: -1, to: start) ?? start,
            end: cal.date(byAdding: .day, value: 1, to: end) ?? end,
            calendars: [calendar]
        )
        var map: [String: EKEvent] = [:]
        for event in store.events(matching: predicate) {
            if let s = event.url?.absoluteString, s.hasPrefix("\(Self.urlScheme):") { map[s] = event }
        }
        return map
    }

    private func allHelmEvents(in calendar: EKCalendar) -> [EKEvent] {
        // EventKit's predicateForEvents only matches within ~4 years of its start,
        // so scan a wide horizon in 3-year chunks and dedupe boundary overlaps.
        let cal = Calendar.current
        let now = Date.now
        let start = cal.date(byAdding: .year, value: -10, to: now)!
        let end = cal.date(byAdding: .year, value: 10, to: now)!
        var byID: [String: EKEvent] = [:]
        var windowStart = start
        while windowStart < end {
            let windowEnd = min(end, cal.date(byAdding: .year, value: 3, to: windowStart) ?? end)
            let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [calendar])
            for event in store.events(matching: predicate)
            where (event.url?.absoluteString.hasPrefix("\(Self.urlScheme):")) == true {
                byID[event.eventIdentifier ?? event.calendarItemIdentifier] = event
            }
            windowStart = windowEnd
        }
        return Array(byID.values)
    }

    private func eventURL(for dedupKey: String) -> URL {
        let encoded = dedupKey.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? dedupKey
        return URL(string: "\(Self.urlScheme)://shift/\(encoded)")!
    }
}
