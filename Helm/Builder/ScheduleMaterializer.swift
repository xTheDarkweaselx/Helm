//
//  ScheduleMaterializer.swift
//  Helm
//
//  Bridges a built Schedule (@Model graph) to the import pipeline: snapshots it
//  into Sendable specs, runs the pure ScheduleExpander over the bounded horizon,
//  and produces a RosterImportResult that flows through RosterSyncEngine.plan/apply
//  exactly like an import (diff/sync/reminders/.ics). sourceName = "schedule:<id>"
//  gives it a stable identity so re-materialising updates the same Roster.
//

import Foundation
import SwiftData
import HelmDomain

@MainActor
enum ScheduleMaterializer {

    static func makeResult(for schedule: Schedule, today: Date = .now) -> RosterImportResult {
        let spec = snapshot(schedule)
        let range = horizon(for: schedule, today: today)
        let days = ScheduleExpander.expand(spec, horizon: range)
        let drafts = days.map(draftShift(from:))
        return RosterImportResult(drafts: drafts, sourceName: "schedule:\(schedule.id)",
                                  unmappedCodes: [], displayName: rosterTitle(for: schedule))
    }

    /// The Roster title to show (decorative; identity is the id-based fingerprint).
    static func rosterTitle(for schedule: Schedule) -> String {
        schedule.title?.isEmpty == false ? schedule.title! : "Schedule"
    }

    // MARK: - Snapshot @Model -> specs

    static func snapshot(_ schedule: Schedule) -> ScheduleSpec {
        let defaultTZ = schedule.defaultTimeZoneIdentifier ?? TimeZone.current.identifier
        let segments = (schedule.segments ?? [])
            .sorted { $0.sortIndex < $1.sortIndex }
            .map(segmentSpec(from:))
        let exceptions = (schedule.exceptions ?? []).compactMap(exceptionSpec(from:))
        return ScheduleSpec(scope: schedule.id, defaultTimeZoneIdentifier: defaultTZ,
                            segments: segments, exceptions: exceptions)
    }

    private static func segmentSpec(from seg: ScheduleSegment) -> SegmentSpec {
        let slots = (seg.pattern?.slots ?? [])
            .sorted { $0.sortIndex < $1.sortIndex }
            .map { SlotSpec(sortIndex: $0.sortIndex, isOff: $0.isOff,
                            shiftType: typeSpec(from: $0.shiftType), locationName: $0.locationName) }
        let explicit = (seg.explicitDays ?? [])
            .sorted { ($0.localDate ?? .distantPast) < ($1.localDate ?? .distantPast) }
            .compactMap { day -> ExplicitDaySpec? in
                guard let d = day.localDate else { return nil }
                return ExplicitDaySpec(localDate: d, isOff: day.isOff, shiftType: typeSpec(from: day.shiftType),
                                       inlineStartMinute: day.inlineStartMinute, inlineEndMinute: day.inlineEndMinute,
                                       title: day.title, locationName: day.locationName)
            }
        return SegmentSpec(sortIndex: seg.sortIndex, isExplicit: seg.kind == .explicit,
                           effectiveFrom: seg.effectiveFrom, effectiveTo: seg.effectiveTo,
                           timeZoneIdentifier: seg.timeZoneIdentifier, locationName: seg.locationName,
                           anchorDate: seg.anchorDate, dayOffset: seg.dayOffset,
                           cycleLengthDays: seg.pattern?.cycleLengthDays ?? 0,
                           slots: slots, explicitDays: explicit)
    }

    private static func exceptionSpec(from ex: ScheduleException) -> ExceptionSpec? {
        guard let d = ex.localDate else { return nil }
        return ExceptionSpec(localDate: d, kindRaw: ex.kindRaw, shiftType: typeSpec(from: ex.shiftType),
                             inlineStartMinute: ex.inlineStartMinute, inlineEndMinute: ex.inlineEndMinute,
                             title: ex.title, locationName: ex.locationName)
    }

    private static func typeSpec(from type: ShiftType?) -> ShiftTypeSpec? {
        guard let type else { return nil }
        return ShiftTypeSpec(id: type.id, code: type.code, label: type.label,
                             startMinuteOfDay: type.startMinuteOfDay, endMinuteOfDay: type.endMinuteOfDay,
                             endDayOffset: type.endDayOffset, breakMinutes: type.breakMinutes,
                             workKindRaw: type.workKindRaw, locationName: type.locationName)
    }

    // MARK: - Horizon

    static func horizon(for schedule: Schedule, today: Date) -> ClosedRange<Date> {
        let cal = Calendar.current
        if let start = schedule.horizonStart, let end = schedule.horizonEnd, start <= end {
            return start...end
        }
        let lower = cal.date(byAdding: .month, value: -1, to: today) ?? today
        let months = schedule.rollingHorizonMonths > 0 ? schedule.rollingHorizonMonths : 12
        let upper = cal.date(byAdding: .month, value: months, to: today) ?? today
        return lower...max(lower, upper)
    }

    // MARK: - ExpandedDay -> DraftShift

    private static func draftShift(from day: ExpandedDay) -> DraftShift {
        DraftShift(
            localDate: day.localDate,
            timeZoneIdentifier: day.timeZoneIdentifier,
            code: day.code,
            label: nil,
            title: day.title,
            location: day.location,
            startMinuteOfDay: day.startMinuteOfDay,
            endMinuteOfDay: day.endMinuteOfDay,
            start: day.start,
            end: day.end,
            paidHours: day.paidHours,
            dedupKey: day.dedupKey,
            sourceRow: nil,
            shiftTypeID: day.shiftTypeID,
            outcome: day.isWritable ? .willWrite : .skippedOff
        )
    }
}
