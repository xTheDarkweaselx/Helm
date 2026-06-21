//
//  PlanningModels.swift
//  Helm
//
//  v7 planning: time-off / leave and availability (recurring weekly rules +
//  one-off windows). CloudKit-safe like the rest of the schema — every
//  attribute optional or defaulted, no @Attribute(.unique), every relationship
//  optional with an EXPLICIT inverse (declared on UserProfile), no ordered
//  relationships, enums stored as raw String. The pure logic that consumes
//  these lives in HelmDomain (LeaveAccumulator / AvailabilityMerger).
//

import Foundation
import SwiftData
import HelmDomain

// MARK: - TimeOff (a booked stretch of leave / holiday)

@Model
final class TimeOff {
    var id: String = UUID().uuidString
    /// Start-of-day in `timeZoneIdentifier`. Inclusive range with `endDate`.
    var startDate: Date?
    var endDate: Date?
    var kindRaw: String = LeaveKind.annual.rawValue
    var paid: Bool = true
    /// Optional credited hours per leave day (e.g. 7.5). nil → days only.
    var hoursPerDay: Double?
    var title: String?
    var note: String?
    var timeZoneIdentifier: String? = TimeZone.current.identifier
    var createdAt: Date = Date.now
    /// Future-proofing (v7 ships leave as metadata + a calendar band; writing
    /// leave OUT to the calendar as events is deferred). Defaulted, harmless.
    var writesToCalendar: Bool = false

    var user: UserProfile?

    var kind: LeaveKind {
        get { LeaveKind(rawValue: kindRaw) ?? .annual }
        set { kindRaw = newValue.rawValue }
    }

    init(id: String = UUID().uuidString, startDate: Date? = nil, endDate: Date? = nil, kind: LeaveKind = .annual, paid: Bool = true, user: UserProfile? = nil) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.kindRaw = kind.rawValue
        self.paid = paid
        self.createdAt = .now
        self.user = user
    }
}

// MARK: - AvailabilityRule (recurring weekly availability / unavailability)

@Model
final class AvailabilityRule {
    var id: String = UUID().uuidString
    var kindRaw: String = AvailabilityKind.unavailable.rawValue
    /// CSV of Foundation weekdays (1 = Sun … 7 = Sat), e.g. "2,3,4".
    var weekdayMaskRaw: String?
    var startMinuteOfDay: Int = 0
    var endMinuteOfDay: Int = 1440
    var effectiveFrom: Date?
    var effectiveTo: Date?
    var note: String?
    var createdAt: Date = Date.now

    var user: UserProfile?

    var kind: AvailabilityKind {
        get { AvailabilityKind(rawValue: kindRaw) ?? .unavailable }
        set { kindRaw = newValue.rawValue }
    }

    /// The selected weekdays as a set (parsed/encoded through the CSV mask).
    var weekdays: Set<Int> {
        get { WeekdayMask.parse(weekdayMaskRaw) }
        set { weekdayMaskRaw = WeekdayMask.encode(newValue) }
    }

    init(id: String = UUID().uuidString, kind: AvailabilityKind = .unavailable, weekdays: Set<Int> = [], user: UserProfile? = nil) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.weekdayMaskRaw = WeekdayMask.encode(weekdays)
        self.createdAt = .now
        self.user = user
    }
}

// MARK: - AvailabilityWindow (a one-off availability override for a date)

@Model
final class AvailabilityWindow {
    var id: String = UUID().uuidString
    var kindRaw: String = AvailabilityKind.unavailable.rawValue
    /// Start-of-day of the affected date.
    var localDate: Date?
    var startMinuteOfDay: Int = 0
    var endMinuteOfDay: Int = 1440
    var allDay: Bool = false
    var note: String?
    var createdAt: Date = Date.now

    var user: UserProfile?

    var kind: AvailabilityKind {
        get { AvailabilityKind(rawValue: kindRaw) ?? .unavailable }
        set { kindRaw = newValue.rawValue }
    }

    init(id: String = UUID().uuidString, kind: AvailabilityKind = .unavailable, localDate: Date? = nil, allDay: Bool = false, user: UserProfile? = nil) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.localDate = localDate
        self.allDay = allDay
        self.createdAt = .now
        self.user = user
    }
}

// MARK: - Weekday CSV helper

/// CSV (de)serialisation for a weekday set (Foundation weekdays 1…7). Kept here
/// (app target) since it bridges the @Model CSV column to a Set<Int>. Marked
/// `nonisolated` because @Model property accessors are nonisolated and the app
/// target's default isolation is MainActor.
enum WeekdayMask {
    nonisolated static func parse(_ raw: String?) -> Set<Int> {
        guard let raw, !raw.isEmpty else { return [] }
        return Set(raw.split(separator: ",").compactMap { Int($0) }.filter { (1...7).contains($0) })
    }

    nonisolated static func encode(_ days: Set<Int>) -> String {
        days.filter { (1...7).contains($0) }.sorted().map(String.init).joined(separator: ",")
    }
}
