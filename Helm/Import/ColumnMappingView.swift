//
//  ColumnMappingView.swift
//  Helm
//
//  v8.1 "never dead-end" manual column mapper: when auto-detection can't find the
//  date + shift columns (non-English/abbreviated/missing headers, an unusual
//  sheet), the user maps them by hand over a raw-grid preview — pick the sheet,
//  the header row, which column is the date / shift code / title / location, and
//  the date format — with a LIVE parse preview, then resolve. Reached on a
//  detection failure or via "Columns wrong?" in the preview.
//

import SwiftUI
import HelmDomain
import HelmParsing

struct ColumnMappingView: View {
    let grid: SpreadsheetGrid
    let sourceDisplayName: String
    /// (sheetIndex, mapping, dateOrder)
    let onApply: (Int, ListColumnMapping, RosterDateParser.Order) -> Void
    let onCancel: () -> Void

    @State private var sheetIndex = 0
    @State private var headerRow = 0
    @State private var dateCol: Int?
    @State private var codeCol: Int?
    @State private var titleCol: Int?
    @State private var locationCol: Int?
    @State private var dateOrder: RosterDateParser.Order = .auto
    @State private var aiSuggesting = false
    @State private var aiError: String?

    // `body` only builds `mapper` (the sole user of `sheet`) when sheets is
    // non-empty, and RosterImporter.grid() rejects an empty grid — but never
    // subscript sheets[-1]: clamp to a valid index and fall back to an empty sheet.
    private var sheet: Sheet {
        guard !grid.sheets.isEmpty else { return Sheet(name: "", cells: [:]) }
        return grid.sheets[min(max(sheetIndex, 0), grid.sheets.count - 1)]
    }
    private var columnIndices: [Int] { Array(0..<max(sheet.columnCount, 1)) }

    private var mapping: ListColumnMapping? {
        guard let dateCol, let codeCol else { return nil }
        return ListColumnMapping(dateColumn: dateCol, codeColumn: codeCol,
                                 titleColumn: titleCol, locationColumn: locationCol,
                                 headerRowCount: headerRow + 1)
    }

    /// The concrete order the COMMIT will use: an explicit pick, or — for
    /// "Auto-detect" — the SAME column-wide inference resolveManual() applies, so
    /// the preview's dates are exactly what gets written (no per-cell vs column
    /// disagreement on ambiguous dates).
    private var effectiveOrder: RosterDateParser.Order {
        guard dateOrder == .auto, let dateCol else { return dateOrder }
        let lastRow = sheet.rowCount - 1
        guard lastRow >= headerRow + 1 else { return .dayFirst }
        let samples = ((headerRow + 1)...lastRow).compactMap {
            sheet.cell(CellReference(column: dateCol, row: $0))?.text
        }
        return RosterDateParser.inferOrder(from: samples)
    }

    /// Live re-interpretation with the current choices (pure, in-memory).
    private var previewShifts: [ParsedShift] {
        guard let mapping else { return [] }
        return ListLayoutInterpreter.interpret(sheet: sheet, mapping: mapping,
                                               timeZoneIdentifier: TimeZone.current.identifier,
                                               dateOrder: effectiveOrder)
    }

    var body: some View {
        // Defence in depth — RosterImporter.grid() already rejects an empty grid,
        // so the mapper is never presented one, but never risk indexing sheets[-1].
        if grid.sheets.isEmpty {
            ContentUnavailableView("Couldn’t read this file", systemImage: "tablecells")
        } else {
            mapper
        }
    }

