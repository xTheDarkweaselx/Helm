//
//  ShiftAlarmScheduler.swift
//  Helm
//
//  Optional "wake me up for my shift" alarms. When enabled in Settings, Helm
//  schedules a real system alarm (AlarmKit, iOS 26+) a configurable lead time
//  before each upcoming TIMED shift. AlarmKit alarms break through Silent mode
//  and Focus — including Sleep Focus — and ring full-screen exactly like a Clock
//  alarm. That is the closest an app is allowed to get to the system "Sleep ▸
//  Wake Up" alarm: Apple exposes NO public API to read or write the Clock app's
//  alarms or the Health Sleep schedule, so Helm creates its OWN alarm instead.
//
//  (Re)scheduled from SnapshotWriter.refresh whenever shifts change. It is an
//  `actor`, so overlapping refreshes (launch + foreground + import) serialise
//  instead of racing the cancel-then-reschedule sequence. It diffs the desired
//  set against a signature in UserDefaults so plain foregrounding doesn't churn
//  — but only records that signature once EVERY alarm actually scheduled, so a
//  failed schedule is retried on the next refresh rather than silently lost.
//  iOS-only; gated out of macOS/visionOS/watchOS.
//

import Foundation
import HelmDomain

/// Settings + persistence for the "wake me up for my shift" alarm. Cross-platform:
/// the global default lives in UserDefaults and a per-roster override lives on the
/// Roster (so both are editable from the Mac), even though the alarm itself only
/// fires on iOS via AlarmKit.
enum ShiftAlarmSetting {
    // nonisolated so the (non-MainActor) ShiftAlarmScheduler actor can read them
    // — the app target defaults to MainActor isolation.
    nonisolated static let enabledKey = "shiftAlarmsEnabled"
    nonisolated static let leadMinutesKey = "shiftAlarmLeadMinutes"
    nonisolated static let signatureKey = "shiftAlarmsSignature"
    nonisolated static let defaultLeadMinutes = 60

    /// Offered quick-pick lead times (minutes before the shift start); a roster
    /// can also store any custom value.
    nonisolated static let leadChoices = [15, 30, 45, 60, 90, 120, 180]

    nonisolated static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// The global default lead — the value a roster inherits when it has no override.
    nonisolated static var leadMinutes: Int {
        let stored = UserDefaults.standard.integer(forKey: leadMinutesKey)
        return stored > 0 ? stored : defaultLeadMinutes
    }

    /// A shift's effective lead: its roster's override (nil = inherit), else the
    /// global default.
    nonisolated static func effectiveLead(override: Int?) -> Int {
        override ?? leadMinutes
    }

    /// Human label for a lead time: "45 min" / "1 hr" / "2 hr 15 min".
    nonisolated static func label(forLead minutes: Int) -> String {
        let total = max(0, minutes)
        guard total > 0 else { return "at shift start" }
        let hours = total / 60, mins = total % 60
        switch (hours, mins) {
        case (0, _): return "\(mins) min"
        case (_, 0): return "\(hours) hr"
        default:     return "\(hours) hr \(mins) min"
        }
    }
}

/// One shift's wake-up request, carrying its OWN (roster-resolved) lead so the
/// scheduler can mix leads across rosters in a single pass.
struct ShiftAlarmRequest: Sendable {
    let start: Date?
    let isAllDay: Bool
    let isTentative: Bool
    let title: String
    let leadMinutes: Int
}

#if os(iOS) && canImport(AlarmKit)
import AlarmKit
import SwiftUI   // tint Color

