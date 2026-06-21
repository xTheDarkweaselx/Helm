//
//  RosterDiff.swift
//  HelmDomain
//
//  Pure, deterministic diff for idempotent re-import (DEVELOPMENT_PLAN.md v1.1).
//  Compares the previously-imported shifts against a freshly-parsed set, keyed by
//  dedupKey, and classifies each as added / updated / removed / unchanged —
//  preserving any user-authored instance so manual swaps/edits are never clobbered.
//

import Foundation

/// What Helm already knows about a previously-imported shift.
public struct ExistingShift: Sendable, Equatable {
    public let contentHash: String
    /// True if the user edited/added/swapped this instance (overrideKind != none).
    public let isUserAuthored: Bool

    public init(contentHash: String, isUserAuthored: Bool) {
        self.contentHash = contentHash
        self.isUserAuthored = isUserAuthored
    }
}

public struct RosterDiff: Sendable, Equatable {
    public var added: [String] = []      // dedupKeys present only in the new import
    public var updated: [String] = []    // same key, different content (and not user-authored)
    public var removed: [String] = []    // previously imported, gone now (and not user-authored)
    public var unchanged: [String] = []  // same key + content, or preserved user edits

    public var hasChanges: Bool { !added.isEmpty || !updated.isEmpty || !removed.isEmpty }
    public var isEmpty: Bool { added.isEmpty && updated.isEmpty && removed.isEmpty && unchanged.isEmpty }
}

public enum RosterDiffer {

    /// Diff a freshly-parsed roster (`incoming`: dedupKey → contentHash) against
    /// what was imported before (`existing`: dedupKey → ExistingShift).
    /// User-authored instances are never marked updated or removed.
    public static func diff(existing: [String: ExistingShift], incoming: [String: String]) -> RosterDiff {
        var result = RosterDiff()

        for (key, newHash) in incoming {
            if let prior = existing[key] {
                if prior.isUserAuthored {
                    result.unchanged.append(key)        // never clobber a manual edit
                } else if prior.contentHash != newHash {
                    result.updated.append(key)
                } else {
                    result.unchanged.append(key)
                }
            } else {
                result.added.append(key)
            }
        }

        for (key, prior) in existing where incoming[key] == nil {
            if prior.isUserAuthored {
                result.unchanged.append(key)            // keep user-added shifts
            } else {
                result.removed.append(key)
            }
        }

        result.added.sort(); result.updated.sort(); result.removed.sort(); result.unchanged.sort()
        return result
    }
}
