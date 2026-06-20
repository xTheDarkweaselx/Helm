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
import HelmDomain // ShiftTags (the v7 tag accessors on ShiftType)

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

    // CloudKit requires to-many relationships to be OPTIONAL (not just defaulted).
    @Relationship(deleteRule: .cascade, inverse: \Roster.user)
    var rosters: [Roster]?

    @Relationship(deleteRule: .cascade, inverse: \RotationAssignment.user)
    var assignments: [RotationAssignment]?

    @Relationship(deleteRule: .cascade, inverse: \ImportProfile.user)
    var importProfiles: [ImportProfile]?

    @Relationship(deleteRule: .cascade, inverse: \Schedule.user)
    var schedules: [Schedule]?

    // v7 planning. CloudKit needs every relationship to carry an explicit
    // inverse — a missing one silently drops the WHOLE store to local-only.
    @Relationship(deleteRule: .cascade, inverse: \TimeOff.user)
    var timeOffs: [TimeOff]?

    @Relationship(deleteRule: .cascade, inverse: \AvailabilityRule.user)
    var availabilityRules: [AvailabilityRule]?

    @Relationship(deleteRule: .cascade, inverse: \AvailabilityWindow.user)
    var availabilityWindows: [AvailabilityWindow]?

    // v9 Payslip Reconcile. Explicit inverse (CloudKit needs it on both sides).
    @Relationship(deleteRule: .cascade, inverse: \Payslip.user)
    var payslips: [Payslip]?

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

    // v7 categorisation. CSV-backed (CloudKit-safe), parsed by HelmDomain.ShiftTags.
    /// Comma-separated tag names, e.g. "Night,Senior".
    var tagsRaw: String?
    /// Optional "name|RRGGBB" colour overrides for tags.
    var tagColorsRaw: String?
    /// Pinned to the top of the library + picker.
    var isFavorite: Bool = false
    /// User ordering in the library / picker (CloudKit-safe alternative to an
    /// ordered relationship).
    var sortIndex: Int = 0

    @Relationship(deleteRule: .nullify, inverse: \ShiftInstance.shiftType)
    var instances: [ShiftInstance]?

    @Relationship(deleteRule: .nullify, inverse: \RotationSlot.shiftType)
    var rotationSlots: [RotationSlot]?

    @Relationship(deleteRule: .nullify, inverse: \ShiftCodeMapping.shiftType)
    var codeMappings: [ShiftCodeMapping]?

    // Builder back-references (explicit inverses required for CloudKit) — also let
    // us count how many days a shift type is used by before deleting it.
    @Relationship(deleteRule: .nullify, inverse: \ExplicitDay.shiftType)
    var explicitDays: [ExplicitDay]?
    @Relationship(deleteRule: .nullify, inverse: \ScheduleException.shiftType)
    var exceptions: [ScheduleException]?

    var workKind: WorkKind {
        get { WorkKind(rawValue: workKindRaw) ?? .worked }
        set { workKindRaw = newValue.rawValue }
    }

    /// The shift type's tags (parsed/encoded through HelmDomain.ShiftTags so the
    /// editor and the readers share one rule). Setting also prunes colours for
    /// any removed tag.
    var tags: [String] {
        get { ShiftTags.parse(tagsRaw) }
        set {
            tagsRaw = ShiftTags.encode(newValue)
            let colors = ShiftTags.parseColors(tagColorsRaw)
            let encoded = ShiftTags.encodeColors(colors, among: ShiftTags.parse(tagsRaw))
            tagColorsRaw = encoded.isEmpty ? nil : encoded
        }
    }

    /// Resolved display colour for one of this type's tags (custom or palette).
    func colorHex(forTag tag: String) -> String {
        ShiftTags.colorHex(for: tag, customColors: ShiftTags.parseColors(tagColorsRaw))
    }

    /// Set or clear a custom colour for a tag (nil clears → falls back to palette).
    func setTagColor(_ hex: String?, forTag tag: String) {
        var colors = ShiftTags.parseColors(tagColorsRaw)
        if let hex, let norm = ShiftTags.normalizedHex(hex) {
            colors[tag.lowercased()] = norm
        } else {
            colors[tag.lowercased()] = nil
        }
        let encoded = ShiftTags.encodeColors(colors, among: tags)
        tagColorsRaw = encoded.isEmpty ? nil : encoded
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
    /// Per-roster reminder override, CSV of minutes-before (v4). nil = inherit
    /// the global ReminderSetting default; "" = explicitly no reminders.
    /// Optional for CloudKit; parsed via HelmDomain.ReminderOffsets.
    var reminderOffsetsRaw: String?

    /// Per-roster wake-up-alarm lead, minutes before each timed shift's start.
    /// nil = inherit the global ShiftAlarmSetting default. Optional for CloudKit;
    /// consumed by the iOS scheduler (the alarm itself is iOS-only) but editable
    /// on every platform so it can be chosen from the Mac.
    var alarmLeadMinutesOverride: Int?

    // v9 Multiple Jobs — a roster can stand for one job/employer with its own pay.
    /// Employer / job name shown in per-employer pay subtotals. nil/empty = use the
    /// roster title.
    var employerName: String?
    /// Per-roster hourly rate. nil = inherit the global rate from Settings.
    var hourlyRateOverride: Double?
    /// Per-roster premium rules, JSON-encoded `[PremiumRule]`. nil = inherit the
    /// global premium rules. Optional for CloudKit.
    var premiumRulesData: Data?
    /// Per-roster premium stacking ("highest" | "sum"). nil = inherit global.
    var premiumStackingRaw: String?

    var user: UserProfile?

    @Relationship(deleteRule: .cascade, inverse: \ShiftInstance.roster)
    var instances: [ShiftInstance]?

    init(id: String = UUID().uuidString, title: String? = nil, user: UserProfile? = nil) {
        self.id = id
        self.title = title
        self.createdAt = .now
        self.user = user
    }
}

