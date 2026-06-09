//
//  ParsedShift.swift
//  HelmDomain
//
//  The Sendable DTO that the parser produces and the import actor consumes
//  (ADR-9). Pure value type — safe to hand across actor boundaries.
//

import Foundation

/// One shift extracted from a source, before it becomes a persisted ShiftInstance.
public struct ParsedShift: Sendable, Equatable, Identifiable {
    public var id: String { dedupKeyInput }

    /// The calendar day (y/m/d meaningful; interpreted in `timeZoneIdentifier`).
    public let localDate: Date
    public let timeZoneIdentifier: String

    /// Normalized shift code from the source (e.g. "M"). May be empty for inline-time cells.
    public let normalizedCode: String
    /// Explicit inline times, if the cell carried them (e.g. "0900-1700").
    public let inlineTimes: InlineTimeRange?

    /// Enrichment pulled from sibling columns.
    public let title: String?
    public let location: String?

    /// Provenance for diagnostics and re-import diffing.
    public let sourceRow: Int?

    public init(
        localDate: Date,
        timeZoneIdentifier: String,
        normalizedCode: String,
        inlineTimes: InlineTimeRange? = nil,
        title: String? = nil,
        location: String? = nil,
        sourceRow: Int? = nil
    ) {
        self.localDate = localDate
        self.timeZoneIdentifier = timeZoneIdentifier
        self.normalizedCode = normalizedCode
        self.inlineTimes = inlineTimes
        self.title = title
        self.location = location
        self.sourceRow = sourceRow
    }

    /// Stable per-day identity used to build the dedup key (ADR-3). The import
    /// layer combines this with the import-profile and person identifiers and hashes it.
    /// The day is computed in the shift's own time zone (not UTC), so a shift just
    /// after local midnight keys to the correct calendar day.
    public var dedupKeyInput: String {
        // Inline-time shifts carry no code; key them by their times so two timed
        // entries on the same day don't collapse to one key (which would orphan a
        // calendar event on re-import). Times are stable across re-imports; the
        // source row is not, so it is deliberately NOT used here.
        let code = normalizedCode.isEmpty
            ? (inlineTimes.map { "\($0.startMinuteOfDay)-\($0.endMinuteOfDay)" } ?? "")
            : normalizedCode
        return ShiftKey.make(localDate: localDate, timeZoneIdentifier: timeZoneIdentifier, code: code)
    }
}
