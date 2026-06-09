//
//  ScheduleCoordinator.swift
//  Helm
//
//  Drives preview + apply for a built Schedule, reusing RosterSyncEngine verbatim
//  (mirrors ImportCoordinator). Materialise → plan (diff preview) → commit (write).
//

import Foundation
import SwiftData

@MainActor
@Observable
final class ScheduleCoordinator {
    enum Phase: Equatable {
        case idle
        case loaded
        case writing
        case finished(SyncSummary)
        case failed(String)
    }

    var phase: Phase = .idle
    var plan: RosterSyncEngine.Plan?

    /// Materialise the schedule and compute the add/update/remove diff (read-only).
    func preparePlan(for schedule: Schedule, in context: ModelContext) {
        let result = ScheduleMaterializer.makeResult(for: schedule)
        plan = RosterSyncEngine.plan(for: result, in: context)
        phase = .loaded
    }

    /// Delete a schedule and everything it generated: its calendar events, the
    /// backing Roster + ImportProfile, then the schedule (segments/exceptions cascade).
    static func deleteSchedule(_ schedule: Schedule, in context: ModelContext) async {
        let fingerprint = RosterSyncEngine.fingerprint(for: "schedule:\(schedule.id)")
        let writer = ShiftCalendarWriter()
        _ = await writer.requestAccess()
        if let profile = try? context.fetch(FetchDescriptor<ImportProfile>(predicate: #Predicate { $0.sourceFingerprint == fingerprint })).first {
            let pid = profile.id
            if let roster = try? context.fetch(FetchDescriptor<Roster>(predicate: #Predicate { $0.sourceImportProfileID == pid })).first {
                try? await RosterSyncEngine.delete(roster: roster, target: writer, in: context)
            }
            context.delete(profile)
        }
        context.delete(schedule)
        try? context.save()
    }

    func commit(in context: ModelContext) async {
        guard let plan else { return }
        phase = .writing
        let writer = ShiftCalendarWriter()
        guard await writer.requestAccess() else {
            phase = .failed("Calendar access was denied. Enable it for Helm in Settings, then try again. Your schedule is saved.")
            return
        }
        do {
            let summary = try await RosterSyncEngine.apply(plan, target: writer, in: context)
            phase = .finished(summary)
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
