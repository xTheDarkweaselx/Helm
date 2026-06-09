//
//  Enums.swift
//  Helm
//
//  Domain enumerations. Stored on @Model types as raw `String` (with a default)
//  so they satisfy CloudKit's "every attribute optional or defaulted" rule, with
//  typed computed accessors for ergonomic use in code.
//

import Foundation

/// What a shift represents for pay / presence purposes.
enum WorkKind: String, CaseIterable, Codable, Sendable {
    case worked
    case onCall
    case standby
    case off
    case leave
}

/// How a materialized instance diverges from what the source said.
/// Anything other than `.none` is user-authored and must never be clobbered by re-import.
enum OverrideKind: String, CaseIterable, Codable, Sendable {
    case none
    case modified
    case cancelled
    case added
    case swapped
}

/// A timeline segment in a built schedule: a repeating cycle, or an explicit list of dated days.
enum SegmentKind: String, CaseIterable, Codable, Sendable {
    case cyclic
    case explicit
}

/// The layout Helm detected for a source spreadsheet.
enum LayoutKind: String, CaseIterable, Codable, Sendable {
    case list   // one row per day (date down a column)
    case matrix // days across columns, people/rows down
}

/// Which calendar destination a sync record targets.
enum CalendarTargetKind: String, CaseIterable, Codable, Sendable {
    case eventkit
    case google
    case ics
}

/// Lifecycle of a single calendar write, tracked in the idempotency ledger.
enum SyncStatus: String, CaseIterable, Codable, Sendable {
    case pending
    case written
    case confirmed
    case failed
    case deleted
}