@available(iOS 26.0, *)
actor ShiftAlarmScheduler {
    static let shared = ShiftAlarmScheduler()
    private init() {}

    /// Only schedule alarms within this window; later shifts re-materialise on
    /// the next refresh (alarm slots are finite, and far-future shifts move).
    private static let horizonDays = 30
    /// Safety cap on concurrently-scheduled alarms.
    private static let maxAlarms = 24

    /// No extra Live-Activity payload needed for a simple wake-up alarm.
    struct Metadata: AlarmMetadata {}

    private struct Pending {
        let fireDate: Date
        let title: String
    }

    /// (Re)build the alarm set from the live shifts, each request carrying its own
    /// (roster-resolved) lead. Cheap no-op when the desired set matches what we
    /// last scheduled. Actor-isolated, so concurrent callers run one-at-a-time.
    func reschedule(from requests: [ShiftAlarmRequest]) async {
        let now = Date()
        let horizon = Calendar.current.date(byAdding: .day, value: Self.horizonDays, to: now) ?? now

        let pending: [Pending] = requests
            .compactMap { request -> Pending? in
                // Only timed, non-tentative shifts have a real wake-up moment.
                guard !request.isAllDay, !request.isTentative, let start = request.start else { return nil }
                let lead = TimeInterval(max(0, request.leadMinutes) * 60)
                let fire = start.addingTimeInterval(-lead)
                guard fire > now, start <= horizon else { return nil }
                return Pending(fireDate: fire, title: request.title)
            }
            .sorted { $0.fireDate < $1.fireDate }
            .prefix(Self.maxAlarms)
            .map { $0 }

        // Skip entirely if nothing changed since we last *fully* scheduled.
        let signature = pending.map { "\(Int($0.fireDate.timeIntervalSince1970))|\($0.title)" }.joined(separator: ";")
        if signature == UserDefaults.standard.string(forKey: ShiftAlarmSetting.signatureKey) { return }

        // Don't persist the signature when unauthorized — the guard returns
        // before recording it, so a later grant retries.
        guard await ensureAuthorized() else { return }

        await cancelHelmAlarms()
        var allScheduled = true
        for item in pending {
            if await schedule(item) == false { allScheduled = false }
        }

        // Record the signature ONLY if the whole set actually landed; otherwise
        // clear it so the next refresh retries the missing alarms instead of
        // treating a partial/failed schedule as done.
        if allScheduled {
            UserDefaults.standard.set(signature, forKey: ShiftAlarmSetting.signatureKey)
        } else {
            UserDefaults.standard.removeObject(forKey: ShiftAlarmSetting.signatureKey)
        }
    }

    /// Remove every alarm Helm scheduled (the feature was switched off). All
    /// alarms in our AlarmManager belong to Helm — AlarmKit is per-app.
    func cancelAll() async {
        await cancelHelmAlarms()
        UserDefaults.standard.removeObject(forKey: ShiftAlarmSetting.signatureKey)
    }

    // MARK: - AlarmKit plumbing

    private func cancelHelmAlarms() async {
        let manager = AlarmManager.shared
        let existing = (try? manager.alarms) ?? []
        for alarm in existing {
            try? manager.cancel(id: alarm.id)
        }
    }

    /// Returns whether the alarm actually scheduled.
    private func schedule(_ item: Pending) async -> Bool {
        let stop = AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.fill")
        let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: item.title),
                                            stopButton: stop)
        let attributes = AlarmAttributes(presentation: AlarmPresentation(alert: alert),
                                         metadata: Metadata(),
                                         tintColor: .accentColor)
        let configuration = AlarmManager.AlarmConfiguration(
            schedule: .fixed(item.fireDate),
            attributes: attributes
        )
        do {
            _ = try await AlarmManager.shared.schedule(id: UUID(), configuration: configuration)
            return true
        } catch {
            return false
        }
    }

    private func ensureAuthorized() async -> Bool {
        let manager = AlarmManager.shared
        switch manager.authorizationState {
        case .authorized:
            return true
        case .denied:
            return false
        case .notDetermined:
            let state = try? await manager.requestAuthorization()
            return state == .authorized
        @unknown default:
            let state = try? await manager.requestAuthorization()
            return state == .authorized
        }
    }
}
#endif
