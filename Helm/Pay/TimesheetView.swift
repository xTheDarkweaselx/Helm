//
//  TimesheetView.swift
//  Helm
//
//  v8 Pay & timesheets: gross pay + an exportable per-shift breakdown for a
//  chosen period (this week / month / tax year), computed by the pure PayEngine
//  over the SAME InsightShift values the dashboard uses.
//

import SwiftUI
import SwiftData
import HelmDomain
import UniformTypeIdentifiers

struct TimesheetView: View {
    @Query private var instances: [ShiftInstance]
    @Environment(\.helmAccent) private var accent
    /// Jump to Settings (owned by ContentView) to set a rate.
    let openSettings: () -> Void

    enum Period: String, CaseIterable, Identifiable {
        case week, month, taxYear
        var id: String { rawValue }
        var label: String {
            switch self {
            case .week: "This week"
            case .month: "This month"
            case .taxYear: "Tax year"
            }
        }
    }
    @State private var period: Period = .month
    @State private var isExporting = false
    /// Built once when Export is tapped (not on every body render) so the file
    /// reflects the period showing at that moment.
    @State private var exportText = ""
    @State private var exportError: String?

    private var calendar: Calendar { CalendarViewModel.displayCalendar }
    private var today: DayKey { DayKey(containing: .now, in: calendar) }
    private var rules: PayRules { PaySettings.rules }
    private var currency: String { PaySettings.currencyCode }
    private var allShifts: [InsightShift] { InsightsSnapshot.shifts(from: instances) }

    private var range: ClosedRange<DayKey> {
        switch period {
        case .week:
            let start = InsightsMath.weekStart(of: today, calendar: calendar)
            return start...start.advanced(by: 6, in: calendar)
        case .month:
            return InsightsMath.monthRange(MonthKey(of: today), calendar: calendar)
        case .taxYear:
            return PayEngine.taxYearRange(containing: today, rules: rules, calendar: calendar)
        }
    }
    private var summary: PaySummary { PayEngine.summary(shifts: allShifts, in: range, rules: rules, calendar: calendar) }
    private var items: [PayLineItem] { PayEngine.lineItems(shifts: allShifts, in: range, rules: rules, calendar: calendar) }

    var body: some View {
        Group {
            if !rules.isActive {
                noRate
            } else {
                content
            }
        }
        .themedPane()
        .navigationTitle("Timesheet")
        .toolbar {
            if rules.isActive {
                ToolbarItem {
                    Button("Export CSV", systemImage: "square.and.arrow.up") {
                        exportText = csv()
                        isExporting = true
                    }
                    .disabled(items.isEmpty)
                }
            }
        }
        .fileExporter(isPresented: $isExporting,
                      document: CSVFile(text: exportText),
                      contentType: .commaSeparatedText,
                      defaultFilename: exportFilename) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert("Couldn’t export timesheet", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let exportError { Text(exportError) }
        }
    }

    private var noRate: some View {
        ContentUnavailableView {
            Label("Set an hourly rate", systemImage: "sterlingsign.circle")
        } description: {
            Text("Add your hourly rate in Settings to see pay totals and export a timesheet.")
        } actions: {
            Button("Open Settings", action: openSettings).buttonStyle(.borderedProminent)
        }
    }

