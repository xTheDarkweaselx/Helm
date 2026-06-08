//
//  RosterImporter.swift
//  Helm
//
//  v0 glue: CSV text → grid → detect columns → [ParsedShift] → resolved draft
//  shifts ready for preview and calendar write. Uses HelmParsing + HelmDomain.
//  The xlsx path (vendored CoreXLSX) replaces only the "text → grid" step in v1.0.
//

import Foundation
import HelmDomain
import HelmParsing

/// A code → wall-clock-times legend (employer-specific; the times for "M"/"A"
/// are not in the spreadsheet — the user supplies them, see Fixtures README).
struct ShiftLegend: Sendable {
    struct Entry: Sendable {
        var startMinute: Int
        var endMinute: Int
        var label: String
    }

    var entries: [String: Entry]

    func entry(for normalizedCode: String) -> Entry? { entries[normalizedCode] }

    /// Default legend for the first real roster (06:30–13:30 / 13:30–22:00).
    static let `default` = ShiftLegend(entries: [
        "M": Entry(startMinute: 6 * 60 + 30, endMinute: 13 * 60 + 30, label: "Morning"),
        "A": Entry(startMinute: 13 * 60 + 30, endMinute: 22 * 60, label: "Afternoon"),
        "M/A": Entry(startMinute: 6 * 60 + 30, endMinute: 22 * 60, label: "Morning + Afternoon"),
    ])
}

/// A resolved candidate shift, shown in the preview before writing.
struct DraftShift: Identifiable, Sendable {
    enum Outcome: Sendable, Equatable {
        case willWrite
        case skippedOff
        case skippedTentative
        case skippedUnmapped
    }

    let id = UUID()
    let localDate: Date
    let timeZoneIdentifier: String
    let code: String
    let label: String?
    let title: String?
    let location: String?
    let startMinuteOfDay: Int?
    let endMinuteOfDay: Int?
    let start: Date?
    let end: Date?
    let paidHours: Double?
    let dedupKey: String
    let sourceRow: Int?
    let outcome: Outcome

    var isWritable: Bool { outcome == .willWrite }
}

enum RosterImportError: LocalizedError {
    case couldNotReadFile
    case noColumnsDetected
    case noRows

    var errorDescription: String? {
        switch self {
        case .couldNotReadFile: "Helm couldn't read that file."
        case .noColumnsDetected: "Helm couldn't find a date column and a shift column in that file."
        case .noRows: "No shifts were found in that file."
        }
    }
}

struct RosterImportResult: Sendable {
    var drafts: [DraftShift]
    var sourceName: String
    var unmappedCodes: [String]

    var writableCount: Int { drafts.filter(\.isWritable).count }
}

enum RosterImporter {

    /// Parse CSV text into resolved draft shifts.
    static func importCSV(
        text: String,
        sourceName: String,
        legend: ShiftLegend = .default,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        dateOrder: RosterDateParser.Order = .dayFirst
    ) throws -> RosterImportResult {
        let grid = CSVParser.parse(text, sheetName: sourceName)
        guard let sheet = grid.sheets.first else { throw RosterImportError.couldNotReadFile }
        guard let mapping = ListLayoutDetector.detect(sheet: sheet) else { throw RosterImportError.noColumnsDetected }

        let parsed = ListLayoutInterpreter.interpret(
            sheet: sheet,
            mapping: mapping,
            timeZoneIdentifier: timeZoneIdentifier,
            dateOrder: dateOrder
        )
        guard !parsed.isEmpty else { throw RosterImportError.noRows }

        var drafts: [DraftShift] = []
        var unmapped = Set<String>()

        for shift in parsed {
            let tz = TimeZone(identifier: shift.timeZoneIdentifier) ?? .current

            // 1) Inline times in the cell (e.g. "0930-1500") take priority over the legend.
            if let inline = shift.inlineTimes {
                let resolved = ShiftTimeResolver.resolve(
                    localDay: shift.localDate,
                    startMinuteOfDay: inline.startMinuteOfDay,
                    endMinuteOfDay: inline.endMinuteOfDay,
                    timeZone: tz
                )
                drafts.append(draft(for: shift, label: nil, startMinute: inline.startMinuteOfDay, endMinute: inline.endMinuteOfDay, resolved: resolved, outcome: resolved == nil ? .skippedUnmapped : .willWrite))
                continue
            }

            // 2) Sentinels: OFF / tentative produce no event.
            if ShiftCodeNormalizer.isOff(shift.normalizedCode) {
                drafts.append(draft(for: shift, label: "Off", startMinute: nil, endMinute: nil, resolved: nil, outcome: .skippedOff)); continue
            }
            if ShiftCodeNormalizer.isTentative(shift.normalizedCode) {
                drafts.append(draft(for: shift, label: "TBC", startMinute: nil, endMinute: nil, resolved: nil, outcome: .skippedTentative)); continue
            }

            // 3) Legend lookup.
            if let entry = legend.entry(for: shift.normalizedCode) {
                let resolved = ShiftTimeResolver.resolve(
                    localDay: shift.localDate,
                    startMinuteOfDay: entry.startMinute,
                    endMinuteOfDay: entry.endMinute,
                    timeZone: tz
                )
                drafts.append(draft(for: shift, label: entry.label, startMinute: entry.startMinute, endMinute: entry.endMinute, resolved: resolved, outcome: resolved == nil ? .skippedUnmapped : .willWrite))
            } else {
                unmapped.insert(shift.normalizedCode)
                drafts.append(draft(for: shift, label: nil, startMinute: nil, endMinute: nil, resolved: nil, outcome: .skippedUnmapped))
            }
        }

        return RosterImportResult(drafts: drafts, sourceName: sourceName, unmappedCodes: unmapped.sorted())
    }

    private static func draft(for shift: ParsedShift, label: String?, startMinute: Int?, endMinute: Int?, resolved: ResolvedShiftTimes?, outcome: DraftShift.Outcome) -> DraftShift {
        DraftShift(
            localDate: shift.localDate,
            timeZoneIdentifier: shift.timeZoneIdentifier,
            code: shift.normalizedCode,
            label: label,
            title: shift.title,
            location: shift.location,
            startMinuteOfDay: startMinute,
            endMinuteOfDay: endMinute,
            start: resolved?.start,
            end: resolved?.end,
            paidHours: resolved?.paidHours(breakMinutes: 0),
            dedupKey: shift.dedupKeyInput,
            sourceRow: shift.sourceRow,
            outcome: outcome
        )
    }
}
