//
//  HelmSnapshot.swift
//  HelmDomain
//
//  v7 widgets: the SHARED data contract between the app and the (staged) widget
//  extension. The app projects its live shifts into a small Codable HelmSnapshot
//  and writes it to the App Group container; the widget reads it back. Pure and
//  Foundation-only so BOTH targets compile it identically and the snapshot
//  shape is unit-tested. The single next-shift RULE also lives here so the
//  dashboard, Siri and the widget can never disagree about what "next" means.
//

import Foundation

/// App Group constants — the one place the container id / filename / suite live.
public enum HelmAppGroup {
    /// Must match the App Groups capability added to BOTH the app and the widget
    /// (a sub-identifier of the Fusion-Studios.Helm bundle family).
    public static let identifier = "group.Fusion-Studios.Helm"
    /// JSON file written into the group container (the primary channel).
    public static let snapshotFilename = "helm-snapshot.json"
    /// UserDefaults suite (same id) — a redundant mirror channel.
    public static let defaultsSuite = identifier
    /// Key under which the JSON-encoded snapshot is mirrored in the suite.
    public static let snapshotDefaultsKey = "helm.snapshot.v1"
    /// WatchConnectivity applicationContext key the iPhone pushes the snapshot
    /// under (v7.5 — the watch is a separate device; the App Group does not
    /// cross to it). The watch stores the received blob under
    /// `snapshotDefaultsKey` in ITS OWN suite, so SnapshotStore reads verbatim.
    public static let watchSnapshotContextKey = "helm.snapshot.v1.watch"
}

/// A shift as the widget needs to show it (Codable for the cross-process hop).
public struct SnapshotShift: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let location: String?
    public let colorHex: String?
    public let start: Date?
    public let end: Date?
    public let isAllDay: Bool
    /// v7.5 (optional → v1-blob compatible): an IMPORTED tentative (TBC) row —
    /// distinct from a deliberate user-made all-day shift. nil reads as false.
    public let isTentative: Bool?

    public init(id: String, title: String, location: String?, colorHex: String?, start: Date?, end: Date?, isAllDay: Bool, isTentative: Bool? = nil) {
        self.id = id
        self.title = title
        self.location = location
        self.colorHex = colorHex
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isTentative = isTentative
    }
}

/// One civil day of the current week (v7.5 — feeds the week-overview widget
/// and the watch app).
public struct SnapshotDay: Codable, Sendable, Equatable, Identifiable {
    /// Start-of-day in the calendar the snapshot was built with.
    public let date: Date
    public let shifts: [SnapshotShift]

    public var id: Date { date }

    public init(date: Date, shifts: [SnapshotShift]) {
        self.date = date
        self.shifts = shifts
    }
}

/// The whole shared snapshot. `version` guards the widget against an older app.
public struct HelmSnapshot: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let version: Int
    public let generatedAt: Date
    public let next: SnapshotShift?
    public let today: [SnapshotShift]
    public let weekHours: Double
    public let weekShiftCount: Int
    /// The shift happening right now, if any (drives the Live Activity / "on now").
    public let current: SnapshotShift?
    // v7.5 additions — ALL optional so a v1 blob (older app, newer widget) and
    // a v1.5 blob (newer app, older widget) both decode cleanly.
    /// The current locale week, 7 entries from its first day.
    public let weekDays: [SnapshotDay]?
    /// Hours of this week's shifts that have already ENDED (gauge numerator;
    /// `weekHours` is the denominator).
    public let weekHoursCompleted: Double?
    /// Imported tentative (TBC) shifts in the week — surfaced as a badge.
    public let weekTBCCount: Int?

    public init(
        version: Int = HelmSnapshot.schemaVersion,
        generatedAt: Date,
        next: SnapshotShift?,
        today: [SnapshotShift],
        weekHours: Double,
        weekShiftCount: Int,
        current: SnapshotShift?,
        weekDays: [SnapshotDay]? = nil,
        weekHoursCompleted: Double? = nil,
        weekTBCCount: Int? = nil
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.next = next
        self.today = today
        self.weekHours = weekHours
        self.weekShiftCount = weekShiftCount
        self.current = current
        self.weekDays = weekDays
        self.weekHoursCompleted = weekHoursCompleted
        self.weekTBCCount = weekTBCCount
    }

    public static let empty = HelmSnapshot(generatedAt: .distantPast, next: nil, today: [], weekHours: 0, weekShiftCount: 0, current: nil)
}

/// The value the builder consumes (projected from a SwiftData ShiftInstance).
public struct SnapshotInputShift: Sendable, Equatable {
    public let id: String
    public let title: String
    public let location: String?
    public let colorHex: String?
    public let start: Date?
    public let end: Date?
    public let localDate: Date?
    public let isAllDay: Bool
    public let paidHours: Double?
    /// v7.5: imported tentative (TBC) row, vs a deliberate all-day shift.
    public let isTentative: Bool

    public init(id: String, title: String, location: String?, colorHex: String?, start: Date?, end: Date?, localDate: Date?, isAllDay: Bool, paidHours: Double?, isTentative: Bool = false) {
        self.id = id
        self.title = title
        self.location = location
        self.colorHex = colorHex
        self.start = start
        self.end = end
        self.localDate = localDate
        self.isAllDay = isAllDay
        self.paidHours = paidHours
        self.isTentative = isTentative
    }
}