    private var content: some View {
        List {
            Section {
                Picker("Period", selection: $period) {
                    ForEach(Period.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section { summaryCard }

            if items.isEmpty {
                Section { Text("No paid shifts in this period.").foregroundStyle(.secondary) }
            } else {
                Section("Shifts (\(items.count))") {
                    ForEach(items) { lineRow($0) }
                }
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(rangeLabel).font(.caption).foregroundStyle(.secondary)
            Text(summary.grossPay, format: .currency(code: currency))
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .foregroundStyle(accent)
            HStack(alignment: .top, spacing: 18) {
                metric("Hours", hoursText(summary.totalHours))
                if summary.overtimeHours > 0 {
                    metric("Overtime", "\(hoursText(summary.overtimeHours)) h")
                }
                if summary.premiumPay > 0 {
                    metric("Premium", summary.premiumPay.formatted(.currency(code: currency)))
                }
                metric("Shifts", "\(summary.shiftCount)")
            }
            if summary.tentativeCount > 0 {
                Text("\(summary.tentativeCount) shift\(summary.tentativeCount == 1 ? "" : "s") awaiting times — not yet paid.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            Text(grossFooter)
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func lineRow(_ item: PayLineItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.day.startOfDay(in: calendar), format: .dateTime.weekday(.abbreviated).day().month())
                    .font(.subheadline)
                HStack(spacing: 6) {
                    if let label = item.typeLabel {
                        Text(label).font(.caption2).foregroundStyle(.secondary)
                    }
                    if let s = item.start, let e = item.end {
                        Text("\(s.formatted(date: .omitted, time: .shortened))–\(e.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(item.pay, format: .currency(code: currency)).font(.subheadline.monospacedDigit())
                Text("\(hoursText(item.hours)) h").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                if item.premiumPay > 0 {
                    Text("incl. \(item.premiumPay.formatted(.currency(code: currency)))")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Explains what's inside the gross figure (overtime and/or premium rules).
    private var grossFooter: String {
        var parts: [String] = []
        if summary.overtimeHours > 0 {
            parts.append("the overtime premium above \(hoursText(rules.overtimeThresholdHours)) h/week at \(rules.overtimeMultiplier.formatted(.number))×")
        }
        if summary.premiumPay > 0 { parts.append("your premium pay rules") }
        guard !parts.isEmpty else { return "Gross, before tax, at a flat hourly rate." }
        return "Gross, before tax — includes " + parts.joined(separator: " and ") + "."
    }

    private var rangeLabel: String {
        let lo = range.lowerBound.startOfDay(in: calendar)
        let hi = range.upperBound.startOfDay(in: calendar)
        return "\(lo.formatted(date: .abbreviated, time: .omitted)) – \(hi.formatted(date: .abbreviated, time: .omitted))"
    }

    private func hoursText(_ h: Double) -> String {
        h.formatted(.number.precision(.fractionLength(0...1)))
    }

    private var exportFilename: String {
        func pad(_ n: Int) -> String { String(format: "%02d", n) }
        let lo = range.lowerBound
        switch period {
        case .week:    return "Helm timesheet week \(lo.year)-\(pad(lo.month))-\(pad(lo.day))"
        case .month:   return "Helm timesheet \(lo.year)-\(pad(lo.month))"
        case .taxYear: return "Helm timesheet tax year \(lo.year)-\(pad(range.upperBound.year % 100))"
        }
    }

    /// One CSV cell, RFC-4180 quoted, with a guard against spreadsheet formula
    /// injection — a leading `= + - @` (or tab/CR) would otherwise execute as a
    /// formula in Excel/Sheets, so it's prefixed with an apostrophe.
    private func csvField(_ s: String) -> String {
        var v = s
        if let first = v.first, "=+-@\t\r".contains(first) { v = "'" + v }
        if v.contains(where: { ",\"\n\r".contains($0) }) {
            v = "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return v
    }
    private func csvRow(_ cells: [String]) -> String { cells.map(csvField).joined(separator: ",") }

    private func csv() -> String {
        // Times are formatted in the app's display zone, consistent with the rest
        // of Helm (per-shift zones aren't threaded through the timesheet yet).
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = calendar.timeZone
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"; tf.timeZone = calendar.timeZone
        // Locale-invariant decimals (period separator, full precision) so the file
        // parses identically in every locale and Hours × rate reconciles with Pay.
        func num(_ v: Double) -> String { String(format: "%.2f", v) }

        var rows = [csvRow(["Date", "Shift", "Start", "End", "Hours", "Pay (\(currency))"])]
        for item in items {
            rows.append(csvRow([
                df.string(from: item.day.startOfDay(in: calendar)),
                item.typeLabel ?? "",
                item.start.map { tf.string(from: $0) } ?? "",
                item.end.map { tf.string(from: $0) } ?? "",
                num(item.hours),
                num(item.pay),
            ]))
        }
        rows.append("")
        rows.append(csvRow(["Total hours", "", "", "", num(summary.totalHours), ""]))
        if summary.overtimeHours > 0 {
            rows.append(csvRow(["Base pay", "", "", "", "", num(summary.basePay)]))
            rows.append(csvRow(["Overtime pay", "", "", "", "", num(summary.overtimePay)]))
        }
        rows.append(csvRow(["Gross pay", "", "", "", "", num(summary.grossPay)]))
        return rows.joined(separator: "\r\n") // RFC-4180 line ending
    }
}

/// Minimal CSV document for `.fileExporter`.
struct CSVFile: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
