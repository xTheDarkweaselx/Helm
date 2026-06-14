//
//  HelmDataExport.swift
//  HelmDomain
//
//  v8.2 ship-ready: a portable, human-readable JSON snapshot of EVERYTHING the
//  user has in Helm — shift types, imported rosters + their shifts, built
//  schedules, time-off, availability and preferences. Pure value types so the
//  document is unit-tested; the app maps SwiftData into these DTOs. Used for
//  GDPR data portability ("export my data") — nothing here leaves the device
//  except when the user saves the file themselves.
//

import Foundation

/// The whole export. `schemaVersion` lets a future importer evolve safely.
public struct HelmDataExport: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let exportedAt: Date
    public let app: String
    public var shiftTypes: [ExportedShiftType]
    public var rosters: [ExportedRoster]
    public var schedules: [ExportedSchedule]
    public var timeOff: [ExportedTimeOff]
    public var availabilityRules: [ExportedAvailabilityRule]
    public var availabilityWindows: [ExportedAvailabilityWindow]
    public var settings: ExportedSettings

    public init(exportedAt: Date, app: String,
                shiftTypes: [ExportedShiftType] = [], rosters: [ExportedRoster] = [],
                schedules: [ExportedSchedule] = [], timeOff: [ExportedTimeOff] = [],
                availabilityRules: [ExportedAvailabilityRule] = [],
                availabilityWindows: [ExportedAvailabilityWindow] = [],
                settings: ExportedSettings = ExportedSettings()) {
        self.schemaVersion = Self.currentSchemaVersion
        self.exportedAt = exportedAt
        self.app = app
        self.shiftTypes = shiftTypes
        self.rosters = rosters
        self.schedules = schedules
        self.timeOff = timeOff
        self.availabilityRules = availabilityRules
        self.availabilityWindows = availabilityWindows
        self.settings = settings
    }

    /// Pretty, stable JSON — sorted keys + ISO-8601 dates so two exports of the
    /// same data are byte-identical and the file reads cleanly in any editor.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // ISO-8601 WITH fractional seconds: the plain .iso8601 strategy truncates
        // to whole seconds, so real (sub-second) timestamps wouldn't round-trip.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.iso8601String(date))
        }
        return try encoder.encode(self)
    }

    public func jsonString() throws -> String {
        String(decoding: try jsonData(), as: UTF8.self)
    }

    /// Decode a previously-exported document (matches `jsonData()`'s date format).
    public static func decode(from data: Data) throws -> HelmDataExport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            guard let date = iso8601Date(string) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "Not an ISO-8601 date: \(string)"))
            }
            return date
        }
        return try decoder.decode(HelmDataExport.self, from: data)
    }

    // Fresh formatters (ISO8601DateFormatter isn't Sendable) — fine for a one-shot
    // export; the per-date allocation is negligible.
    private static func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    private static func iso8601Date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    /// A one-line summary of how much data the export holds (for the UI).
    public var itemSummary: String {
        let shifts = rosters.reduce(0) { $0 + $1.shifts.count }
        var parts: [String] = []
        if !rosters.isEmpty { parts.append("\(rosters.count) roster\(rosters.count == 1 ? "" : "s") (\(shifts) shift\(shifts == 1 ? "" : "s"))") }
        if !schedules.isEmpty { parts.append("\(schedules.count) schedule\(schedules.count == 1 ? "" : "s")") }
        if !shiftTypes.isEmpty { parts.append("\(shiftTypes.count) shift type\(shiftTypes.count == 1 ? "" : "s")") }
        if !timeOff.isEmpty { parts.append("\(timeOff.count) time-off entr\(timeOff.count == 1 ? "y" : "ies")") }
        return parts.isEmpty ? "No data yet" : parts.joined(separator: " · ")
    }
}

public struct ExportedShiftType: Codable, Sendable, Equatable {
    public let code: String?
    public let label: String?
    public let startMinuteOfDay: Int
    public let endMinuteOfDay: Int
    public let endDayOffset: Int
    public let breakMinutes: Int
    public let paid: Bool
    public let paidHoursOverride: Double?
    public let workKind: String
    public let colorHex: String?
    public let location: String?
    public let tags: [String]

