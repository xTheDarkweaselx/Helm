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
    /// Throws (deleting NOTHING) when the schedule's events can't be removed
    /// from their calendar — e.g. they live in Google and the account is signed
    /// out — so the caller can warn instead of silently stranding events.
    /// `force` deletes the data anyway, knowingly leaving the events behind.
    /// EventKit-denied keeps the historical best-effort behaviour (data deletes;
    /// the user explicitly chose to deny Helm the calendar).
    static func deleteSchedule(_ schedule: Schedule, in context: ModelContext, force: Bool = false) async throws {
        let fingerprint = RosterSyncEngine.fingerprint(for: "schedule:\(schedule.id)")
        if let profile = try? context.fetch(FetchDescriptor<ImportProfile>(predicate: #Predicate { $0.sourceFingerprint == fingerprint })).first {
            let pid = profile.id
            if let roster = try? context.fetch(FetchDescriptor<Roster>(predicate: #Predicate { $0.sourceImportProfileID == pid })).first {
                do {
                    let target = try await CalendarTargetProvider.authorizedTarget(for: profile.target)
                    try await RosterSyncEngine.delete(roster: roster, target: target, in: context)
                } catch {
                    let tolerable = force || (error as? CalendarAccessError) == .eventKitDenied
                    guard tolerable else { throw error }
                    context.delete(roster)
                }
            }
            context.delete(profile)
        }
        context.delete(schedule)
        try? context.save()
    }

    func commit(in context: ModelContext) async {
        guard let plan else { return }
        phase = .writing
        do {
            let target = try await CalendarTargetProvider.authorizedTarget()
            let summary = try await RosterSyncEngine.apply(plan, target: target, in: context)
            phase = .finished(summary)
        } catch CalendarAccessError.eventKitDenied {
            phase = .failed("Calendar access was denied. Enable it for Helm in Settings, then try again. Your schedule is saved.")
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