// MARK: - Payslip (v9 reconcile ledger)

/// One pay period the user reconciles against a real payslip: the period it
/// covers, optionally scoped to one employer (roster), the actual gross they
/// were paid, and whether it's been resolved. Helm's *expected* figure is
/// recomputed live from the shifts in the period, so it isn't stored here.
@Model
final class Payslip {
    var id: String = UUID().uuidString
    var createdAt: Date = Date.now
    /// Inclusive pay period (date-only, start-of-day in the display zone).
    var periodStart: Date?
    var periodEnd: Date?
    var payday: Date?
    /// Employer scope: a Roster.id, or nil for all jobs combined.
    var rosterID: String?
    /// Snapshot of the employer name for display (rosters can be renamed/deleted).
    var employerLabel: String?
    /// Gross the user was actually paid, from their payslip. nil = not entered yet.
    var actualGross: Double?
    var resolved: Bool = false
    var note: String?

    var user: UserProfile?

    init(id: String = UUID().uuidString, periodStart: Date? = nil, periodEnd: Date? = nil,
         payday: Date? = nil, rosterID: String? = nil, employerLabel: String? = nil,
         user: UserProfile? = nil) {
        self.id = id
        self.createdAt = .now
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.payday = payday
        self.rosterID = rosterID
        self.employerLabel = employerLabel
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
    /// All-day shift (tentative/TBC rows) — nil reads as false (timed). v6.
    var isAllDay: Bool?
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

    /// v9 Payslip Reconcile — was this shift actually paid? nil = not yet checked
    /// ("unknown"); otherwise "paid" | "notPaid" | "wrong".
    var paidStatusRaw: String?
    /// For a "wrong" status — what was actually paid for this shift (gross).
    var actualPay: Double?

    var shiftType: ShiftType?
    var roster: Roster?

    @Relationship(deleteRule: .cascade, inverse: \ShiftSegment.instance)
    var segments: [ShiftSegment]?

    @Relationship(deleteRule: .cascade, inverse: \CalendarSyncRecord.shiftInstance)
    var syncRecords: [CalendarSyncRecord]?

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
    var slots: [RotationSlot]?

    @Relationship(deleteRule: .cascade, inverse: \RotationAssignment.pattern)
    var assignments: [RotationAssignment]?

    // CloudKit requires EVERY relationship to have an inverse; this one was
    // missing (ScheduleSegment.pattern) and silently knocked the container down
    // to the local fallback store (no sync) on iCloud-signed-in devices.
    @Relationship(deleteRule: .nullify, inverse: \ScheduleSegment.pattern)
    var segments: [ScheduleSegment]?

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
    /// The worked shift for this cycle position (nil + !isOff is also treated as OFF).
    var shiftType: ShiftType?
    /// Explicit OFF — disambiguates a deliberate day off from "not yet filled".
    var isOff: Bool = false
    /// Per-slot overrides (e.g. the same M shift at a different site on some days).
    var locationName: String?
    var note: String?
    var workKindOverrideRaw: String?
    var pattern: RotationPattern?

    var workKindOverride: WorkKind? {
        get { workKindOverrideRaw.flatMap(WorkKind.init(rawValue:)) }
        set { workKindOverrideRaw = newValue?.rawValue }
    }

    init(id: String = UUID().uuidString, sortIndex: Int = 0, shiftType: ShiftType? = nil, isOff: Bool = false) {
        self.id = id
        self.sortIndex = sortIndex
        self.shiftType = shiftType
        self.isOff = isOff
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

// MARK: - Custom rota builder (v2.2): Schedule timeline of segments + exceptions

/// A user-built rota. Owns an ordered timeline of segments (cycles / explicit
/// stretches) plus per-date exceptions, materialised into ShiftInstances over a
/// bounded horizon and synced through the same diff/sync path as imports.
@Model
final class Schedule {
    var id: String = UUID().uuidString
    var title: String?
    var createdAt: Date = Date.now
    var notes: String?
    var defaultTimeZoneIdentifier: String? = TimeZone.current.identifier
    /// Bounded horizon; `horizonEnd` is only ever extended, never shrunk (avoids churn).
    var horizonStart: Date?
    var horizonEnd: Date?
    /// 0 = use explicit horizon dates; >0 = rolling "expand N months ahead".
    var rollingHorizonMonths: Int = 0
    /// Links to the synthetic ImportProfile/Roster used for diff/sync ("schedule:<id>").
    var sourceImportProfileID: String?
    var user: UserProfile?

    @Relationship(deleteRule: .cascade, inverse: \ScheduleSegment.schedule)
    var segments: [ScheduleSegment]?
    @Relationship(deleteRule: .cascade, inverse: \ScheduleException.schedule)
    var exceptions: [ScheduleException]?

    init(id: String = UUID().uuidString, title: String? = nil, user: UserProfile? = nil) {
        self.id = id
        self.title = title
        self.createdAt = .now
        self.defaultTimeZoneIdentifier = TimeZone.current.identifier
        self.user = user
    }
}

/// A date-bounded timeline segment: a repeating cycle (points at a RotationPattern)
/// or an explicit list of dated days. Overlap precedence = highest `sortIndex`.
@Model
final class ScheduleSegment {
    var id: String = UUID().uuidString
    var sortIndex: Int = 0
    var title: String?
    var kindRaw: String = SegmentKind.cyclic.rawValue
    var effectiveFrom: Date?
    var effectiveTo: Date?
    var anchorDate: Date?            // cycle Day-1 (cyclic only)
    var dayOffset: Int = 0
    var timeZoneIdentifier: String? // pinned at creation; nil → schedule default
    var locationName: String?
    var pattern: RotationPattern?   // cyclic only
    var schedule: Schedule?

    @Relationship(deleteRule: .cascade, inverse: \ExplicitDay.segment)
    var explicitDays: [ExplicitDay]? // explicit only

    var kind: SegmentKind {
        get { SegmentKind(rawValue: kindRaw) ?? .cyclic }
        set { kindRaw = newValue.rawValue }
    }

    init(id: String = UUID().uuidString, kind: SegmentKind = .cyclic, sortIndex: Int = 0) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.sortIndex = sortIndex
    }
}

/// A single dated entry in an explicit (non-cyclic) segment.
@Model
final class ExplicitDay {
    var id: String = UUID().uuidString
    var sortIndex: Int = 0
    var localDate: Date?
    var shiftType: ShiftType?
    var isOff: Bool = false
    var inlineStartMinute: Int?
    var inlineEndMinute: Int?
    var title: String?
    var locationName: String?
    var note: String?
    var segment: ScheduleSegment?

    init(id: String = UUID().uuidString, localDate: Date? = nil, shiftType: ShiftType? = nil) {
        self.id = id
        self.localDate = localDate
        self.shiftType = shiftType
    }
}

/// A per-date override layered on top of the timeline (highest precedence).
@Model
final class ScheduleException {
    var id: String = UUID().uuidString
    var localDate: Date?
    var kindRaw: String = OverrideKind.modified.rawValue // modified|cancelled|added|swapped
    var shiftType: ShiftType?
    var inlineStartMinute: Int?
    var inlineEndMinute: Int?
    var title: String?
    var locationName: String?
    var note: String?
    var schedule: Schedule?

    var kind: OverrideKind {
        get { OverrideKind(rawValue: kindRaw) ?? .modified }
        set { kindRaw = newValue.rawValue }
    }

    init(id: String = UUID().uuidString, localDate: Date? = nil, kind: OverrideKind = .modified) {
        self.id = id
        self.localDate = localDate
        self.kindRaw = kind.rawValue
    }
}