    private var mapper: some View {
        Form {
            Section {
                Text("Helm couldn’t find the columns in “\(sourceDisplayName)”. Pick which hold your shifts — the preview updates as you go.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            #if canImport(FoundationModels)
            if SmartImport.isAvailable {
                Section {
                    Button { Task { await suggestColumnsWithAI() } } label: {
                        HStack {
                            Label("Suggest columns with Apple Intelligence", systemImage: "sparkles")
                            Spacer()
                            if aiSuggesting { ProgressView() }
                        }
                    }
                    .disabled(aiSuggesting)
                    if let aiError {
                        Text(aiError).font(.caption).foregroundStyle(.orange)
                    }
                } footer: {
                    Text("Fills in the columns below for you to confirm.")
                }
            }
            #endif

            if grid.sheets.count > 1 {
                Section("Sheet") {
                    Picker("Sheet", selection: $sheetIndex) {
                        ForEach(grid.sheets.indices, id: \.self) { i in
                            Text(grid.sheets[i].name.isEmpty ? "Sheet \(i + 1)" : grid.sheets[i].name).tag(i)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            Section("Raw data") {
                rawGridPreview
                Stepper(value: $headerRow, in: 0...max(0, min(sheet.rowCount - 1, 9))) {
                    Text("Header is row \(headerRow + 1)")
                }
            }

            Section("Columns") {
                columnPicker("Date", selection: $dateCol, includeNone: false)
                columnPicker("Shift code", selection: $codeCol, includeNone: false)
                columnPicker("Title (optional)", selection: $titleCol, includeNone: true)
                columnPicker("Location (optional)", selection: $locationCol, includeNone: true)
                Picker("Date format", selection: $dateOrder) {
                    ForEach(RosterDateParser.Order.allCases, id: \.self) { Text(orderLabel($0)).tag($0) }
                }
                .pickerStyle(.menu)
            }

            Section("Preview") { previewSummary }
        }
        .formStyle(.grouped)
        .themedPane(.grouped)
        .navigationTitle("Map columns")
        .onAppear(perform: prefillFromDetector)
        .onChange(of: sheetIndex) {
            dateCol = nil; codeCol = nil; titleCol = nil; locationCol = nil; headerRow = 0
            prefillFromDetector()
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.glass)
                Spacer()
                Button("Use this mapping") {
                    if let mapping { onApply(sheetIndex, mapping, effectiveOrder) }
                }
                .buttonStyle(.glassProminent)
                .disabled(mapping == nil || previewShifts.isEmpty)
            }
            .padding()
        }
    }

    // MARK: - Raw grid

    private var rawGridPreview: some View {
        let rows = min(sheet.rowCount, 6)
        return ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 2) {
                    ForEach(columnIndices, id: \.self) { col in
                        Text(CellReference.columnLetters(col))
                            .font(.caption2.weight(.bold).monospaced())
                            .frame(width: 88, alignment: .leading)
                            .foregroundStyle(roleColor(col) ?? .secondary)
                    }
                }
                ForEach(0..<max(rows, 0), id: \.self) { row in
                    HStack(spacing: 2) {
                        ForEach(columnIndices, id: \.self) { col in
                            Text(sheet.cell(CellReference(column: col, row: row))?.text ?? "")
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                                .frame(width: 88, alignment: .leading)
                                .foregroundStyle(row == headerRow ? Color.primary : .secondary)
                                .fontWeight(row == headerRow ? .semibold : .regular)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// Tint a column's letter once it's been assigned a role.
    private func roleColor(_ col: Int) -> Color? {
        if col == dateCol { return .blue }
        if col == codeCol { return .green }
        if col == titleCol || col == locationCol { return .purple }
        return nil
    }

    // MARK: - Pickers

    private func columnPicker(_ title: String, selection: Binding<Int?>, includeNone: Bool) -> some View {
        Picker(title, selection: selection) {
            if includeNone {
                Text("None").tag(Int?.none)
            } else if selection.wrappedValue == nil {
                Text("Choose…").tag(Int?.none)
            }
            ForEach(columnIndices, id: \.self) { col in
                Text(columnLabel(col)).tag(Int?.some(col))
            }
        }
        .pickerStyle(.menu)
    }

    private func columnLabel(_ col: Int) -> String {
        let letter = CellReference.columnLetters(col)
        let header = sheet.cell(CellReference(column: col, row: headerRow))?.text.trimmingCharacters(in: .whitespaces)
        if let header, !header.isEmpty { return "\(letter) — \(header)" }
        return letter
    }

    private func orderLabel(_ o: RosterDateParser.Order) -> String {
        switch o {
        case .auto: "Auto-detect"
        case .dayFirst: "Day first (DD/MM)"
        case .monthFirst: "Month first (MM/DD)"
        case .iso: "Year first (ISO)"
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private var previewSummary: some View {
        if mapping == nil {
            Label("Pick a Date column and a Shift-code column above.", systemImage: "arrow.up")
                .font(.caption).foregroundStyle(.secondary)
        } else if previewShifts.isEmpty {
            Label("No shifts found — check the Date column and format.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        } else {
            Label("\(previewShifts.count) day\(previewShifts.count == 1 ? "" : "s") found", systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.green)
            ForEach(Array(previewShifts.prefix(4).enumerated()), id: \.offset) { _, shift in
                HStack {
                    Text(shift.localDate, format: .dateTime.weekday(.abbreviated).day().month())
                    Spacer()
                    Text(sampleValue(shift)).foregroundStyle(.secondary)
                }
                .font(.caption.monospaced())
            }
        }
    }

    private func sampleValue(_ shift: ParsedShift) -> String {
        if let t = shift.inlineTimes {
            return "\(hhmmCell(t.startMinuteOfDay))–\(hhmmCell(t.endMinuteOfDay))"
        }
        return shift.normalizedCode.isEmpty ? "—" : shift.normalizedCode
    }

    /// Seed unset roles from auto-detection without overriding the user's own
    /// picks. (On a sheet switch the caller clears the fields first, so each sheet
    /// gets a fresh detection.)
    private func prefillFromDetector() {
        guard let m = ListLayoutDetector.detect(sheet: sheet) else { return }
        if dateCol == nil { dateCol = m.dateColumn }
        if codeCol == nil { codeCol = m.codeColumn }
        if titleCol == nil { titleCol = m.titleColumn }
        if locationCol == nil { locationCol = m.locationColumn }
        if dateCol != nil || codeCol != nil { headerRow = max(0, m.headerRowCount - 1) }
    }

    #if canImport(FoundationModels)
    /// Tab-separated rows of the sheet (first ~12), each column labelled with its
    /// 0-based index, for the model to map roles onto.
    private func gridText() -> String {
        let rows = min(sheet.rowCount, 12)
        let cols = columnIndices
        var lines = [cols.map { "Col\($0)" }.joined(separator: "\t")]
        for r in 0..<max(rows, 0) {
            lines.append(cols.map { sheet.cell(CellReference(column: $0, row: r))?.text ?? "" }.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    private func suggestColumnsWithAI() async {
        guard #available(iOS 26, macOS 26, *) else { return }
        aiError = nil
        aiSuggesting = true
        defer { aiSuggesting = false }
        do {
            let s = try await SmartImport.suggestColumns(from: gridText())
            let maxCol = sheet.columnCount - 1
            if (0...max(0, maxCol)).contains(s.dateColumn) { dateCol = s.dateColumn }
            if (0...max(0, maxCol)).contains(s.codeColumn) { codeCol = s.codeColumn }
            titleCol = (0...max(0, maxCol)).contains(s.titleColumn) ? s.titleColumn : nil
            headerRow = max(0, min(s.headerRows - 1, max(0, sheet.rowCount - 1), 9))
        } catch {
            aiError = error.localizedDescription
        }
    }
    #endif
}

private func hhmmCell(_ minute: Int) -> String {
    let m = ((minute % 1440) + 1440) % 1440
    return String(format: "%02d:%02d", m / 60, m % 60)
}
