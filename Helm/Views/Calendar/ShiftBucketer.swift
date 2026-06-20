//
//  ShiftBucketer.swift
//  Helm
//
//  The single place a [ShiftInstance] is flattened into per-day display items for
//  the month grids. It lives here (not in the nonisolated CalendarItems.swift)
//  because reading a @Model is MainActor work: this type is MainActor-isolated by
//  the app target's default — no explicit attribute — and it emits the
//  nonisolated, Sendable ShiftItem. Both the Calendar tab (CalendarView) and the
//  roster-detail Calendar view mode (ShiftListView) bucket through here, so the
//  ShiftInstance → ShiftItem field mapping can't silently diverge — it already
//  had (the roster copy dropped DayBucketer's overnight `endsOnLaterDay` flag).
//

import Foundation
import HelmDomain

enum ShiftBucketer {
    /// Bucket instances by their OWN-timezone civil day (a per-zone Calendar is
    /// cached), skipping any whose `dedupKey` is in `suppressed` (the Calendar tab
    /// hides shifts a pending preview overlay re-renders). Each bucketed value is
    /// `transform(instance, endsOnLaterDay)`, where `endsOnLaterDay` is
    /// DayBucketer's overnight flag — so a caller can map to a ShiftItem (with the
    /// correct flag) or keep the instance, sharing one pass + one zone cache.
    static func byDay<Value>(
        _ instances: [ShiftInstance],
        suppressing suppressed: Set<String> = [],
        focus: ShiftFocus = .all,
        _ transform: (ShiftInstance, Bool) -> Value
    ) -> [DayKey: [Value]] {
        var calendarByZone: [String: Calendar] = [:]
        var byDay: [DayKey: [Value]] = [:]
        for instance in instances {
            if let key = instance.dedupKey, suppressed.contains(key) { continue }
            guard focus.matches(instance) else { continue } // v9 Shift Focus
            guard let localDate = instance.localDate else { continue }
            let zoneID = instance.timeZoneIdentifier
            let cal = calendarByZone[zoneID] ?? {
                var c = Calendar(identifier: .gregorian)
                c.timeZone = TimeZone(identifier: zoneID) ?? .current
                calendarByZone[zoneID] = c
                return c
            }()
            let (day, endsLater) = DayBucketer.shiftDay(
                localDate: localDate, start: instance.startUTC, end: instance.endUTC, calendar: cal
            )
            byDay[day, default: []].append(transform(instance, endsLater))
        }
        return byDay
    }

    /// Shifts → display ShiftItems, bucketed by day — the month grids' feed.
    static func itemsByDay(
        _ instances: [ShiftInstance],
        suppressing suppressed: Set<String> = [],
        focus: ShiftFocus = .all
    ) -> [DayKey: [ShiftItem]] {
        byDay(instances, suppressing: suppressed, focus: focus) { item(from: $0, endsOnLaterDay: $1) }
    }

    /// The SINGLE ShiftInstance → ShiftItem field mapping (previously copied in
    /// both views, where the copies had diverged on `endsOnLaterDay`).
    static func item(from instance: ShiftInstance, endsOnLaterDay: Bool) -> ShiftItem {
        ShiftItem(
            id: instance.id,
            dedupKey: instance.dedupKey,
            title: instance.title ?? instance.shiftType?.label ?? instance.shiftType?.code ?? "Shift",
            start: instance.startUTC,
            end: instance.endUTC,
            colorHex: instance.shiftType?.colorHex,
            location: instance.locationName,
            endsOnLaterDay: endsOnLaterDay,
            paidHours: instance.computedPaidHours,
            isAllDay: instance.isAllDay ?? false,
            tags: instance.shiftType?.tags ?? [],
            note: instance.note,
            timeZoneIdentifier: instance.timeZoneIdentifier
        )
    }
}
