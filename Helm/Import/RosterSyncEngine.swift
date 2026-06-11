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
        // v6: code-learning creates the ImportProfile EAGERLY (before any
        // commit), so "re-import" must mean a ROSTER exists, not a profile.
        let roster = profile.flatMap { fetchRoster(forProfileID: $0.id, in: context) }
        let existing = roster.map(existingMap(for:)) ?? [:]
        let incoming = incomingMap(for: result)
        return Plan(
            result: result,
            diff: RosterDiffer.diff(existing: existing, incoming: incoming),
            isReimport: roster != nil,
            existingProfileID: profile?.id
        )
    }

    // MARK: - Apply (mutates SwiftData + calendar)

    static func apply(_ plan: Plan, targets: [any CalendarTarget], in context: ModelContext) async throws -> SyncSummary {
        let result = plan.result
        let fingerprint = fingerprint(for: result.sourceName)

        // ── STAGE (read-only) ────────────────────────────────────────────────
        // NOTHING below mutates the store until every calendar write succeeds.
        // The old shape mutated first and relied on rollback() in the catch —
        // but these writes can suspend for MINUTES under Google throttling and
        // the main context autosaves, so a mid-await commit silently turned
        // rollback() into a no-op, leaving store and calendars diverged.
        let existingProfile = fetchProfile(fingerprint: fingerprint, in: context)
        let existingRoster = existingProfile.flatMap { fetchRoster(forProfileID: $0.id, in: context) }

        var existingByKey: [String: ShiftInstance] = [:]
        for instance in existingRoster?.instances ?? [] {
            if let key = instance.dedupKey { existingByKey[key] = instance }
        }

        // Destination migration: a re-apply aimed at a DIFFERENT destination
        // set than this roster's events live in (Apple ↔ Google ↔ both, or a
        // different Google account). Decided from PRE-apply state; DROPPED
        // destinations are only cleaned up AFTER the new-target writes succeed
        // and SwiftData commits — a destructive pre-write side effect can't be
        // rolled back, so failure must degrade to a recoverable duplicate,
        // never a hole in every calendar.
        let newKinds = Set(targets.compactMap { CalendarTargetKind(rawValue: $0.kind) })
        let oldKinds = existingProfile?.targets ?? [.eventkit]
        let newAccount = newKinds.contains(.google) ? GoogleConfig.accountEmail : nil
        let accountChanged = newKinds.contains(.google) && oldKinds.contains(.google)
            && existingProfile?.calendarAccount != nil && newAccount != nil
            && existingProfile?.calendarAccount != newAccount
        let isMigration = plan.isReimport && (oldKinds != newKinds || accountChanged) && !existingByKey.isEmpty
        let oldKeys = Array(existingByKey.keys)

        // Last-wins on duplicate keys (matches incomingMap, used for the diff).
        // The trapping uniqueKeysWithValues: would crash on two same-day same-code rows.
        let incomingByKey = Dictionary(
            result.drafts.filter(\.isWritable).map { (key(for: $0), $0) },
            uniquingKeysWith: { _, last in last })

        let removedKeys = plan.diff.removed

        // Calendar drafts staged STRAIGHT from the plan's source data via
        // stagedDraft(for:) — the pure twin of calendarDraft(for:) over the
        // instance the commit phase will create/update.
        var draftsToWrite: [CalendarEventDraft] = []
        for key in plan.diff.added {
            guard let draft = incomingByKey[key],
                  let staged = stagedDraft(for: draft, roster: existingRoster, in: context) else { continue }
            draftsToWrite.append(staged)
        }
        for key in plan.diff.updated {
            guard let draft = incomingByKey[key], existingByKey[key] != nil,
                  let staged = stagedDraft(for: draft, roster: existingRoster, in: context) else { continue }
            draftsToWrite.append(staged)
        }

        // Migrating destinations: every CURRENT target must receive the FULL
        // roster (unchanged + user-authored shifts included), not just the diff
        // — newly-added destinations have nothing yet, and dropped ones are
        // about to lose their copy. Survivors are read (not mutated) at their
        // stored content; updated rows are staged at their NEW content; added
        // rows join at theirs. Upserts are idempotent, so over-writing is safe.
        if isMigration {
            let removedSet = Set(removedKeys)
            let updatedSet = Set(plan.diff.updated)
            var migrated: [CalendarEventDraft] = []
            for instance in existingRoster?.instances ?? [] {
                if let key = instance.dedupKey, removedSet.contains(key) { continue }
                if let key = instance.dedupKey, updatedSet.contains(key),
                   let draft = incomingByKey[key],
                   let staged = stagedDraft(for: draft, roster: existingRoster, in: context) {
                    migrated.append(staged)
                } else if let cal = calendarDraft(for: instance) {
                    migrated.append(cal)
                }
            }
            for key in plan.diff.added {
                guard let draft = incomingByKey[key],
                      let staged = stagedDraft(for: draft, roster: existingRoster, in: context) else { continue }
                migrated.append(staged)
            }
            draftsToWrite = migrated
        }

        // ── WRITE CALENDARS (still nothing mutated — a throw is clean) ───────
        // v7.2: work in small chunks and report progress — Google throttling
        // can stretch a big roster into minutes, and silence reads as a hang.
        let progressTotal = targets.count * (removedKeys.count + draftsToWrite.count)
        if progressTotal > 0 {
            SyncProgress.shared.begin("Updating \(SyncSummary.name(for: newKinds))…", total: progressTotal)
        }
        defer { SyncProgress.shared.end() }
        for target in targets {
            // Always remove removed keys: on a newly-added destination they
            // don't exist and both adapters tolerate missing keys; on a
            // RETAINED destination during migration this is the only thing
            // that deletes them (the full rewrite only covers survivors).
            for chunk in removedKeys.chunks(of: 8) {
                _ = try await target.remove(dedupKeys: chunk)
                SyncProgress.shared.advance(chunk.count)
            }
            for chunk in draftsToWrite.chunks(of: 8) {
                _ = try await target.write(chunk)
                SyncProgress.shared.advance(chunk.count)
            }
        }

        // ── COMMIT (all mutations + save, with no await in between) ──────────
        let profile = existingProfile ?? {
            let p = ImportProfile(name: result.sourceName)
            p.sourceFingerprint = fingerprint
            p.layoutKindRaw = LayoutKind.list.rawValue
            context.insert(p)
            return p
        }()
        profile.lastImportedAt = .now
        profile.targets = newKinds
        profile.calendarAccount = newAccount

        let title = result.displayName ?? result.sourceName
        let roster = existingRoster ?? {
            let r = Roster(title: title)
            r.sourceImportProfileID = profile.id
            context.insert(r)
            return r
        }()
        roster.title = title // keep in sync (e.g. a renamed schedule)

        var typeCache: [String: ShiftType] = [:]
        for key in plan.diff.removed {
            if let instance = existingByKey[key] { context.delete(instance) }
        }
        for key in plan.diff.added {
            guard let draft = incomingByKey[key] else { continue }
            let type = shiftType(for: draft, cache: &typeCache, context: context)
            _ = makeInstance(from: draft, type: type, roster: roster, context: context)
        }
        for key in plan.diff.updated {
            guard let draft = incomingByKey[key], let instance = existingByKey[key] else { continue }
            let type = shiftType(for: draft, cache: &typeCache, context: context)
            apply(draft: draft, to: instance, type: type)
        }

        let run = ImportRun(importProfile: profile)
        run.addedCount = plan.diff.added.count
        run.changedCount = plan.diff.updated.count
        run.removedCount = plan.diff.removed.count
        run.skippedCount = result.drafts.count - result.writableCount
        context.insert(run)

        try context.save()
        SnapshotWriter.refresh(context: context)

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
            SyncProgress.shared.begin("Removing \(keys.count) shift\(keys.count == 1 ? "" : "s")…",
                                      total: keys.count * targets.count)
        }
        defer { SyncProgress.shared.end() }
        if !keys.isEmpty {
            for target in targets {
                for chunk in keys.chunks(of: 8) {
                    _ = try await target.remove(dedupKeys: chunk)
                    SyncProgress.shared.advance(chunk.count)
                }
            }
        }
        context.delete(roster)
        try context.save()
        SnapshotWriter.refresh(context: context)
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
        instance.isAllDay = draft.isAllDay ? true : nil
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
        instance.isAllDay = draft.isAllDay ? true : nil
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
            SyncProgress.shared.begin("Removing shift…", total: nil)
            defer { SyncProgress.shared.end() }
            for target in targets { _ = try await target.remove(dedupKeys: [key]) }
        }
        context.delete(instance)
        try context.save()
        SnapshotWriter.refresh(context: context)
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
            isAllDay: instance.isAllDay ?? false,
            alarmOffsetsMinutes: offsets,
            contentHash: ShiftContentHash.make(
                title: instance.title, startUTC: start, endUTC: end,
                location: instance.locationName, timeZoneIdentifier: instance.timeZoneIdentifier
            )
        )
    }

    /// The PURE twin of `calendarDraft(for:)` for a shift that has NOT been
    /// persisted yet: built straight from the source `DraftShift` so the
    /// write-first apply can stage calendar work before any model mutation.
    /// Must produce identical output to `calendarDraft(for:)` over the instance
    /// the commit phase will create — the title goes through the SAME type
    /// resolution `shiftType(for:)` will perform, just read-only.
    private static func stagedDraft(for draft: DraftShift, roster: Roster?, in context: ModelContext) -> CalendarEventDraft? {
        guard let start = draft.start, let end = draft.end else { return nil }
        let title = stagedTitle(for: draft, in: context)
        return CalendarEventDraft(
            dedupKey: draft.dedupKey,
            title: title,
            location: draft.location,
            start: start,
            end: end,
            timeZoneIdentifier: draft.timeZoneIdentifier,
            isAllDay: draft.isAllDay,
            alarmOffsetsMinutes: effectiveReminderOffsets(for: roster),
            contentHash: ShiftContentHash.make(
                title: title, startUTC: start, endUTC: end,
                location: draft.location, timeZoneIdentifier: draft.timeZoneIdentifier
            )
        )
    }

    /// What `title(for:type:)` WILL produce once `shiftType(for:)` resolves —
    /// computed read-only (no inserts): the same id-first / code lookup, and
    /// for a type that would be freshly created, the same label fallback chain
    /// (a created type's label is always non-nil, so type.label wins).
    private static func stagedTitle(for draft: DraftShift, in context: ModelContext) -> String {
        if let t = draft.title { return t }
        var type: ShiftType?
        if let id = draft.shiftTypeID {
            let d = FetchDescriptor<ShiftType>(predicate: #Predicate { $0.id == id })
            type = try? context.fetch(d).first
        }
        if type == nil { type = fetchShiftType(for: draft, context: context) }
        if let type { return type.label ?? type.code ?? "Shift" }
        return draft.label
            ?? draft.startMinuteOfDay.map { hhmm($0) + (draft.endMinuteOfDay.map { "\u{2013}" + hhmm($0) } ?? "") }
            ?? (draft.code.isEmpty ? "Shift" : draft.code)
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
        SyncProgress.shared.begin("Re-syncing \(drafts.count) shift\(drafts.count == 1 ? "" : "s")…",
                                  total: drafts.count * targets.count)
        defer { SyncProgress.shared.end() }
        for target in targets {
            for chunk in drafts.chunks(of: 8) {
                _ = try await target.write(chunk)
                SyncProgress.shared.advance(chunk.count)
            }
        }
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
