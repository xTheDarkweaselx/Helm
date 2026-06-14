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

// v6: the legend is HelmDomain's three-tier MergedLegend (built-ins < global
// ShiftTypes < per-source learned mappings). LegendBuilder snapshots SwiftData
// into it on the main actor; this file stays pure.

/// A resolved candidate shift, shown in the preview before writing.
nonisolated struct DraftShift: Identifiable, Sendable {
    enum Outcome: Sendable, Equatable {
        case willWrite
        case skippedOff
        case skippedTentative
        /// The user explicitly mapped this code to "ignore" — never conflated
        /// with roster OFF days in the health summary.
        case skippedByRule
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
    /// Tentative (TBC) shifts write as ALL-DAY events: the worker still owns
    /// the day even when the roster hasn't committed to times (v6 fix for nine
    /// silently-dropped real working days). Re-import upgrades them in place:
    /// code TBC → M changes the dedupKey, so the diff removes + re-adds.
    let isAllDay: Bool
    let dedupKey: String
    let sourceRow: Int?
    /// When set (rota builder), the engine reuses this exact ShiftType instead of
    /// fetching by code / synthesizing a bare one. Imports leave it nil.
    let shiftTypeID: String?
    let outcome: Outcome

    var isWritable: Bool { outcome == .willWrite }
}

enum RosterImportError: LocalizedError {
    case couldNotReadFile
    case noColumnsDetected
    case noRows
    case legacyXLS

    var errorDescription: String? {
        switch self {
        case .couldNotReadFile: "Helm couldn't read that file."
        case .noColumnsDetected: "Helm couldn't find a date column and a shift column in that file."
        case .noRows: "No shifts were found in that file."
        case .legacyXLS: "That's an older Excel .xls file. In Excel choose File → Save As and pick “Excel Workbook (.xlsx)” or “CSV”, then import that."
        }
    }
}

nonisolated struct RosterImportResult: Sendable {
    var drafts: [DraftShift]
    /// Stable identity used for the re-import fingerprint (filename, or "schedule:<id>").
    var sourceName: String
    var unmappedCodes: [String]
    /// Human-readable roster title (falls back to sourceName). Built rotas set this
    /// to the schedule's title so the sidebar doesn't show the raw fingerprint.
    var displayName: String? = nil
    /// Retained parse rows so the review panel can RE-resolve after learning a
    /// code, without re-reading the (expired security-scope) file.
    var parsed: [ParsedShift] = []

    var writableCount: Int { drafts.filter(\.isWritable).count }
}

enum RosterImporter {

    /// Parse CSV text into resolved draft shifts.
    nonisolated static func importCSV(
        text: String,
        sourceName: String,
        legend: MergedLegend = LegendMerger.merge(globalTypes: [], learned: []),
        timeZoneIdentifier: String = TimeZone.current.identifier,
        dateOrder: RosterDateParser.Order = .dayFirst
    ) throws -> RosterImportResult {
        let grid = CSVParser.parse(text, sheetName: sourceName)
        return try resolve(grid: grid, sourceName: sourceName, legend: legend,
                           timeZoneIdentifier: timeZoneIdentifier, dateOrder: dateOrder)
    }

    /// Parse `.xlsx` file data into resolved draft shifts via the vendored
    /// CoreXLSX fork + Helm date resolver. The adapter emits `dd/MM/yyyy` date
    /// text, so the default `.dayFirst` order is correct (no caller change).
    nonisolated static func importXLSX(
        data: Data,
        sourceName: String,
        legend: MergedLegend = LegendMerger.merge(globalTypes: [], learned: []),
        timeZoneIdentifier: String = TimeZone.current.identifier,
        dateOrder: RosterDateParser.Order = .dayFirst
    ) throws -> RosterImportResult {
        let grid: SpreadsheetGrid
        do {
            grid = try XLSXGridLoader.load(data: data, timeZoneIdentifier: timeZoneIdentifier)
        } catch {
            throw RosterImportError.couldNotReadFile
        }
        return try resolve(grid: grid, sourceName: sourceName, legend: legend,
                           timeZoneIdentifier: timeZoneIdentifier, dateOrder: dateOrder)
    }

    /// Shared: pick the first sheet with a detectable roster layout, interpret it,
    /// and resolve drafts (so multi-sheet workbooks just work).
    nonisolated private static func resolve(
        grid: SpreadsheetGrid,
        sourceName: String,
        legend: MergedLegend,
        timeZoneIdentifier: String,
        dateOrder: RosterDateParser.Order
    ) throws -> RosterImportResult {
        guard !grid.sheets.isEmpty else { throw RosterImportError.couldNotReadFile }

        var sawMapping = false
        for sheet in grid.sheets {
            guard let mapping = ListLayoutDetector.detect(sheet: sheet) else { continue }
            sawMapping = true
            // Smart date order: when the caller left the default (.dayFirst), infer
            // the column's true order so a US mm/dd or ISO file stops silently
            // landing on the wrong day. An explicit non-default order is respected.
            let effectiveOrder = dateOrder == .dayFirst
                ? RosterDateParser.inferOrder(from: dateSamples(sheet: sheet, mapping: mapping))
                : dateOrder
            let parsed = ListLayoutInterpreter.interpret(
                sheet: sheet, mapping: mapping,
                timeZoneIdentifier: timeZoneIdentifier, dateOrder: effectiveOrder
            )
            if !parsed.isEmpty {
                return makeResult(parsed: parsed, sourceName: sourceName, legend: legend)
            }
        }
        throw sawMapping ? RosterImportError.noRows : RosterImportError.noColumnsDetected
    }

    /// The date-column cell strings (rows below the header), for order inference.
    nonisolated private static func dateSamples(sheet: Sheet, mapping: ListColumnMapping) -> [String] {
        let lastRow = sheet.rowCount - 1
        guard lastRow >= mapping.headerRowCount else { return [] }
        return (mapping.headerRowCount...lastRow).compactMap {
            sheet.cell(CellReference(column: mapping.dateColumn, row: $0))?.text
        }
    }

    /// Pure re-resolution over a result's retained rows — the review panel
    /// calls this after a mapping is learned (no file re-read: the
    /// security-scoped URL is long gone by then). dedupKeys derive from
    /// code+date only, so identities are stable across re-resolution.
    nonisolated static func reresolve(_ result: RosterImportResult, legend: MergedLegend) -> RosterImportResult {
        var newResult = makeResult(parsed: result.parsed, sourceName: result.sourceName, legend: legend)
        newResult.displayName = result.displayName
        return newResult
    }

    nonisolated private static func makeResult(parsed: [ParsedShift], sourceName: String, legend: MergedLegend) -> RosterImportResult {
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

            // A trailing note ("M (training)", "OFF*") shouldn't make a known code
            // unknown — match against the stripped form as a fallback.
            let code = shift.normalizedCode
            let stripped = ShiftCodeNormalizer.stripAnnotation(code)

            func allDayDraft(label: String?) {
                var dayCal = Calendar(identifier: .gregorian)
                dayCal.timeZone = tz
                let dayStart = dayCal.startOfDay(for: shift.localDate)
                drafts.append(draft(for: shift, label: label, startMinute: nil, endMinute: nil,
                                    resolved: nil, outcome: .willWrite,
                                    allDay: (start: dayStart, end: dayStart)))
            }

            // 2) An EXPLICIT legend mapping (learned > global > built-in), exact
            // then annotation-stripped, WINS over the conventional sentinels — so a
            // user who maps an off-looking code (e.g. "X") to a real shift is
            // honoured rather than silently dropped as an off day.
            switch legend.resolution(for: code) ?? legend.resolution(for: stripped) {
            case let .timed(entry):
                let resolved = ShiftTimeResolver.resolve(
                    localDay: shift.localDate,
                    startMinuteOfDay: entry.startMinute,
                    endMinuteOfDay: entry.endMinute,
                    timeZone: tz
                )
                drafts.append(draft(for: shift, label: entry.label, startMinute: entry.startMinute, endMinute: entry.endMinute, resolved: resolved, outcome: resolved == nil ? .skippedUnmapped : .willWrite, breakMinutes: entry.breakMinutes, shiftTypeID: entry.shiftTypeID))
            case let .allDay(label):
                allDayDraft(label: label ?? code)
            case .ignore:
                drafts.append(draft(for: shift, label: nil, startMinute: nil, endMinute: nil, resolved: nil, outcome: .skippedByRule))
            case nil:
                // 3) No explicit mapping → conventional fallbacks: OFF (no event),
                // then tentative (all-day TBC), then a known leave/holiday code
                // (all-day), else surfaced as unknown — never a silent drop.
                if ShiftCodeNormalizer.isOff(code) || ShiftCodeNormalizer.isOff(stripped) {
                    drafts.append(draft(for: shift, label: "Off", startMinute: nil, endMinute: nil, resolved: nil, outcome: .skippedOff))
                } else if ShiftCodeNormalizer.isTentative(code) || ShiftCodeNormalizer.isTentative(stripped) {
                    allDayDraft(label: "TBC")
                } else if let leave = ShiftCodeNormalizer.leaveLabel(code) {
                    allDayDraft(label: leave)
                } else {
                    unmapped.insert(code)
                    drafts.append(draft(for: shift, label: nil, startMinute: nil, endMinute: nil, resolved: nil, outcome: .skippedUnmapped))
                }
            }
        }

        return RosterImportResult(drafts: drafts, sourceName: sourceName, unmappedCodes: unmapped.sorted(), parsed: parsed)
    }

    nonisolated private static func draft(for shift: ParsedShift, label: String?, startMinute: Int?, endMinute: Int?, resolved: ResolvedShiftTimes?, outcome: DraftShift.Outcome, allDay: (start: Date, end: Date)? = nil, breakMinutes: Int = 0, shiftTypeID: String? = nil) -> DraftShift {
        DraftShift(
            localDate: shift.localDate,
            timeZoneIdentifier: shift.timeZoneIdentifier,
            code: shift.normalizedCode,
            label: label,
            title: shift.title,
            location: shift.location,
            startMinuteOfDay: startMinute,
            endMinuteOfDay: endMinute,
            start: allDay?.start ?? resolved?.start,
            end: allDay?.end ?? resolved?.end,
            paidHours: resolved?.paidHours(breakMinutes: breakMinutes),
            isAllDay: allDay != nil,
            dedupKey: shift.dedupKeyInput,
            sourceRow: shift.sourceRow,
            shiftTypeID: shiftTypeID,
            outcome: outcome
        )
    }
}
