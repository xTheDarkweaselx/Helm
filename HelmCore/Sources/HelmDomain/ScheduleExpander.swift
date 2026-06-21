//
//  ScheduleExpander.swift
//  HelmDomain
//
//  Pure, deterministic expansion of a built rota (timeline of cyclic / explicit
//  segments + per-date exceptions) into dated shifts over a bounded horizon.
//  Operates only on Sendable value snapshots (never @Model), so it runs off-main
//  and is unit-testable. Output feeds the SAME draft → diff → sync → reminders →
//  .ics path as imports; generated dedup keys are namespaced (ShiftKey) so they
//  can never collide with imported events.
//
//  Precedence per day: exception > governing segment (highest sortIndex) > gap.
//

import Foundation

// MARK: - Value specs (snapshot of the @Model graph)

public struct ShiftTypeSpec: Sendable, Equatable {
    public let id: String
    public let code: String?
    public let label: String?
    public let startMinuteOfDay: Int
    public let endMinuteOfDay: Int
    public let endDayOffset: Int
    public let breakMinutes: Int
    public let workKindRaw: String     // "worked" | "onCall" | "standby" | "off" | "leave"
    public let locationName: String?

    public init(id: String, code: String?, label: String?, startMinuteOfDay: Int, endMinuteOfDay: Int,
                endDayOffset: Int = 0, breakMinutes: Int = 0, workKindRaw: String = "worked", locationName: String? = nil) {
        self.id = id; self.code = code; self.label = label
        self.startMinuteOfDay = startMinuteOfDay; self.endMinuteOfDay = endMinuteOfDay
        self.endDayOffset = endDayOffset; self.breakMinutes = breakMinutes
        self.workKindRaw = workKindRaw; self.locationName = locationName
    }
}

public struct SlotSpec: Sendable, Equatable {
    public let sortIndex: Int
    public let isOff: Bool
    public let shiftType: ShiftTypeSpec?
    public let locationName: String?
    public init(sortIndex: Int, isOff: Bool = false, shiftType: ShiftTypeSpec? = nil, locationName: String? = nil) {
        self.sortIndex = sortIndex; self.isOff = isOff; self.shiftType = shiftType; self.locationName = locationName
    }
}

public struct ExplicitDaySpec: Sendable, Equatable {
    public let localDate: Date
    public let isOff: Bool
    public let shiftType: ShiftTypeSpec?
    public let inlineStartMinute: Int?
    public let inlineEndMinute: Int?
    public let title: String?
    public let locationName: String?
    public init(localDate: Date, isOff: Bool = false, shiftType: ShiftTypeSpec? = nil,
                inlineStartMinute: Int? = nil, inlineEndMinute: Int? = nil, title: String? = nil, locationName: String? = nil) {
        self.localDate = localDate; self.isOff = isOff; self.shiftType = shiftType
        self.inlineStartMinute = inlineStartMinute; self.inlineEndMinute = inlineEndMinute
        self.title = title; self.locationName = locationName
    }
}

public struct SegmentSpec: Sendable, Equatable {
    public let sortIndex: Int
    public let isExplicit: Bool
    public let effectiveFrom: Date?
    public let effectiveTo: Date?
    public let timeZoneIdentifier: String?
    public let locationName: String?
    public let anchorDate: Date?
    public let dayOffset: Int
    public let cycleLengthDays: Int
    public let slots: [SlotSpec]
    public let explicitDays: [ExplicitDaySpec]
    public init(sortIndex: Int, isExplicit: Bool, effectiveFrom: Date?, effectiveTo: Date?,
                timeZoneIdentifier: String? = nil, locationName: String? = nil, anchorDate: Date? = nil,
                dayOffset: Int = 0, cycleLengthDays: Int = 0, slots: [SlotSpec] = [], explicitDays: [ExplicitDaySpec] = []) {
        self.sortIndex = sortIndex; self.isExplicit = isExplicit
        self.effectiveFrom = effectiveFrom; self.effectiveTo = effectiveTo
        self.timeZoneIdentifier = timeZoneIdentifier; self.locationName = locationName
        self.anchorDate = anchorDate; self.dayOffset = dayOffset; self.cycleLengthDays = cycleLengthDays
        self.slots = slots; self.explicitDays = explicitDays
    }
}

public struct ExceptionSpec: Sendable, Equatable {
    public let localDate: Date
    public let kindRaw: String          // OverrideKind: modified|cancelled|added|swapped
    public let shiftType: ShiftTypeSpec?
    public let inlineStartMinute: Int?
    public let inlineEndMinute: Int?
    public let title: String?
    public let locationName: String?
    public init(localDate: Date, kindRaw: String, shiftType: ShiftTypeSpec? = nil,
                inlineStartMinute: Int? = nil, inlineEndMinute: Int? = nil, title: String? = nil, locationName: String? = nil) {
        self.localDate = localDate; self.kindRaw = kindRaw; self.shiftType = shiftType
        self.inlineStartMinute = inlineStartMinute; self.inlineEndMinute = inlineEndMinute
        self.title = title; self.locationName = locationName
    }
}

