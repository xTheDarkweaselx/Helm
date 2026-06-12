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
    /// Paid hours when the source computed them (lets renderers compute the
    /// hours gauge AT RENDER TIME instead of trusting a build-time scalar).
    public let paidHours: Double?

    public init(id: String, title: String, location: String?, colorHex: String?, start: Date?, end: Date?, isAllDay: Bool, isTentative: Bool? = nil, paidHours: Double? = nil) {
        self.id = id
        self.title = title
        self.location = location
        self.colorHex = colorHex
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isTentative = isTentative
        self.paidHours = paidHours
    }
}

/// One civil day of the current week (v7.5 — feeds the week-overview widget
/// and the watch app).
public struct SnapshotDay: Codable, Sendable, Equatable, Identifiable {
    /// Start-of-day in the calendar the snapshot was built with.
    public let date: Date
    public let shifts: [SnapshotShift]
    /// The civil day as zone-free components (optional → blob-compatible).
    /// Renderers should prefer this over `date`: an instant baked in the
    /// build zone reads as the wrong day after a device timezone change.
    public let key: DayKey?

    public var id: Date { date }

    public init(date: Date, shifts: [SnapshotShift], key: DayKey? = nil) {
        self.date = date
        self.shifts = shifts
        self.key = key
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
    /// The shift's OWN IANA zone — civil-day bucketing must happen here, not
    /// in the device zone (the app's canonical DayBucketer rule). nil → the
    /// build calendar's zone.
    public let timeZoneIdentifier: String?

    public init(id: String, title: String, location: String?, colorHex: String?, start: Date?, end: Date?, localDate: Date?, isAllDay: Bool, paidHours: Double?, isTentative: Bool = false, timeZoneIdentifier: String? = nil) {
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
        self.timeZoneIdentifier = timeZoneIdentifier
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

        // Civil-day bucketing happens in each shift's OWN zone (the app's
        // canonical DayBucketer rule) — the device zone put builder shifts
        // (midnight-anchored localDate) one day early west of the roster zone.
        var zoneCals: [String: Calendar] = [:]
        func civilDay(of s: SnapshotInputShift) -> DayKey? {
            guard let local = s.localDate else { return nil }
            guard let zoneID = s.timeZoneIdentifier, zoneID != calendar.timeZone.identifier else {
                return DayKey(containing: local, in: calendar)
            }
            let cal = zoneCals[zoneID] ?? {
                var c = Calendar(identifier: .gregorian)
                c.timeZone = TimeZone(identifier: zoneID) ?? calendar.timeZone
                zoneCals[zoneID] = c
                return c
            }()
            return DayKey(containing: local, in: cal)
        }

        // Next shift (one rule, everywhere).
        let candidates = shifts.map { NextShiftRule.Candidate(id: $0.id, isAllDay: $0.isAllDay, start: $0.start, localDate: $0.localDate) }
        let nextID = NextShiftRule.nextID(in: candidates, now: now, calendar: calendar)
        let next = nextID.flatMap { id in shifts.first { $0.id == id } }.map(snapshotShift(from:))

        // Today's shifts (civil-day membership), by start.
        let todays = shifts
            .filter { civilDay(of: $0) == today }
            .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
            .map(snapshotShift(from:))

        // Currently on shift.
        let current = shifts.first { s in
            guard !s.isAllDay, let start = s.start, let end = s.end else { return false }
            return start <= now && now < end
        }.map(snapshotShift(from:))

        // This week's hours (reuse the one insights engine).
        let insightShifts: [InsightShift] = shifts.compactMap { s in
            guard let day = civilDay(of: s) else { return nil }
            return InsightShift(
                day: day,
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
            guard let day = civilDay(of: s) else { continue }
            dayBuckets[day, default: []].append(s)
        }
        let weekDays: [SnapshotDay] = (0..<7).map { offset in
            let day = weekStart.advanced(by: offset, in: calendar)
            let dayShifts = (dayBuckets[day] ?? [])
                .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
                .map(snapshotShift(from:))
            // The civil-day KEY is what renderers should trust — the instant
            // is only a display convenience for same-zone renders.
            return SnapshotDay(date: day.startOfDay(in: calendar), shifts: dayShifts, key: day)
        }

        // Build-time gauge numerator (renderers recompute live via
        // SnapshotMath.completedHours; this scalar keeps OLD widgets sane):
        // ended shifts in full, in-progress shifts at their elapsed fraction.
        var completed = 0.0
        var tbcCount = 0
        for s in shifts {
            guard let day = civilDay(of: s), weekRange.contains(day) else { continue }
            if s.isAllDay {
                if s.isTentative { tbcCount += 1 }
            } else if let start = s.start, let end = s.end, end > start, start <= now {
                let credit = s.paidHours ?? end.timeIntervalSince(start) / 3600
                if end <= now {
                    completed += credit
                } else {
                    completed += credit * (now.timeIntervalSince(start) / end.timeIntervalSince(start))
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
                      isTentative: s.isTentative ? true : nil,
                      paidHours: s.paidHours)
    }
}

/// RENDER-TIME math over a (possibly hours-old) snapshot — the ONE set of
/// rules every surface uses (iOS widgets, watch app, complications), so a
/// stale blob degrades identically everywhere. All pure and tested.
public enum SnapshotMath {
    /// The shift happening at `now`: the stored `current` while it's still
    /// running, else `next` PROMOTED once its window started (the blob may
    /// predate the shift's start).
    public static func onNow(in snapshot: HelmSnapshot, at now: Date) -> SnapshotShift? {
        if let c = snapshot.current, let end = c.end, end > now { return c }
        if let n = snapshot.next, !n.isAllDay, let s = n.start, let e = n.end, s <= now, now < e { return n }
        return nil
    }

    /// The genuinely upcoming shift at `now` (a started timed `next` belongs
    /// to `onNow`, a finished one to neither). All-day entries pass through —
    /// their civil-day freshness can't be judged from instants alone.
    public static func upcoming(in snapshot: HelmSnapshot, at now: Date) -> SnapshotShift? {
        guard let n = snapshot.next else { return nil }
        if n.isAllDay { return n }
        guard let start = n.start, start > now else { return nil }
        return n
    }

    /// Live gauge numerator from the week grid: ended shifts in full,
    /// in-progress at their elapsed fraction. Falls back to the build-time
    /// scalar for v1 blobs (no weekDays).
    public static func completedHours(in snapshot: HelmSnapshot, at now: Date) -> Double? {
        guard let week = snapshot.weekDays else { return snapshot.weekHoursCompleted }
        var total = 0.0
        for day in week {
            for shift in day.shifts where !shift.isAllDay {
                guard let start = shift.start, let end = shift.end, end > start, start <= now else { continue }
                let credit = shift.paidHours ?? end.timeIntervalSince(start) / 3600
                if end <= now {
                    total += credit
                } else {
                    total += credit * (now.timeIntervalSince(start) / end.timeIntervalSince(start))
                }
            }
        }
        return total
    }

    /// Whether the blob's week still contains `now` (after a week rollover a
    /// stale grid must show a refresh hint, not last week labelled "this").
    /// v1 blobs (no weekDays) can't be judged → treated as current.
    public static func isWeekCurrent(_ snapshot: HelmSnapshot, at now: Date, calendar: Calendar) -> Bool {
        guard let week = snapshot.weekDays, !week.isEmpty else { return true }
        let today = DayKey(containing: now, in: calendar)
        return week.contains { day in
            (day.key ?? DayKey(containing: day.date, in: calendar)) == today
        }
    }

    /// Today's shifts AT RENDER TIME: recomputed from the week grid (the
    /// stored `today` array names the build day, which midnight outruns).
    /// Week present but today missing → honest empty; v1 blob → stored array.
    public static func todayShifts(in snapshot: HelmSnapshot, at now: Date, calendar: Calendar) -> [SnapshotShift] {
        guard let week = snapshot.weekDays else { return snapshot.today }
        let today = DayKey(containing: now, in: calendar)
        return week.first { day in
            (day.key ?? DayKey(containing: day.date, in: calendar)) == today
        }?.shifts ?? []
    }

    /// The week-grid day containing a shift (e.g. to show WHICH day an
    /// all-day "next" falls on).
    public static func day(of shift: SnapshotShift, in snapshot: HelmSnapshot) -> SnapshotDay? {
        snapshot.weekDays?.first { $0.shifts.contains { $0.id == shift.id } }
    }
}
