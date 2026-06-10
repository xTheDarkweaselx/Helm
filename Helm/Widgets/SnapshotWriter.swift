//
//  SnapshotWriter.swift
//  Helm
//
//  v7 widgets (app side): project the live shifts into the shared HelmSnapshot
//  and write it to the App Group container (JSON file + a UserDefaults mirror)
//  for the widget extension to read. NO-OPS gracefully until the App Group is
//  configured (containerURL nil), exactly like the CloudKit gate — the app
//  builds and runs today with the widget target absent.
//

import Foundation
import SwiftData
import HelmDomain
#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor
enum SnapshotWriter {
    /// Recompute and publish the snapshot from the current store, then nudge any
    /// installed widgets. Safe to call from any save chokepoint.
    static func refresh(context: ModelContext) {
        let instances = (try? context.fetch(FetchDescriptor<ShiftInstance>())) ?? []
        let inputs: [SnapshotInputShift] = instances.map { inst in
            SnapshotInputShift(
                id: inst.id,
                title: inst.title ?? inst.shiftType?.label ?? inst.shiftType?.code ?? "Shift",
                location: inst.locationName,
                colorHex: inst.shiftType?.colorHex,
                start: inst.startUTC,
                end: inst.endUTC,
                localDate: inst.localDate,
                isAllDay: inst.isAllDay ?? false,
                paidHours: inst.computedPaidHours
            )
        }
        let snapshot = HelmSnapshotBuilder.build(shifts: inputs, now: .now, calendar: .current)
        write(snapshot)
        LiveActivityController.sync(current: snapshot.current)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    static func write(_ snapshot: HelmSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        if let url = containerURL() {
            try? data.write(to: url, options: .atomic)
        }
        // Redundant mirror; harmless if the suite isn't shared yet.
        UserDefaults(suiteName: HelmAppGroup.defaultsSuite)?.set(data, forKey: HelmAppGroup.snapshotDefaultsKey)
    }

    /// nil until the App Group capability is added (then the widget reads the
    /// same URL). Its nil-ness is exactly what makes the writer a safe no-op.
    static func containerURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: HelmAppGroup.identifier)?
            .appendingPathComponent(HelmAppGroup.snapshotFilename)
    }
}
