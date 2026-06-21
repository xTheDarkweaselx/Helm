//
//  CalendarTarget.swift
//  HelmCalendar
//
//  The provider-agnostic seam (ADR-1). The import pipeline produces
//  `CalendarEventDraft`s and hands them to a `CalendarTarget`; concrete adapters
//  (EventKit, .ics, Google) implement this without the pipeline knowing which.
//  Pure value types here keep the package testable; the EventKit/Google adapters
//  (which import platform frameworks) live alongside or in the app target.
//

import Foundation

/// A calendar event Helm intends to write, carrying its idempotency key so the
/// target can update-in-place rather than duplicate on re-import (ADR-3).
public struct CalendarEventDraft: Sendable, Equatable {
    public let dedupKey: String
    public let title: String
    public let location: String?
    public let notes: String?
    public let start: Date
    public let end: Date
    public let timeZoneIdentifier: String
    public let isAllDay: Bool
    /// Stamped onto the event (e.g. `helm://roster/<id>/shift/<hash>`) as a recovery key.
    public let url: URL?
    /// Reminders, in minutes before start (e.g. [60], [720] for night-before).
    public let alarmOffsetsMinutes: [Int]
    /// Hash of the event's content so re-import can tell "changed" from "same".
    public let contentHash: String

    public init(
        dedupKey: String,
        title: String,
        location: String? = nil,
        notes: String? = nil,
        start: Date,
        end: Date,
        timeZoneIdentifier: String,
        isAllDay: Bool = false,
        url: URL? = nil,
        alarmOffsetsMinutes: [Int] = [],
        contentHash: String
    ) {
        self.dedupKey = dedupKey
        self.title = title
        self.location = location
        self.notes = notes
        self.start = start
        self.end = end
        self.timeZoneIdentifier = timeZoneIdentifier
        self.isAllDay = isAllDay
        self.url = url
        self.alarmOffsetsMinutes = alarmOffsetsMinutes
        self.contentHash = contentHash
    }
}

public enum CalendarWriteAction: String, Sendable {
    case added, updated, unchanged, removed, failed
}

public struct CalendarWriteResult: Sendable {
    public let dedupKey: String
    public let action: CalendarWriteAction
    public let eventIdentifier: String?
    public let message: String?

    public init(dedupKey: String, action: CalendarWriteAction, eventIdentifier: String? = nil, message: String? = nil) {
        self.dedupKey = dedupKey
        self.action = action
        self.eventIdentifier = eventIdentifier
        self.message = message
    }
}

/// A destination Helm can write shifts to (Apple Calendar via EventKit, an .ics
/// file, or Google directly). Implementations must be idempotent on `dedupKey`.
public protocol CalendarTarget: Sendable {
    /// Stable identifier for the target kind ("eventkit" / "ics" / "google").
    var kind: String { get }

    /// Upsert the given drafts, returning what happened to each.
    func write(_ drafts: [CalendarEventDraft]) async throws -> [CalendarWriteResult]

    /// Remove previously-written events by their dedup keys (re-import removals).
    /// Returns the number actually removed.
    @discardableResult
    func remove(dedupKeys: [String]) async throws -> Int

    /// Remove every event Helm created in this target.
    @discardableResult
    func removeAll() async throws -> Int
}
