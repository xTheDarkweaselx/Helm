//
//  DayBucketer.swift
//  HelmDomain
//
//  Pure day-bucketing rules for the calendar feed.
//
//  SHIFTS: one bucket — the civil day of the shift's localDate extracted in the
//  SHIFT'S OWN time zone. Imported shifts anchor localDate at NOON in that zone
//  (RosterDateParser) and builder shifts at local midnight; extracting
//  components in the same zone yields the rota's civil day for both, and it
//  matches ShiftKey's day — so live shifts, preview-overlay keys and removed
//  items always agree. An overnight shift shows on its START day with a "+1".
//
//  EVENTS: every display-calendar day the span intersects, end-EXCLUSIVE at
//  exact midnight (normalises EventKit's 23:59:59 vs next-midnight all-day
//  conventions).
//

import Foundation

public enum DayBucketer {
    /// The single display bucket for a shift + whether it ends on a later day.
    public static func shiftDay(
        localDate: Date,
        start: Date?,
        end: Date?,
        timeZone: TimeZone
    ) -> (day: DayKey, endsOnLaterDay: Bool) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let day = DayKey(containing: localDate, in: cal)
        var endsLater = false
        if let start, let end, end > start {
            endsLater = DayKey(containing: end, in: cal) > DayKey(containing: start, in: cal)
        }
        return (day, endsLater)
    }

    /// All display days a timed/all-day span occupies, clamped to `window`.
    /// `calendar` is the DISPLAY calendar (current zone).
    public static func dayKeys(
        start: Date,
        end: Date,
        in calendar: Calendar,
        clampedTo window: ClosedRange<DayKey>? = nil
    ) -> [DayKey] {
        guard end >= start else { return [] }
        let firstDay = DayKey(containing: start, in: calendar)
        // End-exclusive: an end at EXACT midnight belongs to the previous day.
        let effectiveEnd = end > start && end == calendar.startOfDay(for: end) ? end.addingTimeInterval(-1) : end
        let lastDay = DayKey(containing: max(start, effectiveEnd), in: calendar)

        var keys: [DayKey] = []
        var day = firstDay
        // A span can't meaningfully exceed the grid; hard cap guards bad data.
        var guardrail = 0
        while day <= lastDay, guardrail < 62 {
            if window == nil || window!.contains(day) {
                keys.append(day)
            }
            day = day.advanced(by: 1, in: calendar)
            guardrail += 1
        }
        return keys
    }
}

public enum CalendarItemSort {
    /// All-day items first, then by start instant, then title (stable).
    public struct SortKey: Sendable, Comparable {
        public let isAllDay: Bool
        public let start: Date
        public let title: String

        public init(isAllDay: Bool, start: Date, title: String) {
            self.isAllDay = isAllDay
            self.start = start
            self.title = title
        }

        public static func < (l: SortKey, r: SortKey) -> Bool {
            if l.isAllDay != r.isAllDay { return l.isAllDay }
            if l.start != r.start { return l.start < r.start }
            return l.title < r.title
        }
    }
}

/// Identifies events Helm itself wrote, so the "other events" feed never
/// double-shows a shift. Three nets, because the channels differ:
/// - the dedicated calendar's title (EventKit "Helm Shifts", and the Google
///   "Helm Shifts" calendar when that account is also added to the system),
/// - the helm:// URL stamped by the EventKit writer,
/// - the "[helm:" notes tag stamped by BOTH writers (survives calendar renames;
///   Google events carry no URL field, so the tag is their only per-event mark).
public enum HelmEventSignature {
    public static let calendarTitle = "Helm Shifts"
    public static let urlScheme = "helm"
    public static let notesTag = "[helm:"

    public static func isHelmAuthored(calendarTitle: String?, urlScheme: String?, notes: String?) -> Bool {
        if calendarTitle == Self.calendarTitle { return true }
        if urlScheme == Self.urlScheme { return true }
        if notes?.contains(notesTag) == true { return true }
        return false
    }
}
