//
//  ManualShiftCoordinator.swift
//  Helm
//
//  v7 quick-add: create a one-off shift without an import or a full schedule.
//  It lives in a dedicated, never-re-imported "Manual Shifts" roster (a synthetic
//  ImportProfile keyed by a "manual:" fingerprint, so it can never collide with a
//  file import or a built schedule), is marked .added (user-authored → survives
//  re-imports), and is written to the calendar through the SAME draft/upsert path
//  the sync engine uses.
//

import Foundation
import SwiftData
import HelmDomain
import HelmCalendar

@MainActor
enum ManualShiftCoordinator {
    /// Fingerprint source for the manual roster (namespaced so it never collides
    /// with a file ("…xlsx") or a schedule ("schedule:<id>")).
    static let sourceName = "manual:shifts"

    /// Find-or-create the manual roster (and its backing profile).
    static func manualRoster(in context: ModelContext) -> Roster {
        let fingerprint = RosterSyncEngine.fingerprint(for: sourceName)
        if let profile = try? context.fetch(FetchDescriptor<ImportProfile>(predicate: #Predicate { $0.sourceFingerprint == fingerprint })).first {
            let pid = profile.id
            if let roster = try? context.fetch(FetchDescriptor<Roster>(predicate: #Predicate { $0.sourceImportProfileID == pid })).first {
                return roster
            }
            let roster = Roster(title: "Manual Shifts")
            roster.sourceImportProfileID = profile.id
            context.insert(roster)
            return roster
        }
        let profile = ImportProfile(name: "Manual Shifts")
        profile.sourceFingerprint = fingerprint
        profile.layoutKindRaw = LayoutKind.list.rawValue
        context.insert(profile)
        let roster = Roster(title: "Manual Shifts")
        roster.sourceImportProfileID = profile.id
        context.insert(roster)
        return roster
    }

    /// Add (and calendar-write) a one-off shift. Times come from `shiftType` unless
    /// custom minutes are supplied; an all-day shift uses the midnight convention.
    @discardableResult
    static func addShift(
        date: Date,
        timeZoneIdentifier: String,
        shiftType: ShiftType?,
        title: String?,
        location: String?,
        note: String?,
        startMinute: Int?,
        endMinute: Int?,
        endDayOffset: Int,
        isAllDay: Bool,
        in context: ModelContext
    ) async throws -> ShiftInstance {
        let tz = TimeZone(identifier: timeZoneIdentifier) ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let dayStart = cal.startOfDay(for: date)

        let roster = manualRoster(in: context)
        // Unique, stable, namespaced key so the calendar upsert/removal works and
        // never collides with imports or schedules.
        let code = ShiftKey.generatedCode(scope: "manual", code: UUID().uuidString)
        let dedupKey = ShiftKey.make(localDate: dayStart, timeZoneIdentifier: timeZoneIdentifier, code: code)

        // An "off" type (or a degenerate zero-length time) can't be a timed
        // shift — fall back to an all-day entry instead of a phantom 24h event.
        var allDay = isAllDay
        if shiftType?.workKind == .off { allDay = true }

        let instance = ShiftInstance(
            localDate: dayStart,
            timeZoneIdentifier: timeZoneIdentifier,
            title: title?.isEmpty == false ? title : (shiftType?.label ?? shiftType?.code),
            locationName: (location?.isEmpty == false ? location : nil) ?? shiftType?.locationName,
            shiftType: shiftType,
            roster: roster,
            dedupKey: dedupKey
        )
        instance.overrideKind = .added
        instance.note = note?.isEmpty == false ? note : nil

        if allDay {
            instance.startUTC = dayStart
            instance.endUTC = dayStart
            instance.computedPaidHours = nil
        } else {
            let sMin = startMinute ?? shiftType?.startMinuteOfDay ?? 9 * 60
            let eMin = endMinute ?? shiftType?.endMinuteOfDay ?? 17 * 60
            let off = endDayOffset != 0 ? endDayOffset : (shiftType?.endDayOffset ?? 0)
            if let resolved = ShiftTimeResolver.resolve(localDay: dayStart, startMinuteOfDay: sMin, endMinuteOfDay: eMin, endDayOffset: off, timeZone: tz), resolved.end > resolved.start {
                instance.startUTC = resolved.start
                instance.endUTC = resolved.end
                instance.computedPaidHours = resolved.paidHours(breakMinutes: shiftType?.breakMinutes ?? 0)
            } else {
                // Degenerate (start == end) → all-day rather than a zero-length event.
                allDay = true
                instance.startUTC = dayStart
                instance.endUTC = dayStart
                instance.computedPaidHours = nil
            }
        }
        instance.isAllDay = allDay ? true : nil
        context.insert(instance)

        // Destination is stamped ONCE on the manual roster's profile and reused
        // thereafter, so every manual shift lands on the same calendar(s) and a
        // later per-shift removal cleans up the right place (changing the global
        // destination between quick-adds can't orphan earlier ones).
        let chosen = CalendarDestinationSetting.chosenKinds
        var destinations = chosen
        if let pid = roster.sourceImportProfileID,
           let profile = try? context.fetch(FetchDescriptor<ImportProfile>(predicate: #Predicate { $0.id == pid })).first {
            if profile.calendarTargetRaw == nil { profile.targets = chosen }
            destinations = profile.targets
        }

        // Write the calendar BEFORE committing (rollback on failure, like the
        // engine). Even one Google write can sit in retry backoff — show it.
        if let draft = RosterSyncEngine.calendarDraft(for: instance) {
            SyncProgress.shared.begin("Adding shift to \(SyncSummary.name(for: destinations))…", total: nil)
            defer { SyncProgress.shared.end() }
            do {
                let targets = try await CalendarTargetProvider.authorizedTargets(for: destinations)
                for target in targets { _ = try await target.write([draft]) }
            } catch {
                context.rollback()
                throw error
            }
        }
        try context.save()
        SnapshotWriter.refresh(context: context)
        return instance
    }
}
