//
//  RosterSyncEngine.swift
//  Helm
//
//  v1.1 idempotent re-import. Matches a re-imported source to its existing
//  Roster (via an ImportProfile keyed by a source fingerprint), diffs the new
//  shifts against what's stored (add / update / remove / unchanged, preserving
//  user overrides), applies the diff to SwiftData, and syncs the calendar through
//  the CalendarTarget protocol — so re-importing a changed roster updates in
//  place with zero duplicates.
//

import Foundation
import SwiftData
import HelmDomain
import HelmCalendar

struct SyncSummary: Sendable, Equatable {
    var added = 0
    var updated = 0
    var removed = 0
    var unchanged = 0
    var isReimport = false
}

@MainActor
struct RosterSyncEngine {

    /// A read-only preview of what committing would do (shown before writing).
    struct Plan {
        let result: RosterImportResult
        let diff: RosterDiff
        let isReimport: Bool
        let existingProfileID: String?
    }

    // MARK: - Planning (no mutation)

    static func plan(for result: RosterImportResult, in context: ModelContext) -> Plan {
        let fingerprint = fingerprint(for: result.sourceName)
        let profile = fetchProfile(fingerprint: fingerprint, in: context)
        let existing = profile.flatMap { fetchRoster(forProfileID: $0.id, in: context) }
            .map(existingMap(for:)) ?? [:]
        let incoming = incomingMap(for: result)
        return Plan(
            result: result,
            diff: RosterDiffer.diff(existing: existing, incoming: incoming),
            isReimport: profile != nil,
            existingProfileID: profile?.id
        )
    }

    // MARK: - Apply (mutates SwiftData + calendar)

    static func apply(_ plan: Plan, target: ShiftCalendarWriter, in context: ModelContext) async throws -> SyncSummary {
        let result = plan.result
        let fingerprint = fingerprint(for: result.sourceName)

        // Find or create the profile + roster.
        let profile = fetchProfile(fingerprint: fingerprint, in: context) ?? {
            let p = ImportProfile(name: result.sourceName)
            p.sourceFingerprint = fingerprint
            p.layoutKindRaw = LayoutKind.list.rawValue
            context.insert(p)
            return p
        }()
        profile.lastImportedAt = .now

        let roster = fetchRoster(forProfileID: profile.id, in: context) ?? {
            let r = Roster(title: result.sourceName)
            r.sourceImportProfileID = profile.id
            context.insert(r)
            return r
        }()

        var existingByKey: [String: ShiftInstance] = [:]
        for instance in roster.instances ?? [] {
            if let key = instance.dedupKey { existingByKey[key] = instance }
        }
        let incomingByKey = Dictionary(uniqueKeysWithValues:
            result.drafts.filter(\.isWritable).map { (key(for: $0), $0) })

        var typeCache: [String: ShiftType] = [:]
        var removedKeys: [String] = []
        var draftsToWrite: [CalendarEventDraft] = []

        // Removed: delete instances no longer present (RosterDiffer already excluded user-authored).
        for key in plan.diff.removed {
            if let instance = existingByKey[key] {
                context.delete(instance)
            }
            removedKeys.append(key)
        }

        // Added: create new instances.
        for key in plan.diff.added {
            guard let draft = incomingByKey[key] else { continue }
            let type = shiftType(for: draft, cache: &typeCache, context: context)
            let instance = makeInstance(from: draft, type: type, roster: roster, context: context)
            draftsToWrite.append(calendarDraft(for: instance, type: type))
        }

        // Updated: mutate existing instances in place.
        for key in plan.diff.updated {
            guard let draft = incomingByKey[key], let instance = existingByKey[key] else { continue }
            let type = shiftType(for: draft, cache: &typeCache, context: context)
            apply(draft: draft, to: instance, type: type)
            draftsToWrite.append(calendarDraft(for: instance, type: type))
        }

        let run = ImportRun(importProfile: profile)
        run.addedCount = plan.diff.added.count
        run.changedCount = plan.diff.updated.count
        run.removedCount = plan.diff.removed.count
        run.skippedCount = result.drafts.count - result.writableCount
        context.insert(run)

        try context.save()

        // Sync the calendar via the protocol.
        if !draftsToWrite.isEmpty { _ = try await target.write(draftsToWrite) }
        if !removedKeys.isEmpty { _ = try await target.remove(dedupKeys: removedKeys) }

        return SyncSummary(
            added: plan.diff.added.count,
            updated: plan.diff.updated.count,
            removed: plan.diff.removed.count,
            unchanged: plan.diff.unchanged.count,
            isReimport: plan.isReimport
        )
    }

    /// Delete a roster and all of its calendar events.
    static func delete(roster: Roster, target: ShiftCalendarWriter, in context: ModelContext) async throws {
        let keys = (roster.instances ?? []).compactMap(\.dedupKey)
        context.delete(roster)
        try context.save()
        if !keys.isEmpty { _ = try await target.remove(dedupKeys: keys) }
    }

    // MARK: - Mapping helpers

