//
//  WatchBridge.swift
//  Helm
//
//  v7.5 (iOS only): pushes the shared HelmSnapshot to the paired Apple Watch.
//  The App Group does not cross devices, so the watch gets the SAME JSON blob
//  over WatchConnectivity's applicationContext — latest-state semantics (each
//  push replaces the previous one, delivered when the watch wakes), which is
//  exactly right for a snapshot. The watch side (HelmWatch/PhoneLink.swift)
//  stores it under HelmAppGroup.snapshotDefaultsKey in its own suite, so the
//  staged SnapshotStore reads it verbatim.
//

import Foundation
import HelmDomain

#if os(iOS)
import WatchConnectivity

/// MainActor like the rest of the app (callers are the MainActor SnapshotWriter);
/// WCSession delegate callbacks arrive on a background queue, so the protocol
/// witnesses are explicitly nonisolated and touch no state.
final class WatchBridge: NSObject, WCSessionDelegate {
    static let shared = WatchBridge()

    /// Idempotent: assigns the delegate and activates once per launch.
    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if session.delegate !== self { session.delegate = self }
        if session.activationState == .notActivated { session.activate() }
    }

    /// Pushes the encoded snapshot. Silently no-ops without a paired watch with
    /// the app installed — same graceful degradation as the App Group writer.
    func push(snapshotData: Data) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled else { return }
        try? session.updateApplicationContext([HelmAppGroup.watchSnapshotContextKey: snapshotData])
    }

    // MARK: WCSessionDelegate (background queue → nonisolated, stateless)

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate after a watch switch (Apple's documented pattern).
        session.activate()
    }
}
#endif
