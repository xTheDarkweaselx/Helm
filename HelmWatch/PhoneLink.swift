//
//  PhoneLink.swift
//  HelmWatch (STAGED — add to the watch APP target in Xcode; see README.md)
//
//  The watch side of the snapshot pipe: receives the iPhone's HelmSnapshot
//  blob over WatchConnectivity applicationContext (latest-state semantics),
//  persists it under the SAME key SnapshotStore reads (so the complications
//  see it too), and exposes the decoded snapshot to the watch UI.
//

import Foundation
import WatchConnectivity
import HelmDomain
#if canImport(WidgetKit)
import WidgetKit
#endif

@Observable
final class PhoneLink: NSObject, WCSessionDelegate {
    static let shared = PhoneLink()

    private(set) var snapshot: HelmSnapshot = .empty
    private(set) var lastReceivedAt: Date?

    /// Idempotent: load whatever arrived previously, then (re)activate.
    func activate() {
        loadStored()
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if session.delegate !== self { session.delegate = self }
        if session.activationState == .notActivated { session.activate() }
    }

    /// Persist + decode a freshly received blob, and wake the complications.
    func ingest(_ data: Data) {
        // App Group suite when the capability is configured; standard defaults
        // as the ever-present fallback (the watch APP can always read its own).
        UserDefaults(suiteName: HelmAppGroup.defaultsSuite)?.set(data, forKey: HelmAppGroup.snapshotDefaultsKey)
        UserDefaults.standard.set(data, forKey: HelmAppGroup.snapshotDefaultsKey)
        if let snap = try? JSONDecoder().decode(HelmSnapshot.self, from: data) {
            snapshot = snap
            lastReceivedAt = .now
        }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    private func loadStored() {
        let data = UserDefaults(suiteName: HelmAppGroup.defaultsSuite)?.data(forKey: HelmAppGroup.snapshotDefaultsKey)
            ?? UserDefaults.standard.data(forKey: HelmAppGroup.snapshotDefaultsKey)
        if let data, let snap = try? JSONDecoder().decode(HelmSnapshot.self, from: data) {
            snapshot = snap
        }
    }

    // MARK: WCSessionDelegate (background queue → nonisolated; hop to MainActor)

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        // A context may have been delivered while we weren't running.
        let context = session.receivedApplicationContext
        guard let data = context[HelmAppGroup.watchSnapshotContextKey] as? Data else { return }
        Task { @MainActor in PhoneLink.shared.ingest(data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[HelmAppGroup.watchSnapshotContextKey] as? Data else { return }
        Task { @MainActor in PhoneLink.shared.ingest(data) }
    }
}