public struct ScheduleSpec: Sendable, Equatable {
    public let scope: String            // schedule id (namespaces generated keys)
    public let defaultTimeZoneIdentifier: String
    public let segments: [SegmentSpec]
    public let exceptions: [ExceptionSpec]
    public init(scope: String, defaultTimeZoneIdentifier: String, segments: [SegmentSpec], exceptions: [ExceptionSpec] = []) {
        self.scope = scope; self.defaultTimeZoneIdentifier = defaultTimeZoneIdentifier
        self.segments = segments; self.exceptions = exceptions
    }
}

// MARK: - Output

public struct ExpandedDay: Sendable, Equatable {
    public let localDate: Date
    public let timeZoneIdentifier: String
    public let code: String             // namespaced (g:<scope>:<code>)
    public let title: String?
    public let location: String?
    public let startMinuteOfDay: Int?
    public let endMinuteOfDay: Int?
    public let start: Date?
    public let end: Date?
    public let paidHours: Double?
    public let shiftTypeID: String?
    public let isWritable: Bool         // false = OFF (preview-only; produces a "removed" in the diff)

    public var dedupKey: String { ShiftKey.make(localDate: localDate, timeZoneIdentifier: timeZoneIdentifier, code: code) }
}

public enum ScheduleExpander {

    public static func expand(_ spec: ScheduleSpec, horizon: ClosedRange<Date>) -> [ExpandedDay] {
        let defaultTZ = TimeZone(identifier: spec.defaultTimeZoneIdentifier) ?? .gmt
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = defaultTZ

        let byPriority = spec.segments.sorted { $0.sortIndex > $1.sortIndex } // highest first
        var exceptionsByDay: [String: ExceptionSpec] = [:]
        for ex in spec.exceptions {
            exceptionsByDay[dayKey(ex.localDate, defaultTZ)] = ex // last-wins
        }

        var out: [ExpandedDay] = []
        var day = cal.startOfDay(for: horizon.lowerBound)
        let last = cal.startOfDay(for: horizon.upperBound)
        while day <= last {
            if let resolved = resolveDay(day, spec: spec, byPriority: byPriority, exceptions: exceptionsByDay, defaultTZ: defaultTZ) {
                out.append(resolved)
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out
    }

    // MARK: - Resolution

    private static func resolveDay(_ day: Date, spec: ScheduleSpec, byPriority: [SegmentSpec],
                                   exceptions: [String: ExceptionSpec], defaultTZ: TimeZone) -> ExpandedDay? {
        // 1. Exception wins — but only when it actually resolves to something.
        if let ex = exceptions[dayKey(day, defaultTZ)] {
            if ex.kindRaw == OverrideKindRaw.cancelled { return offDay(day, tz: spec.defaultTimeZoneIdentifier, scope: spec.scope) }
            if let resolved = fromSource(day, tz: spec.defaultTimeZoneIdentifier, scope: spec.scope,
                                         shiftType: ex.shiftType, inlineStart: ex.inlineStartMinute, inlineEnd: ex.inlineEndMinute,
                                         title: ex.title, location: ex.locationName) {
                return resolved
            }
            // An incomplete exception (no shift / no times) is NOT authoritative —
            // fall through to the segments rather than forcing the day OFF.
        }

        // 2. Governing segment, highest sortIndex first. EXPLICIT segments are sparse
        //    OVERLAYS: a day with no matching entry falls through to lower-priority
        //    segments (so an explicit overlay doesn't blank an underlying cycle).
        //    CYCLIC segments govern every day in their window.
        for seg in byPriority where windowContains(seg, day, defaultTZ) {
            let tz = seg.timeZoneIdentifier ?? spec.defaultTimeZoneIdentifier
            if seg.isExplicit {
                guard let ed = seg.explicitDays.first(where: { sameDay($0.localDate, day, TimeZone(identifier: tz) ?? defaultTZ) }) else {
                    continue // overlay miss → try the next (lower-priority) segment
                }
                if ed.isOff { return offDay(day, tz: tz, scope: spec.scope) }
                return fromSource(day, tz: tz, scope: spec.scope, shiftType: ed.shiftType,
                                  inlineStart: ed.inlineStartMinute, inlineEnd: ed.inlineEndMinute,
                                  title: ed.title, location: ed.locationName)
                    ?? offDay(day, tz: tz, scope: spec.scope)
            } else {
                guard let anchor = seg.anchorDate, seg.cycleLengthDays > 0 else { continue }
                let pos = cyclePosition(anchor: anchor, day: day, dayOffset: seg.dayOffset,
                                        cycleLength: seg.cycleLengthDays, tz: TimeZone(identifier: tz) ?? defaultTZ)
                guard let slot = seg.slots.first(where: { $0.sortIndex == pos }) else {
                    return offDay(day, tz: tz, scope: spec.scope) // unfilled position → OFF
                }
                if slot.isOff || slot.shiftType == nil { return offDay(day, tz: tz, scope: spec.scope) }
                return fromType(day, tz: tz, scope: spec.scope, type: slot.shiftType!,
                                location: slot.locationName ?? seg.locationName)
            }
        }
        return nil // gap
    }

    private static func fromSource(_ day: Date, tz: String, scope: String, shiftType: ShiftTypeSpec?,
                                   inlineStart: Int?, inlineEnd: Int?, title: String?, location: String?) -> ExpandedDay? {
        if let type = shiftType { return fromType(day, tz: tz, scope: scope, type: type, location: location ?? type.locationName, titleOverride: title) }
        if let s = inlineStart, let e = inlineEnd {
            let resolved = ShiftTimeResolver.resolve(localDay: day, startMinuteOfDay: s, endMinuteOfDay: e, timeZone: TimeZone(identifier: tz) ?? .gmt)
            let code = ShiftKey.generatedCode(scope: scope, code: "inline:\(s)-\(e)")
            return ExpandedDay(localDate: day, timeZoneIdentifier: tz, code: code,
                               title: title ?? "\(hhmm(s))–\(hhmm(e))", location: location,
                               startMinuteOfDay: s, endMinuteOfDay: e,
                               start: resolved?.start, end: resolved?.end,
                               paidHours: resolved?.paidHours(breakMinutes: 0), shiftTypeID: nil,
                               isWritable: resolved != nil)
        }
        return nil
    }

    private static func fromType(_ day: Date, tz: String, scope: String, type: ShiftTypeSpec,
                                 location: String?, titleOverride: String? = nil) -> ExpandedDay {
        if type.workKindRaw == "off" { return offDay(day, tz: tz, scope: scope) }
        let code = ShiftKey.generatedCode(scope: scope, code: (type.code ?? "shift").uppercased())
        let resolved = ShiftTimeResolver.resolve(localDay: day, startMinuteOfDay: type.startMinuteOfDay,
                                                 endMinuteOfDay: type.endMinuteOfDay, endDayOffset: type.endDayOffset,
                                                 timeZone: TimeZone(identifier: tz) ?? .gmt)
        return ExpandedDay(localDate: day, timeZoneIdentifier: tz, code: code,
                           title: titleOverride ?? type.label ?? type.code ?? "Shift",
                           location: location,
                           startMinuteOfDay: type.startMinuteOfDay, endMinuteOfDay: type.endMinuteOfDay,
                           start: resolved?.start, end: resolved?.end,
                           paidHours: resolved?.paidHours(breakMinutes: type.breakMinutes),
                           shiftTypeID: type.id, isWritable: resolved != nil)
    }

    private static func offDay(_ day: Date, tz: String, scope: String) -> ExpandedDay {
        ExpandedDay(localDate: day, timeZoneIdentifier: tz, code: ShiftKey.generatedCode(scope: scope, code: "OFF"),
                    title: "Off", location: nil, startMinuteOfDay: nil, endMinuteOfDay: nil,
                    start: nil, end: nil, paidHours: nil, shiftTypeID: nil, isWritable: false)
    }

    // MARK: - Date helpers (all DST-safe via Calendar)

    private static func windowContains(_ seg: SegmentSpec, _ day: Date, _ tz: TimeZone) -> Bool {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        if let from = seg.effectiveFrom, day < cal.startOfDay(for: from) { return false }
        if let to = seg.effectiveTo, day > cal.startOfDay(for: to) { return false }
        return true
    }

    static func cyclePosition(anchor: Date, day: Date, dayOffset: Int, cycleLength: Int, tz: TimeZone) -> Int {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let diff = cal.dateComponents([.day], from: cal.startOfDay(for: anchor), to: cal.startOfDay(for: day)).day ?? 0
        let n = max(cycleLength, 1)
        return (((diff + dayOffset) % n) + n) % n
    }

    private static func sameDay(_ a: Date, _ b: Date, _ tz: TimeZone) -> Bool {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        return cal.isDate(a, inSameDayAs: b)
    }

    private static func dayKey(_ date: Date, _ tz: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func hhmm(_ minute: Int) -> String {
        let m = ((minute % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    private enum OverrideKindRaw { static let cancelled = "cancelled" }
}