/// THE next-shift rule, as a pure function over value snapshots. The app's
/// `NextShiftSelector` maps its @Model objects through this so the screen, Siri
/// and the widget share one definition. Tie-break: an all-day (TBC) day wins
/// only when its civil day is STRICTLY earlier than the next timed shift's.
public enum NextShiftRule {
    public struct Candidate: Sendable, Equatable {
        public let id: String
        public let isAllDay: Bool
        public let start: Date?      // startUTC for timed shifts
        public let localDate: Date?  // civil-day anchor for all-day shifts

        public init(id: String, isAllDay: Bool, start: Date?, localDate: Date?) {
            self.id = id
            self.isAllDay = isAllDay
            self.start = start
            self.localDate = localDate
        }
    }

    /// The id of the next shift, or nil. Behaviour-preserving port of the v6
    /// NextShiftSelector logic.
    public static func nextID(in candidates: [Candidate], now: Date, calendar: Calendar) -> String? {
        let todayStart = calendar.startOfDay(for: now)
        let nextTimed = candidates
            .filter { !$0.isAllDay }
            .compactMap { c in c.start.map { (c, $0) } }
            .filter { $0.1 > now }
            .min { $0.1 < $1.1 }
        let nextAllDay = candidates
            .filter { $0.isAllDay && ($0.localDate ?? .distantPast) >= todayStart }
            .min { ($0.localDate ?? .distantFuture) < ($1.localDate ?? .distantFuture) }
        switch (nextTimed, nextAllDay) {
        case (nil, nil): return nil
        case let (timed?, nil): return timed.0.id
        case let (nil, allDay?): return allDay.id
        case let (timed?, allDay?):
            let allDayDay = allDay.localDate.map { calendar.startOfDay(for: $0) } ?? .distantFuture
            return allDayDay < calendar.startOfDay(for: timed.1) ? allDay.id : timed.0.id
        }
    }
}

/// Builds the shared snapshot from live shift projections.
public enum HelmSnapshotBuilder {
    public static func build(shifts: [SnapshotInputShift], now: Date, calendar: Calendar) -> HelmSnapshot {
        let today = DayKey(containing: now, in: calendar)

        // Next shift (one rule, everywhere).
        let candidates = shifts.map { NextShiftRule.Candidate(id: $0.id, isAllDay: $0.isAllDay, start: $0.start, localDate: $0.localDate) }
        let nextID = NextShiftRule.nextID(in: candidates, now: now, calendar: calendar)
        let next = nextID.flatMap { id in shifts.first { $0.id == id } }.map(snapshotShift(from:))

        // Today's shifts (civil-day membership), timed first then all-day, by start.
        let todays = shifts
            .filter { ($0.localDate).map { DayKey(containing: $0, in: calendar) == today } ?? false }
            .sorted { lhs, rhs in
                (lhs.start ?? .distantFuture) < (rhs.start ?? .distantFuture)
            }
            .map(snapshotShift(from:))

        // Currently on shift.
        let current = shifts.first { s in
            guard !s.isAllDay, let start = s.start, let end = s.end else { return false }
            return start <= now && now < end
        }.map(snapshotShift(from:))

        // This week's hours (reuse the one insights engine).
        let insightShifts: [InsightShift] = shifts.compactMap { s in
            guard let local = s.localDate else { return nil }
            return InsightShift(
                day: DayKey(containing: local, in: calendar),
                start: s.start, end: s.end, paidHours: s.paidHours,
                typeKey: nil, typeLabel: nil, colorHex: s.colorHex, isAllDay: s.isAllDay
            )
        }
        let weekStart = InsightsMath.weekStart(of: today, calendar: calendar)
        let weekRange = weekStart...weekStart.advanced(by: 6, in: calendar)
        let week = InsightsMath.periodSummary(shifts: insightShifts, in: weekRange)

        // v7.5: the week itself — 7 civil days with their shifts (the
        // week-overview widget and the watch app render these directly).
        var dayBuckets: [DayKey: [SnapshotInputShift]] = [:]
        for s in shifts {
            guard let local = s.localDate else { continue }
            dayBuckets[DayKey(containing: local, in: calendar), default: []].append(s)
        }
        let weekDays: [SnapshotDay] = (0..<7).map { offset in
            let day = weekStart.advanced(by: offset, in: calendar)
            let dayShifts = (dayBuckets[day] ?? [])
                .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
                .map(snapshotShift(from:))
            return SnapshotDay(date: day.startOfDay(in: calendar), shifts: dayShifts)
        }

        // Gauge numerator: this week's TIMED hours already worked (end ≤ now).
        var completed = 0.0
        var tbcCount = 0
        for s in shifts {
            guard let local = s.localDate else { continue }
            let day = DayKey(containing: local, in: calendar)
            guard weekRange.contains(day) else { continue }
            if s.isAllDay {
                if s.isTentative { tbcCount += 1 }
            } else if let end = s.end, end <= now {
                if let paid = s.paidHours {
                    completed += paid
                } else if let start = s.start, end > start {
                    completed += end.timeIntervalSince(start) / 3600
                }
            }
        }

        return HelmSnapshot(
            generatedAt: now,
            next: next,
            today: todays,
            weekHours: week.hours,
            weekShiftCount: week.shiftCount,
            current: current,
            weekDays: weekDays,
            weekHoursCompleted: completed,
            weekTBCCount: tbcCount
        )
    }

    private static func snapshotShift(from s: SnapshotInputShift) -> SnapshotShift {
        SnapshotShift(id: s.id, title: s.title, location: s.location, colorHex: s.colorHex,
                      start: s.start, end: s.end, isAllDay: s.isAllDay,
                      isTentative: s.isTentative ? true : nil)
    }
}
