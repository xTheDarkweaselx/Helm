//
//  ShiftLegend.swift
//  HelmDomain
//
//  v6 Import Intelligence: the code → meaning legend becomes a THREE-TIER
//  merged table — built-in defaults < the user's global ShiftTypes (by code)
//  < per-source learned mappings (explicit user intent, always wins). Pure
//  value types: the app snapshots SwiftData into these on the main actor and
//  the merge itself is headlessly tested.
//

import Foundation

/// What a legend lookup says a code means.
public enum LegendResolution: Sendable, Equatable {
    /// A timed shift with resolved wall-clock minutes (end may exceed 1440 for
    /// overnight — ShiftTimeResolver accepts that directly).
    case timed(ShiftLegendEntry)
    /// An all-day event (leave, sickness, study…): visible, no times.
    case allDay(label: String?)
    /// The user said this code means nothing — skip it VISIBLY (.skippedByRule).
    case ignore
}

public struct ShiftLegendEntry: Sendable, Equatable {
    public let code: String
    public let label: String?
    public let startMinute: Int
    /// EFFECTIVE end: endMinuteOfDay + 1440 × endDayOffset already applied.
    public let endMinute: Int
    public let breakMinutes: Int
    /// When the entry comes from a real ShiftType, its id — the sync engine's
    /// id-first lookup then reuses the exact type (colors/paid semantics free).
    public let shiftTypeID: String?

    public init(code: String, label: String?, startMinute: Int, endMinute: Int, breakMinutes: Int = 0, shiftTypeID: String? = nil) {
        self.code = code
        self.label = label
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.breakMinutes = breakMinutes
        self.shiftTypeID = shiftTypeID
    }
}

/// The merged lookup table.
public struct MergedLegend: Sendable {
    let table: [String: LegendResolution]

    public func resolution(for normalizedCode: String) -> LegendResolution? {
        table[normalizedCode]
    }

    public var codes: Set<String> { Set(table.keys) }
}

public enum LegendMerger {
    /// Built-in defaults for the first real roster (user-supplied times).
    public static let builtin: [ShiftLegendEntry] = [
        ShiftLegendEntry(code: "M", label: "Morning", startMinute: 6 * 60 + 30, endMinute: 13 * 60 + 30),
        ShiftLegendEntry(code: "A", label: "Afternoon", startMinute: 13 * 60 + 30, endMinute: 22 * 60),
        ShiftLegendEntry(code: "M/A", label: "Morning + Afternoon", startMinute: 6 * 60 + 30, endMinute: 22 * 60),
    ]

    /// Snapshot of a global ShiftType that carries a code.
    public struct GlobalType: Sendable, Equatable {
        public let code: String
        public let label: String?
        public let startMinuteOfDay: Int
        public let endMinuteOfDay: Int
        public let endDayOffset: Int
        public let breakMinutes: Int
        public let shiftTypeID: String

        public init(code: String, label: String?, startMinuteOfDay: Int, endMinuteOfDay: Int, endDayOffset: Int, breakMinutes: Int, shiftTypeID: String) {
            self.code = code
            self.label = label
            self.startMinuteOfDay = startMinuteOfDay
            self.endMinuteOfDay = endMinuteOfDay
            self.endDayOffset = endDayOffset
            self.breakMinutes = breakMinutes
            self.shiftTypeID = shiftTypeID
        }

        var effectiveEndMinute: Int { endMinuteOfDay + 1440 * max(0, endDayOffset) }
    }

    /// Snapshot of a learned per-source ShiftCodeMapping (times already
    /// resolved from its linked ShiftType by the app-side builder).
    public struct Learned: Sendable, Equatable {
        public enum Action: String, Sendable { case timed, allDay, ignore }

        public let code: String
        public let action: Action
        public let label: String?
        public let startMinute: Int?
        /// Effective (offset applied) — nil for allDay/ignore or a dangling type.
        public let endMinute: Int?
        public let breakMinutes: Int
        public let shiftTypeID: String?
        public let lastUsedAt: Date?
        public let id: String

