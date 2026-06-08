//
//  ScheduleModels.swift
//  Helm
//
//  The core schedule entities. All models obey CloudKit's SwiftData rules:
//  every attribute is optional or defaulted, no `@Attribute(.unique)`, every
//  relationship is optional (to-one) or defaulted-empty (to-many) with an
//  explicit inverse, no ordered relationships (we sort by `sortIndex`).
//  See DEVELOPMENT_PLAN.md §3.
//

import Foundation
import SwiftData

// MARK: - UserProfile

/// A person whose shifts Helm manages. v1 is single-user, but the model is
/// user-partitioned so multi-user / future sharing stays possible (ADR-6).
@Model
final class UserProfile {
    var id: String = UUID().uuidString
    var displayName: String?
    /// Alternate spellings used to locate "which row is me" in a multi-person grid.
    var nameAliases: [String]?
    var createdAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \Roster.user)
    var rosters: [Roster] = []

    @Relationship(deleteRule: .cascade, inverse: \RotationAssignment.user)
    var assignments: [RotationAssignment] = []

    @Relationship(deleteRule: .cascade, inverse: \ImportProfile.user)
    var importProfiles: [ImportProfile] = []

    init(id: String = UUID().uuidString, displayName: String? = nil, nameAliases: [String]? = nil) {
        self.id = id
        self.displayName = displayName
        self.nameAliases = nameAliases
        self.createdAt = .now
    }
}

// MARK: - ShiftType (named template)

/// A named shift template (e.g. "M" = Morning 06:30–13:30). Times are stored as
/// wall-clock minutes-of-day; `endMinuteOfDay` may exceed 1440 (or use
/// `endDayOffset`) to express an overnight shift. See ADR-5.
@Model
final class ShiftType {
    var id: String = UUID().uuidString
    /// Normalized source code (uppercased/trimmed), e.g. "M", "A", "N".
    var code: String?
    /// Human label, e.g. "Morning".
    var label: String?

    var startMinuteOfDay: Int = 0
    /// May exceed 1440 for overnight, or keep <1440 and use `endDayOffset`.
    var endMinuteOfDay: Int = 0
    /// Days the end rolls into (1 = ends next day). Alternative to >1440 minutes.
    var endDayOffset: Int = 0

    var breakMinutes: Int = 0
    var paid: Bool = true
    var paidHoursOverride: Double?
    var workKindRaw: String = WorkKind.worked.rawValue

    var colorHex: String?
    var locationName: String?
    var defaultTimeZoneID: String?
    /// Minutes-before-start for default reminders, e.g. [60] or [720] (night-before).
    var defaultAlarmOffsets: [Int]?

    @Relationship(deleteRule: .nullify, inverse: \ShiftInstance.shiftType)
    var instances: [ShiftInstance] = []

    @Relationship(deleteRule: .nullify, inverse: \RotationSlot.shiftType)
    var rotationSlots: [RotationSlot] = []

    @Relationship(deleteRule: .nullify, inverse: \ShiftCodeMapping.shiftType)
    var codeMappings: [ShiftCodeMapping] = []

    var workKind: WorkKind {
        get { WorkKind(rawValue: workKindRaw) ?? .worked }
        set { workKindRaw = newValue.rawValue }
    }

    init(
        id: String = UUID().uuidString,
        code: String? = nil,
        label: String? = nil,
        startMinuteOfDay: Int = 0,
        endMinuteOfDay: Int = 0,
        endDayOffset: Int = 0,
        breakMinutes: Int = 0,
        paid: Bool = true,
        workKind: WorkKind = .worked,
        colorHex: String? = nil,
        locationName: String? = nil
    ) {
        self.id = id
        self.code = code
        self.label = label
        self.startMinuteOfDay = startMinuteOfDay
        self.endMinuteOfDay = endMinuteOfDay
        self.endDayOffset = endDayOffset
        self.breakMinutes = breakMinutes
        self.paid = paid
        self.workKindRaw = workKind.rawValue
        self.colorHex = colorHex
        self.locationName = locationName
    }
}

// MARK: - Roster (a materialized set of shifts)

@Model
final class Roster {
    var id: String = UUID().uuidString
    var title: String?
    var createdAt: Date = Date.now
    var sourceImportProfileID: String?

    var user: UserProfile?

    @Relationship(deleteRule: .cascade, inverse: \ShiftInstance.roster)
    var instances: [ShiftInstance] = []

    init(id: String = UUID().uuidString, title: String? = nil, user: UserProfile? = nil) {
        self.id = id
        self.title = title
        self.createdAt = .now
        self.user = user
    }
}

// MARK: - ShiftInstance (the push-to-calendar unit)

