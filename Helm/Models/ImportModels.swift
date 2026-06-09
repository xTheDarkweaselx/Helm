//
//  ImportModels.swift
//  Helm
//
//  Import "recipe" + the idempotency ledger that powers re-import diffs and undo.
//  CloudKit-safe like the rest of the schema (see DEVELOPMENT_PLAN.md §3).
//

import Foundation
import SwiftData

// MARK: - ImportProfile (employer/source recipe — enables one-tap re-import)

@Model
final class ImportProfile {
    var id: String = UUID().uuidString
    var name: String?

    /// Security-scoped bookmark to the original file (we also copy it into the
    /// app container). The original sandbox URL's scope expires, so this is how
    /// re-import replays without a new file pick (ADR-11).
    var sourceBookmark: Data?
    /// Stable fingerprint of the source so a republished "v2 of June" is
    /// recognised as a newer version of the same logical roster, not a new one.
    var sourceFingerprint: String?

    var sheetName: String?
    var layoutKindRaw: String?
    var headerRowIndex: Int?
    /// Encodes which row/column holds the dates, e.g. "column:A" or "row:1".
    var dateAxis: String?
    /// Confirmed date locale (e.g. "en_GB" → dd/MM/yyyy) to avoid M/D ambiguity.
    var dateLocaleID: String?
    /// 1 = Sunday ... 2 = Monday (Foundation convention) for matrix column mapping.
    var firstDayOfWeek: Int?
    /// How the user's own row/identity is located in the source.
    var meRowIdentity: String?
    var lastImportedAt: Date?
    /// Which calendar destination this profile's roster was last written to
    /// ("eventkit" / "google"), stamped at apply time, so delete/resync clean up
    /// the calendar the events actually live in. Optional for CloudKit; nil
    /// (pre-existing profiles) reads as .eventkit — correct, they predate Google.
    var calendarTargetRaw: String?

    var user: UserProfile?

    @Relationship(deleteRule: .cascade, inverse: \ShiftCodeMapping.importProfile)
    var codeMappings: [ShiftCodeMapping]?

    @Relationship(deleteRule: .cascade, inverse: \ImportRun.importProfile)
    var runs: [ImportRun]?

    var layoutKind: LayoutKind? {
        get { layoutKindRaw.flatMap(LayoutKind.init(rawValue:)) }
        set { layoutKindRaw = newValue?.rawValue }
    }

    var target: CalendarTargetKind {
        get { calendarTargetRaw.flatMap(CalendarTargetKind.init(rawValue:)) ?? .eventkit }
        set { calendarTargetRaw = newValue.rawValue }
    }

    init(id: String = UUID().uuidString, name: String? = nil, user: UserProfile? = nil) {
        self.id = id
        self.name = name
        self.user = user
    }
}

// MARK: - ShiftCodeMapping (remembered code -> template, per source)

@Model
final class ShiftCodeMapping {
    var id: String = UUID().uuidString
    /// Normalized raw code (uppercased/trimmed), e.g. "M".
    var rawCode: String?
    var shiftType: ShiftType?
    var confidenceLastConfirmed: Double?

    var importProfile: ImportProfile?

    init(id: String = UUID().uuidString, rawCode: String? = nil, shiftType: ShiftType? = nil, importProfile: ImportProfile? = nil) {
        self.id = id
        self.rawCode = rawCode
        self.shiftType = shiftType
        self.importProfile = importProfile
    }
}

// MARK: - ImportRun (one import; unit of undo)

@Model
final class ImportRun {
    var id: String = UUID().uuidString
    var ranAt: Date = Date.now
    var addedCount: Int = 0
    var changedCount: Int = 0
    var removedCount: Int = 0
    var skippedCount: Int = 0

    var importProfile: ImportProfile?

    @Relationship(deleteRule: .nullify, inverse: \CalendarSyncRecord.importRun)
    var syncRecords: [CalendarSyncRecord]?

    init(id: String = UUID().uuidString, importProfile: ImportProfile? = nil) {
        self.id = id
        self.ranAt = .now
        self.importProfile = importProfile
    }
}

// MARK: - CalendarSyncRecord (the idempotency ledger)

@Model
final class CalendarSyncRecord {
    var id: String = UUID().uuidString
    /// Matches `ShiftInstance.dedupKey`.
    var shiftKey: String?
    var targetRaw: String = CalendarTargetKind.eventkit.rawValue
    var calendarIdentifier: String?
    /// EventKit's local `eventIdentifier`.
    var eventIdentifier: String?
    /// Provider-side id (Google event id, or `calendarItemExternalIdentifier` fallback).
    var externalEventID: String?
    /// Hash of the event's content, so re-import can tell "changed" from "same".
    var contentHash: String?
    var statusRaw: String = SyncStatus.pending.rawValue

    var shiftInstance: ShiftInstance?
    var importRun: ImportRun?

    var target: CalendarTargetKind {
        get { CalendarTargetKind(rawValue: targetRaw) ?? .eventkit }
        set { targetRaw = newValue.rawValue }
    }
    var status: SyncStatus {
        get { SyncStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    init(
        id: String = UUID().uuidString,
        shiftKey: String? = nil,
        target: CalendarTargetKind = .eventkit,
        shiftInstance: ShiftInstance? = nil,
        importRun: ImportRun? = nil
    ) {
        self.id = id
        self.shiftKey = shiftKey
        self.targetRaw = target.rawValue
        self.shiftInstance = shiftInstance
        self.importRun = importRun
    }
}