    public init(code: String?, label: String?, startMinuteOfDay: Int, endMinuteOfDay: Int, endDayOffset: Int, breakMinutes: Int, paid: Bool, paidHoursOverride: Double?, workKind: String, colorHex: String?, location: String?, tags: [String]) {
        self.code = code; self.label = label
        self.startMinuteOfDay = startMinuteOfDay; self.endMinuteOfDay = endMinuteOfDay
        self.endDayOffset = endDayOffset; self.breakMinutes = breakMinutes
        self.paid = paid; self.paidHoursOverride = paidHoursOverride; self.workKind = workKind
        self.colorHex = colorHex; self.location = location; self.tags = tags
    }
}

public struct ExportedShift: Codable, Sendable, Equatable {
    public let date: Date?
    public let start: Date?
    public let end: Date?
    public let isAllDay: Bool
    public let timeZone: String
    public let paidHours: Double?
    public let shiftCode: String?
    public let title: String?
    public let location: String?
    public let note: String?

    public init(date: Date?, start: Date?, end: Date?, isAllDay: Bool, timeZone: String, paidHours: Double?, shiftCode: String?, title: String?, location: String?, note: String?) {
        self.date = date; self.start = start; self.end = end
        self.isAllDay = isAllDay; self.timeZone = timeZone; self.paidHours = paidHours
        self.shiftCode = shiftCode; self.title = title; self.location = location; self.note = note
    }
}

public struct ExportedRoster: Codable, Sendable, Equatable {
    public let title: String?
    public let createdAt: Date
    public let reminderOffsetsMinutes: [Int]?
    public let shifts: [ExportedShift]

    public init(title: String?, createdAt: Date, reminderOffsetsMinutes: [Int]?, shifts: [ExportedShift]) {
        self.title = title; self.createdAt = createdAt
        self.reminderOffsetsMinutes = reminderOffsetsMinutes; self.shifts = shifts
    }
}

public struct ExportedSlot: Codable, Sendable, Equatable {
    public let position: Int
    public let isOff: Bool
    public let shiftCode: String?
    public let location: String?
    public init(position: Int, isOff: Bool, shiftCode: String?, location: String?) {
        self.position = position; self.isOff = isOff; self.shiftCode = shiftCode; self.location = location
    }
}

public struct ExportedExplicitDay: Codable, Sendable, Equatable {
    public let date: Date?
    public let isOff: Bool
    public let shiftCode: String?
    public let title: String?
    public let location: String?
    public init(date: Date?, isOff: Bool, shiftCode: String?, title: String?, location: String?) {
        self.date = date; self.isOff = isOff; self.shiftCode = shiftCode; self.title = title; self.location = location
    }
}

public struct ExportedScheduleSegment: Codable, Sendable, Equatable {
    public let title: String?
    public let kind: String
    public let effectiveFrom: Date?
    public let effectiveTo: Date?
    public let anchorDate: Date?
    public let patternName: String?
    public let cycleLengthDays: Int?
    public let slots: [ExportedSlot]
    public let explicitDays: [ExportedExplicitDay]

    public init(title: String?, kind: String, effectiveFrom: Date?, effectiveTo: Date?, anchorDate: Date?, patternName: String?, cycleLengthDays: Int?, slots: [ExportedSlot], explicitDays: [ExportedExplicitDay]) {
        self.title = title; self.kind = kind
        self.effectiveFrom = effectiveFrom; self.effectiveTo = effectiveTo; self.anchorDate = anchorDate
        self.patternName = patternName; self.cycleLengthDays = cycleLengthDays
        self.slots = slots; self.explicitDays = explicitDays
    }
}

