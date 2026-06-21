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

    /// Whether a Pro-only feature should be blocked, given the entitlement state.
    /// Returns false for everyone while `enforced` is false.
    static func isLocked(isPro: Bool) -> Bool { enforced && !isPro }
}