@Model
final class ShiftInstance {
    var id: String = UUID().uuidString

    /// Date-only (start-of-day in the shift's time zone). The wall-clock times
    /// come from the `shiftType`; `startUTC`/`endUTC` are derived caches.
    var localDate: Date?
    var timeZoneIdentifier: String = TimeZone.current.identifier
    var startUTC: Date?
    var endUTC: Date?
    var computedPaidHours: Double?

    var overrideKindRaw: String = OverrideKind.none.rawValue
    var originalDate: Date?
    var originalShiftTypeCode: String?

    /// In-code uniqueness key (CloudKit forbids `@Attribute(.unique)`); upsert is
    /// enforced by fetch-by-key in the import actor.
    var dedupKey: String?
    var sortIndex: Int = 0

    /// Free-text title for the calendar event (e.g. the spreadsheet's Course Title).
    var title: String?
    var locationName: String?
    var note: String?

    var shiftType: ShiftType?
    var roster: Roster?

    @Relationship(deleteRule: .cascade, inverse: \ShiftSegment.instance)
    var segments: [ShiftSegment] = []

    @Relationship(deleteRule: .cascade, inverse: \CalendarSyncRecord.shiftInstance)
    var syncRecords: [CalendarSyncRecord] = []

    var overrideKind: OverrideKind {
        get { OverrideKind(rawValue: overrideKindRaw) ?? .none }
        set { overrideKindRaw = newValue.rawValue }
    }

    /// User-authored instances must survive re-import untouched.
    var isUserAuthored: Bool { overrideKind != .none }

    init(
        id: String = UUID().uuidString,
        localDate: Date? = nil,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        title: String? = nil,
        locationName: String? = nil,
        shiftType: ShiftType? = nil,
        roster: Roster? = nil,
        dedupKey: String? = nil
    ) {
        self.id = id
        self.localDate = localDate
        self.timeZoneIdentifier = timeZoneIdentifier
        self.title = title
        self.locationName = locationName
        self.shiftType = shiftType
        self.roster = roster
        self.dedupKey = dedupKey
    }
}

// MARK: - ShiftSegment (optional, split shifts)

@Model
final class ShiftSegment {
    var id: String = UUID().uuidString
    var sortIndex: Int = 0
    var startMinuteOfDay: Int = 0
    var endMinuteOfDay: Int = 0

    var instance: ShiftInstance?

    init(id: String = UUID().uuidString, sortIndex: Int = 0, startMinuteOfDay: Int = 0, endMinuteOfDay: Int = 0) {
        self.id = id
        self.sortIndex = sortIndex
        self.startMinuteOfDay = startMinuteOfDay
        self.endMinuteOfDay = endMinuteOfDay
    }
}

// MARK: - Rotation pattern (abstract repeating cycle) — for the in-app builder

@Model
final class RotationPattern {
    var id: String = UUID().uuidString
    var name: String?
    var cycleLengthDays: Int = 7

    @Relationship(deleteRule: .cascade, inverse: \RotationSlot.pattern)
    var slots: [RotationSlot] = []

    @Relationship(deleteRule: .cascade, inverse: \RotationAssignment.pattern)
    var assignments: [RotationAssignment] = []

    init(id: String = UUID().uuidString, name: String? = nil, cycleLengthDays: Int = 7) {
        self.id = id
        self.name = name
        self.cycleLengthDays = cycleLengthDays
    }
}

@Model
final class RotationSlot {
    var id: String = UUID().uuidString
    /// Ordered position within the cycle (0-based). We sort by this rather than
    /// using an ordered relationship (CloudKit-unsafe).
    var sortIndex: Int = 0
    /// nil = an OFF day in the cycle.
    var shiftType: ShiftType?
    var pattern: RotationPattern?

    init(id: String = UUID().uuidString, sortIndex: Int = 0, shiftType: ShiftType? = nil) {
        self.id = id
        self.sortIndex = sortIndex
        self.shiftType = shiftType
    }
}

@Model
final class RotationAssignment {
    var id: String = UUID().uuidString
    /// Day-1 of the cycle for this assignment.
    var anchorDate: Date?
    /// For crews that start mid-cycle.
    var dayOffset: Int = 0
    var effectiveFrom: Date?
    var effectiveTo: Date?
    var timeZoneIdentifier: String?

    var user: UserProfile?
    var pattern: RotationPattern?

    init(id: String = UUID().uuidString, anchorDate: Date? = nil, dayOffset: Int = 0, user: UserProfile? = nil, pattern: RotationPattern? = nil) {
        self.id = id
        self.anchorDate = anchorDate
        self.dayOffset = dayOffset
        self.user = user
        self.pattern = pattern
    }
}
