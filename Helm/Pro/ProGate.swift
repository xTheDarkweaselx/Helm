//
//  ProGate.swift
//  Helm
//
//  v9 Paywall FOUNDATION. The whole point of this file is the master switch
//  below: while `enforced` is false NOTHING is locked, the paywall is purely
//  informational, and every feature stays free. The StoreKit plumbing (ProStore)
//  and the PaywallView exist so a future build can flip `enforced` to true and
//  decide which features gate — without rebuilding the store or the paywall.
//

import Foundation

enum ProGate {
    /// MASTER SWITCH — keep false. While false, `isLocked(...)` always returns
    /// false: no feature is ever blocked. Flip to true (and add `isLocked` checks
    /// at the features you choose) to actually paywall.
    static let enforced = false

    /// Whether to surface the in-app "Helm Pro" purchase entry (Settings section
    /// + paywall). FALSE for the v1 launch model — Helm is a PAID app and
    /// everything inside is free, so an "Unlock Helm Pro" screen would make no
    /// sense. The StoreKit plumbing (ProStore / PaywallView / HelmPro.storekit)
    /// stays intact; flip this to true (with `enforced`) to pivot to a free app
    /// with a paid Pro tier without rebuilding any of it.
    static let offersUpgrade = false

    /// Whether a Pro-only feature should be blocked, given the entitlement state.
    /// Returns false for everyone while `enforced` is false.
    static func isLocked(isPro: Bool) -> Bool { enforced && !isPro }
}
