//
//  LiveActivityController.swift
//  Helm
//
//  v7 Live Activity (app side): start/update/end the "on shift now" Live
//  Activity. Entirely gated behind `#if os(iOS)` + availability,
//  so it is a no-op on macOS (no ActivityKit) and on older iOS. The shared
//  attributes type lives in HelmDomain; the ActivityKit conformance is added
//  retroactively here (and again in the widget target).
//
//  NOTE: the ActivityKit body can only be verified by an iOS build/device — it
//  is excluded from the macOS typecheck. Kept minimal and standard. The Live
//  Activity also needs NSSupportsLiveActivities=YES in the app's Info.plist
//  (a manual Xcode step) before it will start.
//

import Foundation
import HelmDomain

#if os(iOS)
import ActivityKit

extension ShiftActivityAttributes: @retroactive ActivityAttributes {}
#endif

@MainActor
enum LiveActivityController {
    /// Reconcile the live activity with the currently-on shift: update the
    /// running one, start one if a shift just began, or end them when none is on.
    static func sync(current: SnapshotShift?) {
        #if os(iOS)
        guard #available(iOS 16.2, *) else { return }
        Task { await reconcile(current: current) }
        #endif
    }

    #if os(iOS)
    @available(iOS 16.2, *)
    private static func reconcile(current: SnapshotShift?) async {
        let running = Activity<ShiftActivityAttributes>.activities

        guard let current, let start = current.start, let end = current.end else {
            for activity in running { await activity.end(nil, dismissalPolicy: .immediate) }
            return
        }

        let state = ShiftActivityAttributes.ContentState(
            title: current.title, start: start, end: end, location: current.location
        )
        let content = ActivityContent(state: state, staleDate: end)

        if let match = running.first(where: { $0.attributes.shiftID == current.id }) {
            await match.update(content)
            // End any other stale activities.
            for activity in running where activity.id != match.id {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            return
        }

        // Different (or no) activity running: clear and start fresh.
        for activity in running { await activity.end(nil, dismissalPolicy: .immediate) }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = ShiftActivityAttributes(shiftID: current.id, colorHex: current.colorHex)
        _ = try? Activity.request(attributes: attributes, content: content, pushType: nil)
    }
    #endif
}
