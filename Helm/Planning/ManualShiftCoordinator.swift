//
//  ManualShiftCoordinator.swift
//  Helm
//
//  v7 quick-add: create a one-off shift without an import or a full schedule.
//  By default it lives in a dedicated, never-re-imported "Manual Shifts" roster
//  (a synthetic ImportProfile keyed by a "manual:" fingerprint); v7.3 can also
//  target an EXISTING roster ("expand a roster manually"). Either way the
//  instance is marked .added (user-authored → survives re-imports) with a
//  namespaced dedup key (can't collide with source rows), and the calendar is
//  written FIRST from staged values — the model is only inserted after the
//  write succeeds, so a failure leaves no half-saved shift behind.
//

import Foundation
import SwiftData
import HelmDomain
import HelmCalendar

enum ManualShiftError: LocalizedError {
    case rosterMissing

    var errorDescription: String? {
        switch self {
        case .rosterMissing: "This roster no longer exists — the shift wasn't added."
        }
    }
}

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
        rosterID: String? = nil,
        in context: ModelContext
    ) async throws -> ShiftInstance {
        let tz = TimeZone(identifier: timeZoneIdentifier) ?? .current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let dayStart = cal.startOfDay(for: date)
        // Import convention: localDate is NOON-anchored in the shift's zone so
        // device-zone consumers derive the same civil day and same-day ordering
        // interleaves with imported rows.
        let noonAnchor = cal.date(bySettingHour: 12, minute: 0, second: 0, of: dayStart) ?? dayStart

        // Resolve the target roster. A REQUESTED roster that can't be found is
        // an error (never silently divert the shift to the manual roster).
        let roster: Roster
        var isManualRoster = false
        if let rosterID {
            guard let existing = try? context.fetch(FetchDescriptor<Roster>(predicate: #Predicate { $0.id == rosterID })).first else {
                throw ManualShiftError.rosterMissing
            }
            roster = existing
        } else {
            roster = manualRoster(in: context)
            isManualRoster = true
        }

        // Unique, stable, namespaced key so the calendar upsert/removal works and
        // never collides with imports or schedules.
        let code = ShiftKey.generatedCode(scope: "manual", code: UUID().uuidString)
        let dedupKey = ShiftKey.make(localDate: dayStart, timeZoneIdentifier: timeZoneIdentifier, code: code)

        // STAGE everything locally — the model is only touched after the
        // calendar write succeeds.
        // An "off" type (or a degenerate zero-length time) can't be a timed
        // shift — fall back to an all-day entry instead of a phantom 24h event.
        var allDay = isAllDay
        if shiftType?.workKind == .off { allDay = true }

        var stagedStart = dayStart
        var stagedEnd = dayStart
        var stagedPaidHours: Double?
        if !allDay {
            let sMin = startMinute ?? shiftType?.startMinuteOfDay ?? 9 * 60
            let eMin = endMinute ?? shiftType?.endMinuteOfDay ?? 17 * 60
            let off = endDayOffset != 0 ? endDayOffset : (shiftType?.endDayOffset ?? 0)
            if let resolved = ShiftTimeResolver.resolve(localDay: dayStart, startMinuteOfDay: sMin, endMinuteOfDay: eMin, endDayOffset: off, timeZone: tz), resolved.end > resolved.start {
                stagedStart = resolved.start
                stagedEnd = resolved.end
                stagedPaidHours = resolved.paidHours(breakMinutes: shiftType?.breakMinutes ?? 0)
            } else {
                // Degenerate (start == end) → all-day rather than a zero-length event.
                allDay = true
            }
        }

        let stagedTitle: String? = (title?.isEmpty == false ? title : nil) ?? shiftType?.label ?? shiftType?.code
        let stagedLocation: String? = (location?.isEmpty == false ? location : nil) ?? shiftType?.locationName
        let stagedNote: String? = note?.isEmpty == false ? note : nil

        // Destinations: an EXISTING roster's shifts go where that roster's
        // events already live (NEVER restamp its profile); the manual roster
        // stamps the global choice ONCE and reuses it.
        let chosen = CalendarDestinationSetting.chosenKinds
        var destinations = chosen
        if let pid = roster.sourceImportProfileID,
           let profile = try? context.fetch(FetchDescriptor<ImportProfile>(predicate: #Predicate { $0.id == pid })).first {
            if isManualRoster && profile.calendarTargetRaw == nil { profile.targets = chosen }
            destinations = profile.targets
        }

        // 1. Calendar first, from staged values. Even one Google write can sit
        // in retry backoff — show it.
        let draft = CalendarEventDraft(
            dedupKey: dedupKey,
            title: stagedTitle ?? "Shift",
            location: stagedLocation,
            start: stagedStart,
            end: stagedEnd,
            timeZoneIdentifier: timeZoneIdentifier,
            isAllDay: allDay,
            alarmOffsetsMinutes: RosterSyncEngine.effectiveReminderOffsets(for: roster),
            contentHash: ShiftContentHash.make(
                title: stagedTitle, startUTC: stagedStart, endUTC: stagedEnd,
                location: stagedLocation, timeZoneIdentifier: timeZoneIdentifier
            )
        )
        SyncProgress.shared.begin("Adding shift to \(SyncSummary.name(for: destinations))…", total: nil)
        defer { SyncProgress.shared.end() }
        let targets = try await CalendarTargetProvider.authorizedTargets(for: destinations)
        for target in targets { _ = try await target.write([draft]) }

        // 2. Only now create + insert the instance, and save with no await between.
        let instance = ShiftInstance(
            localDate: noonAnchor,
            timeZoneIdentifier: timeZoneIdentifier,
            title: stagedTitle,
            locationName: stagedLocation,
            shiftType: shiftType,
            roster: roster,
            dedupKey: dedupKey
        )
        instance.overrideKind = .added
        instance.note = stagedNote
        instance.startUTC = stagedStart
        instance.endUTC = stagedEnd
        instance.computedPaidHours = stagedPaidHours
        instance.isAllDay = allDay ? true : nil
        context.insert(instance)
        try context.save()
        SnapshotWriter.refresh(context: context)
        return instance
    }
}