        public init(code: String, action: Action, label: String? = nil, startMinute: Int? = nil, endMinute: Int? = nil, breakMinutes: Int = 0, shiftTypeID: String? = nil, lastUsedAt: Date? = nil, id: String) {
            self.code = code
            self.action = action
            self.label = label
            self.startMinute = startMinute
            self.endMinute = endMinute
            self.breakMinutes = breakMinutes
            self.shiftTypeID = shiftTypeID
            self.lastUsedAt = lastUsedAt
            self.id = id
        }
    }

    public static func merge(
        builtin: [ShiftLegendEntry] = builtin,
        globalTypes: [GlobalType],
        learned: [Learned]
    ) -> MergedLegend {
        var table: [String: LegendResolution] = [:]

        // Tier 1: built-ins.
        for entry in builtin {
            table[entry.code] = .timed(entry)
        }

        // Tier 2: global ShiftTypes by code — filtered. Sentinel codes (OFF/TBC
        // vocab) never enter via the library (a stray type coded "X" must not
        // convert every off-day); degenerate times excluded; ambiguous codes
        // (two types, different meaning) drop out so the review panel surfaces
        // them instead of guessing.
        var byCode: [String: [GlobalType]] = [:]
        for type in globalTypes {
            let code = type.code.trimmingCharacters(in: .whitespaces).uppercased()
            guard !code.isEmpty,
                  !ShiftCodeNormalizer.isOff(code),
                  !ShiftCodeNormalizer.isTentative(code),
                  type.effectiveEndMinute > type.startMinuteOfDay
            else { continue }
            byCode[code, default: []].append(type)
        }
        for (code, candidates) in byCode {
            let distinct = Set(candidates.map { "\($0.startMinuteOfDay)|\($0.effectiveEndMinute)|\($0.label ?? "")" })
            guard distinct.count == 1, let type = candidates.sorted(by: { $0.shiftTypeID < $1.shiftTypeID }).first else {
                continue // ambiguous → not auto-learned
            }
            // Built-in preservation: a library type matching a built-in code
            // with the same minutes and no competing label keeps the built-in
            // entry byte-identical (no title/hash churn on existing events).
            if let builtinEntry = builtin.first(where: { $0.code == code }),
               builtinEntry.startMinute == type.startMinuteOfDay,
               builtinEntry.endMinute == type.effectiveEndMinute,
               type.label == nil || type.label == builtinEntry.label {
                table[code] = .timed(ShiftLegendEntry(
                    code: code,
                    label: builtinEntry.label,
                    startMinute: builtinEntry.startMinute,
                    endMinute: builtinEntry.endMinute,
                    breakMinutes: type.breakMinutes,
                    shiftTypeID: type.shiftTypeID
                ))
            } else {
                table[code] = .timed(ShiftLegendEntry(
                    code: code,
                    label: type.label,
                    startMinute: type.startMinuteOfDay,
                    endMinute: type.effectiveEndMinute,
                    breakMinutes: type.breakMinutes,
                    shiftTypeID: type.shiftTypeID
                ))
            }
        }

        // Tier 3: learned mappings — explicit user intent, always wins.
        // CloudKit can duplicate rows (no unique constraints): dedupe
        // deterministically (latest lastUsedAt, then lowest id).
        var learnedByCode: [String: Learned] = [:]
        for mapping in learned {
            let code = mapping.code.trimmingCharacters(in: .whitespaces).uppercased()
            guard !code.isEmpty else { continue }
            if let existing = learnedByCode[code] {
                let lhs = (mapping.lastUsedAt ?? .distantPast, existing.id)
                let rhs = (existing.lastUsedAt ?? .distantPast, mapping.id)
                if lhs.0 > rhs.0 || (lhs.0 == rhs.0 && mapping.id < existing.id) {
                    learnedByCode[code] = mapping
                }
            } else {
                learnedByCode[code] = mapping
            }
        }
        for (code, mapping) in learnedByCode {
            switch mapping.action {
            case .ignore:
                table[code] = .ignore
            case .allDay:
                table[code] = .allDay(label: mapping.label)
            case .timed:
                // A dangling mapping (type deleted) contributes nothing —
                // falls through to whatever lower tier resolved.
                guard let start = mapping.startMinute, let end = mapping.endMinute, end > start else { continue }
                table[code] = .timed(ShiftLegendEntry(
                    code: code,
                    label: mapping.label,
                    startMinute: start,
                    endMinute: end,
                    breakMinutes: mapping.breakMinutes,
                    shiftTypeID: mapping.shiftTypeID
                ))
            }
        }

        return MergedLegend(table: table)
    }
}

