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
    /// Where the events were written (v5: possibly several at once).
    var destinations: Set<CalendarTargetKind> = [.eventkit]
    /// Destinations this apply moved the roster AWAY from (no longer selected).
    var movedFrom: Set<CalendarTargetKind> = []
    /// An old destination still holds a copy Helm couldn't remove (signed out,
    /// denied, offline, or a previous Google account) — shown to the user.
    var oldDestinationCleanupFailed = false

    /// User-facing name(s) of the destination calendar(s).
    var destinationName: String {
        Self.name(for: destinations)
    }

    static func name(for kind: CalendarTargetKind) -> String {
        switch kind {
        case .google: "Google Calendar"
        case .eventkit, .ics: "Apple Calendar"
        }
    }

    static func name(for kinds: Set<CalendarTargetKind>) -> String {
        guard !kinds.isEmpty else { return name(for: .eventkit) }
        return kinds.sorted { $0.rawValue < $1.rawValue }.map(name(for:)).joined(separator: " + ")
    }

    /// The full result sentence shown on the finished screen, including where
    /// the shifts went and any migration leftovers the user must know about.
    var userDescription: String {
        var text = "Added \(added), updated \(updated), removed \(removed), unchanged \(unchanged) — in \(destinationName)."
        if !movedFrom.isEmpty {
            text += oldDestinationCleanupFailed
                ? " The old copy in \(Self.name(for: movedFrom)) couldn't be removed — sign in there and re-import, or delete the “Helm Shifts” calendar entries manually."
                : " Moved over from \(Self.name(for: movedFrom))."
        } else if oldDestinationCleanupFailed {
            text += " A previous Google account's copy couldn't be removed — delete its “Helm Shifts” calendar manually."
        }
        return text
    }
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

    static func apply(_ plan: Plan, targets: [any CalendarTarget], in context: ModelContext) async throws -> SyncSummary {
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

        let title = result.displayName ?? result.sourceName
        let roster = fetchRoster(forProfileID: profile.id, in: context) ?? {
            let r = Roster(title: title)
            r.sourceImportProfileID = profile.id
            context.insert(r)
            return r
        }()
        roster.title = title // keep in sync (e.g. a renamed schedule)

        var existingByKey: [String: ShiftInstance] = [:]
        for instance in roster.instances ?? [] {
            if let key = instance.dedupKey { existingByKey[key] = instance }
        }

        // Destination migration: a re-apply aimed at a DIFFERENT destination
        // set than this roster's events live in (Apple ↔ Google ↔ both, or a
        // different Google account). Decided here, but DROPPED destinations are
        // only cleaned up AFTER the new-target writes succeed and SwiftData
        // commits — a destructive pre-write side effect can't be rolled back,
        // so failure must degrade to a recoverable duplicate, never a hole in
        // every calendar.
        let newKinds = Set(targets.compactMap { CalendarTargetKind(rawValue: $0.kind) })
        let oldKinds = profile.targets
        let newAccount = newKinds.contains(.google) ? GoogleConfig.accountEmail : nil
        let accountChanged = newKinds.contains(.google) && oldKinds.contains(.google)
            && profile.calendarAccount != nil && newAccount != nil
            && profile.calendarAccount != newAccount
        let isMigration = plan.isReimport && (oldKinds != newKinds || accountChanged) && !existingByKey.isEmpty
        let oldKeys = Array(existingByKey.keys) // captured before any mutation
        profile.targets = newKinds
        profile.calendarAccount = newAccount
        // Last-wins on duplicate keys (matches incomingMap, used for the diff).
        // The trapping uniqueKeysWithValues: would crash on two same-day same-code rows.
        let incomingByKey = Dictionary(
            result.drafts.filter(\.isWritable).map { (key(for: $0), $0) },
            uniquingKeysWith: { _, last in last })

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
            if let cal = calendarDraft(for: instance) { draftsToWrite.append(cal) }
        }

        // Updated: mutate existing instances in place.
        for key in plan.diff.updated {
            guard let draft = incomingByKey[key], let instance = existingByKey[key] else { continue }
            let type = shiftType(for: draft, cache: &typeCache, context: context)
            apply(draft: draft, to: instance, type: type)
            if let cal = calendarDraft(for: instance) { draftsToWrite.append(cal) }
        }

        let run = ImportRun(importProfile: profile)
        run.addedCount = plan.diff.added.count
        run.changedCount = plan.diff.updated.count
        run.removedCount = plan.diff.removed.count
        run.skippedCount = result.drafts.count - result.writableCount
        context.insert(run)

        // Migrating destinations: every CURRENT target must receive the FULL
        // roster (unchanged + user-authored shifts included), not just the diff
        // — newly-added destinations have nothing yet, and dropped ones are
        // about to lose their copy. Upserts are idempotent on all targets, so
        // over-writing is safe.
        if isMigration {
            let removedSet = Set(removedKeys)
            draftsToWrite = (roster.instances ?? [])
                .filter { !removedSet.contains($0.dedupKey ?? "") }
                .compactMap(calendarDraft(for:))
        }

        // Write the calendars BEFORE committing SwiftData, so a calendar failure
        // (e.g. access revoked) rolls the data changes back instead of leaving the
        // store and the calendars permanently out of sync. The SwiftData mutations
        // above are still uncommitted at this point.
        do {
            for target in targets {
                if !removedKeys.isEmpty, !isMigration { _ = try await target.remove(dedupKeys: removedKeys) }
                if !draftsToWrite.isEmpty { _ = try await target.write(draftsToWrite) }
            }
        } catch {
            context.rollback()
            throw error
        }

        try context.save()

        // Dropped-destination cleanup, best-effort, only now that the new
        // calendars and the store are committed. Failure (signed out, denied,
        // offline, or an old Google account we no longer have a token for)
        // leaves duplicates behind — surfaced via the summary, never silent.
        var cleanupFailed = false
        let droppedKinds = oldKinds.subtracting(newKinds)
        if isMigration {
            if accountChanged {
                // The old Google account's token is gone; its copy can't be removed.
                cleanupFailed = true
            }
            for kind in droppedKinds {
                if let oldTarget = try? await CalendarTargetProvider.authorizedTarget(for: kind) {
                    do { _ = try await oldTarget.remove(dedupKeys: oldKeys) } catch { cleanupFailed = true }
                } else {
                    cleanupFailed = true
                }
            }
        }

        return SyncSummary(
            added: plan.diff.added.count,
            updated: plan.diff.updated.count,
            removed: plan.diff.removed.count,
            unchanged: plan.diff.unchanged.count,
            isReimport: plan.isReimport,
            destinations: newKinds,
            movedFrom: isMigration ? droppedKinds : [],
            oldDestinationCleanupFailed: cleanupFailed
        )
    }

    /// Delete a roster and all of its calendar events (from EVERY destination
    /// it lives in). Removes the events FIRST so a failed/denied calendar
    /// removal doesn't orphan them (the roster stays).
    static func delete(roster: Roster, targets: [any CalendarTarget], in context: ModelContext) async throws {
        let keys = (roster.instances ?? []).compactMap(\.dedupKey)
        if !keys.isEmpty {
            for target in targets { _ = try await target.remove(dedupKeys: keys) }
        }
        context.delete(roster)
        try context.save()
    }

    /// The calendar destination(s) this roster's events were last written to
    /// (recorded on its ImportProfile at apply time), so delete/resync clean up
    /// the right calendars even if the user has since switched destinations.
    static func destinations(for roster: Roster, in context: ModelContext) -> Set<CalendarTargetKind> {
        guard let profileID = roster.sourceImportProfileID else { return [.eventkit] }
        let descriptor = FetchDescriptor<ImportProfile>(predicate: #Predicate { $0.id == profileID })
        return (try? context.fetch(descriptor).first)?.targets ?? [.eventkit]
    }

    // MARK: - Mapping helpers

    static func fingerprint(for sourceName: String) -> String {
        sourceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func key(for draft: DraftShift) -> String { draft.dedupKey }

    private static func title(for draft: DraftShift, type: ShiftType) -> String {
        draft.title ?? type.label ?? type.code ?? "Shift"
    }

    /// The title an instance WILL be persisted with — must match `title(for:type:)`
    /// using the type that `shiftType(for:)` would build, so the diff's incoming
    /// hash equals the existing instance's hash (no false "updated" churn).
    private static func resolvedTitle(for draft: DraftShift) -> String {
        if let t = draft.title { return t }
        if let l = draft.label { return l }
        if let s = draft.startMinuteOfDay {
            return hhmm(s) + (draft.endMinuteOfDay.map { "–" + hhmm($0) } ?? "")
        }
        return draft.code.isEmpty ? "Shift" : draft.code
    }

    private static func existingMap(for roster: Roster) -> [String: ExistingShift] {
        var map: [String: ExistingShift] = [:]
        for instance in roster.instances ?? [] {
            guard let key = instance.dedupKey else { continue }
            // Alarms are intentionally excluded from the DIFF hash (they're derived
            // from the shift type, not the source) to avoid false "updated" churn.
            map[key] = ExistingShift(
                contentHash: ShiftContentHash.make(
                    title: instance.title,
                    startUTC: instance.startUTC,
                    endUTC: instance.endUTC,
                    location: instance.locationName,
                    timeZoneIdentifier: instance.timeZoneIdentifier
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
            title: resolvedTitle(for: draft), // must equal the persisted instance.title
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

    /// The reminder offsets an instance's events get: its roster's override
    /// when set (v4), else the global default. "" override = explicitly none.
    static func effectiveReminderOffsets(for roster: Roster?) -> [Int] {
        if let raw = roster?.reminderOffsetsRaw {
            return ReminderOffsets.parse(raw)
        }
        return ReminderSetting.offsets
    }

    /// Remove ONE shift from its calendar(s) and from Helm. Calendars first, so
    /// a failed removal leaves the data intact. NOTE: a later re-import/re-apply
    /// of the same source will diff it as "added" and bring it back — callers
    /// say so in their confirmation UI.
    static func removeInstance(_ instance: ShiftInstance, targets: [any CalendarTarget], in context: ModelContext) async throws {
        if let key = instance.dedupKey {
            for target in targets { _ = try await target.remove(dedupKeys: [key]) }
        }
        context.delete(instance)
        try context.save()
    }

    /// Build the calendar draft for an instance, stamping the effective
    /// (per-roster or global) reminders as alarm offsets.
    static func calendarDraft(for instance: ShiftInstance) -> CalendarEventDraft? {
        guard let start = instance.startUTC, let end = instance.endUTC else { return nil }
        let offsets = effectiveReminderOffsets(for: instance.roster)
        let title = instance.title ?? instance.shiftType?.label ?? instance.shiftType?.code ?? "Shift"
        return CalendarEventDraft(
            dedupKey: instance.dedupKey ?? instance.id,
            title: title,
            location: instance.locationName,
            start: start,
            end: end,
            timeZoneIdentifier: instance.timeZoneIdentifier,
            alarmOffsetsMinutes: offsets,
            contentHash: ShiftContentHash.make(
                title: instance.title, startUTC: start, endUTC: end,
                location: instance.locationName, timeZoneIdentifier: instance.timeZoneIdentifier
            )
        )
    }

    /// All calendar drafts for a roster (for .ics export and re-apply).
    static func drafts(for roster: Roster) -> [CalendarEventDraft] {
        (roster.instances ?? [])
            .sorted { ($0.startUTC ?? .distantPast) < ($1.startUTC ?? .distantPast) }
            .compactMap(calendarDraft(for:))
    }

    /// Re-write all of a roster's events to every destination (e.g. after the
    /// reminder setting changes, or to restore after "Remove Helm events").
    @discardableResult
    static func resync(roster: Roster, targets: [any CalendarTarget]) async throws -> Int {
        let drafts = drafts(for: roster)
        guard !drafts.isEmpty else { return 0 }
        for target in targets { _ = try await target.write(drafts) }
        return drafts.count
    }

    private static func shiftType(for draft: DraftShift, cache: inout [String: ShiftType], context: ModelContext) -> ShiftType {
        // shiftTypeID first: two built types sharing a code must each resolve
        // themselves (a code-only key would collapse them to one).
        let key = draft.shiftTypeID
            ?? (draft.code.isEmpty
                ? "inline:\(draft.startMinuteOfDay ?? 0)-\(draft.endMinuteOfDay ?? 0)"
                : draft.code)
        if let cached = cache[key] { return cached }
        // Rota builder: reuse the exact built ShiftType (rich color/break/location),
        // not a synthesized bare one.
        if let id = draft.shiftTypeID {
            let descriptor = FetchDescriptor<ShiftType>(predicate: #Predicate { $0.id == id })
            if let built = try? context.fetch(descriptor).first {
                cache[key] = built
                return built
            }
        }
        // Reuse an existing ShiftType so a changed re-import doesn't insert a
        // duplicate type each time (and orphan the old one).
        if let found = fetchShiftType(for: draft, context: context) {
            cache[key] = found
            return found
        }
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

    private static func fetchShiftType(for draft: DraftShift, context: ModelContext) -> ShiftType? {
        let start = draft.startMinuteOfDay ?? 0
        let end = draft.endMinuteOfDay ?? 0
        if draft.code.isEmpty {
            let d = FetchDescriptor<ShiftType>(predicate: #Predicate {
                $0.code == nil && $0.startMinuteOfDay == start && $0.endMinuteOfDay == end
            })
            return try? context.fetch(d).first
        } else {
            let code = draft.code
            let d = FetchDescriptor<ShiftType>(predicate: #Predicate { $0.code == code })
            return try? context.fetch(d).first
        }
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