public struct ExportedScheduleException: Codable, Sendable, Equatable {
    public let date: Date?
    public let kind: String
    public let shiftCode: String?
    public let title: String?
    public init(date: Date?, kind: String, shiftCode: String?, title: String?) {
        self.date = date; self.kind = kind; self.shiftCode = shiftCode; self.title = title
    }
}

public struct ExportedSchedule: Codable, Sendable, Equatable {
    public let title: String?
    public let createdAt: Date
    public let notes: String?
    public let horizonStart: Date?
    public let horizonEnd: Date?
    public let segments: [ExportedScheduleSegment]
    public let exceptions: [ExportedScheduleException]

    public init(title: String?, createdAt: Date, notes: String?, horizonStart: Date?, horizonEnd: Date?, segments: [ExportedScheduleSegment], exceptions: [ExportedScheduleException]) {
        self.title = title; self.createdAt = createdAt; self.notes = notes
        self.horizonStart = horizonStart; self.horizonEnd = horizonEnd
        self.segments = segments; self.exceptions = exceptions
    }
}

public struct ExportedTimeOff: Codable, Sendable, Equatable {
    public let startDate: Date?
    public let endDate: Date?
    public let kind: String
    public let paid: Bool
    public let hoursPerDay: Double?
    public let title: String?
    public let note: String?

    public init(startDate: Date?, endDate: Date?, kind: String, paid: Bool, hoursPerDay: Double?, title: String?, note: String?) {
        self.startDate = startDate; self.endDate = endDate; self.kind = kind
        self.paid = paid; self.hoursPerDay = hoursPerDay; self.title = title; self.note = note
    }
}

public struct ExportedAvailabilityRule: Codable, Sendable, Equatable {
    public let kind: String
    public let weekdays: [Int]
    public let startMinuteOfDay: Int
    public let endMinuteOfDay: Int
    public let effectiveFrom: Date?
    public let effectiveTo: Date?
    public let note: String?

    public init(kind: String, weekdays: [Int], startMinuteOfDay: Int, endMinuteOfDay: Int, effectiveFrom: Date?, effectiveTo: Date?, note: String?) {
        self.kind = kind; self.weekdays = weekdays
        self.startMinuteOfDay = startMinuteOfDay; self.endMinuteOfDay = endMinuteOfDay
        self.effectiveFrom = effectiveFrom; self.effectiveTo = effectiveTo; self.note = note
    }
}

public struct ExportedAvailabilityWindow: Codable, Sendable, Equatable {
    public let date: Date?
    public let kind: String
    public let startMinuteOfDay: Int
    public let endMinuteOfDay: Int
    public let allDay: Bool
    public let note: String?

    public init(date: Date?, kind: String, startMinuteOfDay: Int, endMinuteOfDay: Int, allDay: Bool, note: String?) {
        self.date = date; self.kind = kind
        self.startMinuteOfDay = startMinuteOfDay; self.endMinuteOfDay = endMinuteOfDay
        self.allDay = allDay; self.note = note
    }
}

public struct ExportedSettings: Codable, Sendable, Equatable {
    public var hourlyRate: Double?
    public var overtimeEnabled: Bool?
    public var overtimeThresholdHours: Double?
    public var overtimeMultiplier: Double?
    public var taxYearPreset: String?
    public var themeID: String?
    public var reminderOffsetsMinutes: [Int]?
    public var calendarDestinations: [String]?

    public init(hourlyRate: Double? = nil, overtimeEnabled: Bool? = nil, overtimeThresholdHours: Double? = nil, overtimeMultiplier: Double? = nil, taxYearPreset: String? = nil, themeID: String? = nil, reminderOffsetsMinutes: [Int]? = nil, calendarDestinations: [String]? = nil) {
        self.hourlyRate = hourlyRate; self.overtimeEnabled = overtimeEnabled
        self.overtimeThresholdHours = overtimeThresholdHours; self.overtimeMultiplier = overtimeMultiplier
        self.taxYearPreset = taxYearPreset; self.themeID = themeID
        self.reminderOffsetsMinutes = reminderOffsetsMinutes; self.calendarDestinations = calendarDestinations
    }
}