/// "M/A"-style composite codes: split + a confirm-first spanning suggestion
/// (never auto-applied — learn, don't guess).
public enum CompositeShiftCode {
    public static func split(_ normalizedCode: String) -> [String] {
        let parts = normalizedCode
            .split(whereSeparator: { "/+&".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.count >= 2 ? parts : []
    }

    /// When EVERY part resolves to a timed entry: the spanning range
    /// (min start … max effective end) to prefill the review editor.
    public static func spanningSuggestion(parts: [ShiftLegendEntry]) -> (startMinute: Int, endMinute: Int)? {
        guard parts.count >= 2,
              let start = parts.map(\.startMinute).min(),
              let end = parts.map(\.endMinute).max(),
              end > start
        else { return nil }
        return (start, end)
    }
}

/// A prefill guess for an UNKNOWN code, surfaced in the review panel so the user
/// confirms one tap instead of typing a blind 09:00–17:00. Never auto-written.
public struct CodeSuggestion: Sendable, Equatable {
    public enum Confidence: String, Sendable, Equatable { case high, medium, low }
    public let startMinute: Int
    /// Effective end (may exceed 1440 for an overnight suggestion).
    public let endMinute: Int
    public let label: String?
    public let confidence: Confidence
    /// Short human reason ("Spans M + A", "Common ‘Night’ shift").
    public let reason: String

    public init(startMinute: Int, endMinute: Int, label: String?, confidence: Confidence, reason: String) {
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.label = label
        self.confidence = confidence
        self.reason = reason
    }
}

/// Guesses sensible times for an unknown code (composite span → common-UK
/// starter library → semantic hint → 9–5 fallback). PURE: the panel turns the
/// result into an editable prefill; nothing here is ever written without consent.
public enum UnknownCodeSuggester {
    private static func e(_ code: String, _ label: String, _ s: Int, _ end: Int) -> ShiftLegendEntry {
        ShiftLegendEntry(code: code, label: label, startMinute: s, endMinute: end)
    }
    private static let h = 60

    /// Common UK shift codes → typical hours. PREFILL ONLY — generic guesses
    /// must never silently override an employer's real legend.
    public static let starterLibrary: [String: ShiftLegendEntry] = [
        "E":     e("E", "Early",     6*h,        14*h),
        "ED":    e("ED", "Early day", 7*h,       15*h),
        "EARLY": e("EARLY", "Early", 6*h,        14*h),
        "L":     e("L", "Late",      14*h,       22*h),
        "LATE":  e("LATE", "Late",   14*h,       22*h),
        "LD":    e("LD", "Long day", 7*h,        19*h + 30),
        "D":     e("D", "Day",       9*h,        17*h),
        "DAY":   e("DAY", "Day",     9*h,        17*h),
        "N":     e("N", "Night",     22*h,       6*h + 1440), // overnight
        "NIGHT": e("NIGHT", "Night", 22*h,       6*h + 1440),
        "TWILIGHT": e("TWILIGHT", "Twilight", 17*h, 22*h),
        "TWI":   e("TWI", "Twilight", 17*h,      22*h),
    ]

    public static func suggest(for normalizedCode: String, legend: MergedLegend) -> CodeSuggestion {
        let code = normalizedCode

        // 1) Composite (M/A, E/L) where every part is known → the spanning range.
        // Only when the result is a PLAUSIBLE single block: no overnight part and
        // ≤16h, so an early+night ("E/N") doesn't yield a confident 24h shift.
        let parts = CompositeShiftCode.split(code)
        if parts.count >= 2 {
            let resolved: [ShiftLegendEntry] = parts.compactMap { part in
                if case let .timed(entry)? = legend.resolution(for: part) { return entry }
                return starterLibrary[part]
            }
            if resolved.count == parts.count,
               !resolved.contains(where: { $0.endMinute > 1440 }),
               let span = CompositeShiftCode.spanningSuggestion(parts: resolved),
               span.endMinute - span.startMinute <= 16 * h {
                return CodeSuggestion(startMinute: span.startMinute, endMinute: span.endMinute,
                                      label: parts.joined(separator: " + "),
                                      confidence: .high, reason: "Spans \(parts.joined(separator: " + "))")
            }
        }

        // 2) Common UK starter code (exact, then annotation-stripped).
        if let s = starterLibrary[code] ?? starterLibrary[ShiftCodeNormalizer.stripAnnotation(code)] {
            return CodeSuggestion(startMinute: s.startMinute, endMinute: s.endMinute, label: s.label,
                                  confidence: .medium, reason: "Common ‘\(s.label ?? code)’ shift")
        }

        // 3) Semantic hint from the code text.
        if let hint = semanticHint(code) { return hint }

        // 4) Fallback — a flagged guess the user is expected to correct.
        return CodeSuggestion(startMinute: 9*h, endMinute: 17*h, label: nil,
                              confidence: .low, reason: "Default 9–5 — please confirm")
    }

    /// Word-aware hints only — NOT single-letter prefixes, which mis-fired badly
    /// ("AM" → afternoon, "EXTRA" → early, "ANNUAL" → afternoon). A code with no
    /// recognisable word falls through to the flagged 9–5 default instead.
    private static func semanticHint(_ code: String) -> CodeSuggestion? {
        func has(_ needles: [String]) -> Bool { needles.contains { code.contains($0) } }
        func hint(_ s: Int, _ end: Int, _ label: String, _ why: String) -> CodeSuggestion {
            CodeSuggestion(startMinute: s, endMinute: end, label: label, confidence: .low, reason: why)
        }
        if has(["NIGHT", "NOCT"])                       { return hint(22*h, 6*h + 1440, "Night", "Looks like a night shift") }
        if has(["TWILIGHT", "EVENING"])                 { return hint(17*h, 22*h, "Twilight", "Looks like an evening shift") }
        if has(["LONG DAY", "LONGDAY"])                 { return hint(7*h, 19*h + 30, "Long day", "Looks like a long day") }
        if code == "AM" || has(["MORNING", "MORN"])     { return hint(6*h + 30, 13*h + 30, "Morning", "Looks like a morning shift") }
        if code == "PM" || has(["AFTERNOON", "AFTNOON"]) { return hint(13*h + 30, 22*h, "Afternoon", "Looks like an afternoon shift") }
        if has(["EARLY", "EARLIES"])                    { return hint(6*h, 14*h, "Early", "Looks like an early shift") }
        if has(["LATE", "LATES"])                       { return hint(14*h, 22*h, "Late", "Looks like a late shift") }
        return nil
    }
}

/// The always-visible import contract: per-outcome counts, never a silent drop.
public struct ImportHealth: Sendable, Equatable {
    public let written: Int
    public let allDay: Int
    public let off: Int
    public let byRule: Int
    public let unknown: Int
    public let unknownCodes: [String]

    public init(written: Int, allDay: Int, off: Int, byRule: Int, unknown: Int, unknownCodes: [String]) {
        self.written = written
        self.allDay = allDay
        self.off = off
        self.byRule = byRule
        self.unknown = unknown
        self.unknownCodes = unknownCodes
    }

    public var hasUnknown: Bool { unknown > 0 }

    /// "26 shifts · 2 all-day · 4 off · 1 unknown (L)"
    public var summary: String {
        var parts = ["\(written) shift\(written == 1 ? "" : "s")"]
        if allDay > 0 { parts.append("\(allDay) all-day") }
        if off > 0 { parts.append("\(off) off") }
        if byRule > 0 { parts.append("\(byRule) ignored by your rules") }
        if unknown > 0 {
            let codes = unknownCodes.isEmpty ? "" : " (\(unknownCodes.joined(separator: ", ")))"
            parts.append("\(unknown) unknown\(codes)")
        }
        return parts.joined(separator: " · ")
    }
}