    static func fingerprint(for sourceName: String) -> String {
        sourceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func key(for draft: DraftShift) -> String { draft.dedupKey }

    private static func title(for draft: DraftShift, type: ShiftType) -> String {
        draft.title ?? type.label ?? type.code ?? "Shift"
    }

    private static func existingMap(for roster: Roster) -> [String: ExistingShift] {
        var map: [String: ExistingShift] = [:]
        for instance in roster.instances ?? [] {
            guard let key = instance.dedupKey else { continue }
            map[key] = ExistingShift(
                contentHash: ShiftContentHash.make(
                    title: instance.title,
                    startUTC: instance.startUTC,
                    endUTC: instance.endUTC,
                    location: instance.locationName,
                    timeZoneIdentifier: instance.timeZoneIdentifier,
                    alarmOffsetsMinutes: instance.shiftType?.defaultAlarmOffsets ?? []
                ),
                isUserAuthored: instance.isUserAuthored
            )
        }
        return map
    }

    private static func incomingMap(for result: RosterImportResult) -> [String: String] {
        var map: [String: String] = [:]
        for draft in result.drafts where draft.isWritable {
            map[draft.dedupKey] = contentHash(for: draft)
        }
        return map
    }

    private static func contentHash(for draft: DraftShift) -> String {
        ShiftContentHash.make(
            title: draft.title ?? draft.label ?? draft.code,
            startUTC: draft.start,
            endUTC: draft.end,
            location: draft.location,
            timeZoneIdentifier: draft.timeZoneIdentifier
        )
    }

    private static func makeInstance(from draft: DraftShift, type: ShiftType, roster: Roster, context: ModelContext) -> ShiftInstance {
        let instance = ShiftInstance(
            localDate: draft.localDate,
            timeZoneIdentifier: draft.timeZoneIdentifier,
            title: title(for: draft, type: type),
            locationName: draft.location,
            shiftType: type,
            roster: roster,
            dedupKey: draft.dedupKey
        )
        instance.startUTC = draft.start
        instance.endUTC = draft.end
        instance.computedPaidHours = draft.paidHours
        context.insert(instance)
        return instance
    }

    private static func apply(draft: DraftShift, to instance: ShiftInstance, type: ShiftType) {
        instance.title = title(for: draft, type: type)
        instance.locationName = draft.location
        instance.shiftType = type
        instance.startUTC = draft.start
        instance.endUTC = draft.end
        instance.computedPaidHours = draft.paidHours
        instance.timeZoneIdentifier = draft.timeZoneIdentifier
    }

    private static func calendarDraft(for instance: ShiftInstance, type: ShiftType) -> CalendarEventDraft {
        CalendarEventDraft(
            dedupKey: instance.dedupKey ?? instance.id,
            title: instance.title ?? type.label ?? "Shift",
            location: instance.locationName,
            start: instance.startUTC ?? .now,
            end: instance.endUTC ?? .now,
            timeZoneIdentifier: instance.timeZoneIdentifier,
            alarmOffsetsMinutes: type.defaultAlarmOffsets ?? [],
            contentHash: ShiftContentHash.make(
                title: instance.title, startUTC: instance.startUTC, endUTC: instance.endUTC,
                location: instance.locationName, timeZoneIdentifier: instance.timeZoneIdentifier,
                alarmOffsetsMinutes: type.defaultAlarmOffsets ?? []
            )
        )
    }

    private static func shiftType(for draft: DraftShift, cache: inout [String: ShiftType], context: ModelContext) -> ShiftType {
        let key = draft.code.isEmpty
            ? "inline:\(draft.startMinuteOfDay ?? 0)-\(draft.endMinuteOfDay ?? 0)"
            : draft.code
        if let cached = cache[key] { return cached }
        let label = draft.label
            ?? draft.startMinuteOfDay.map { hhmm($0) + (draft.endMinuteOfDay.map { "–" + hhmm($0) } ?? "") }
            ?? (draft.code.isEmpty ? "Shift" : draft.code)
        let type = ShiftType(
            code: draft.code.isEmpty ? nil : draft.code,
            label: label,
            startMinuteOfDay: draft.startMinuteOfDay ?? 0,
            endMinuteOfDay: draft.endMinuteOfDay ?? 0,
            workKind: .worked
        )
        context.insert(type)
        cache[key] = type
        return type
    }

    private static func hhmm(_ minute: Int) -> String {
        let m = ((minute % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    // MARK: - Fetches

    private static func fetchProfile(fingerprint: String, in context: ModelContext) -> ImportProfile? {
        let descriptor = FetchDescriptor<ImportProfile>(predicate: #Predicate { $0.sourceFingerprint == fingerprint })
        return try? context.fetch(descriptor).first
    }

    private static func fetchRoster(forProfileID profileID: String, in context: ModelContext) -> Roster? {
        let descriptor = FetchDescriptor<Roster>(predicate: #Predicate { $0.sourceImportProfileID == profileID })
        return try? context.fetch(descriptor).first
    }
}
