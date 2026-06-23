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
    @State private var showingPayslips = false
    @State private var isExporting = false
    /// Built once when Export is tapped (not on every body render) so the file
    /// reflects the period showing at that moment.
    @State private var exportText = ""
    @State private var exportError: String?

    private var calendar: Calendar { CalendarViewModel.displayCalendar }
    private var today: DayKey { DayKey(containing: .now, in: calendar) }
    private var rules: PayRules { PaySettings.rules }
    private var currency: String { PaySettings.currencyCode }
    /// v9 Multiple Jobs — combined total + per-employer subtotals, each job under
    /// its own resolved rules.
    private var pay: (combined: PaySummary, employers: [EmployerPay]) {
        JobPay.breakdown(instances: instances, in: range, global: rules, calendar: calendar)
    }

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
    private var rows: [TimesheetRow] { JobPay.rows(instances: instances, in: range, global: rules, calendar: calendar) }
    /// Pay is usable when a global rate is set OR any roster carries its own rate
    /// override — mirror of OverviewView's gate, so the two screens never disagree.
    private var payActive: Bool {
        rules.isActive || instances.contains { $0.roster?.hourlyRateOverride != nil }
    }

    var body: some View {
        Group {
            if !payActive {
                noRate
            } else {
                content
            }
        }
        .themedPane()
        .navigationTitle("Timesheet")
        .toolbar {
            if payActive {
                ToolbarItem {
                    Button("Payslips", systemImage: "doc.text.magnifyingglass") { showingPayslips = true }
                }
                ToolbarItem {
                    Button("Export CSV", systemImage: "square.and.arrow.up") {
                        exportText = csv()
                        isExporting = true
                    }
                    .disabled(pay.combined.totalHours <= 0)
                }
            }
        }
        .navigationDestination(isPresented: $showingPayslips) { PayslipsView() }
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
            Button("Open Settings", action: openSettings).buttonStyle(.glassProminent)
        }
    }

    private var content: some View {
        // Compute the breakdown and rows ONCE per render (each is an O(shifts ×
        // premium-minutes) pass over the whole store), then derive everything below.
        let p = pay
        let r = rows
        let multi = p.employers.count > 1
        return List {
            Section {
                Picker("Period", selection: $period) {
                    ForEach(Period.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section { summaryCard(p.combined) }

            forecastSection

            if multi {
                Section("By employer") {
                    ForEach(p.employers) { employerRow($0) }
                }
            }

            if r.isEmpty {
                Section { Text("No paid shifts in this period.").foregroundStyle(.secondary) }
            } else {
                Section("Shifts (\(r.count))") {
                    ForEach(r) { lineRow($0.item, employer: multi ? $0.employer : nil) }
                }
            }
        }
    }

    // MARK: - Payday forecast (v9)

    private var payCycle: PayCycle? { PaySettings.payCycle }

    @ViewBuilder
    private var forecastSection: some View {
        if let cycle = payCycle {
            let upcoming = cycle.upcomingPaydays(from: today, count: 2, calendar: calendar)
            Section {
                ForEach(Array(upcoming.enumerated()), id: \.offset) { _, entry in
                    forecastRow(payday: entry.payday, period: entry.period)
                }
            } header: {
                Text("Upcoming paydays")
            } footer: {
                Text("Projected from your scheduled shifts at your current rates. An estimate, not a promise.")
            }
        }
    }

    private func forecastRow(payday: DayKey, period: ClosedRange<DayKey>) -> some View {
        let gross = JobPay.breakdown(instances: instances, in: period, global: rules, calendar: calendar).combined.grossPay
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(payday.startOfDay(in: calendar), format: .dateTime.weekday().day().month())
                    .font(.subheadline.weight(.medium))
                Text(forecastSubtitle(payday: payday, period: period))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(gross, format: .currency(code: currency)).font(.subheadline.monospacedDigit())
        }
    }

    private func forecastSubtitle(payday: DayKey, period: ClosedRange<DayKey>) -> String {
        let days = calendar.dateComponents([.day], from: today.startOfDay(in: calendar), to: payday.startOfDay(in: calendar)).day ?? 0
        let when = days <= 0 ? "today" : (days == 1 ? "tomorrow" : "in \(days) days")
        let lo = period.lowerBound.startOfDay(in: calendar).formatted(.dateTime.day().month())
        let hi = period.upperBound.startOfDay(in: calendar).formatted(.dateTime.day().month())
        return "\(when) · for \(lo)–\(hi)"
    }

    /// One employer's subtotal in the multi-job breakdown.
    private func employerRow(_ e: EmployerPay) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(e.employer).font(.subheadline.weight(.medium))
                Text("\(hoursText(e.summary.totalHours)) h · \(e.rate.formatted(.currency(code: currency)))/h")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(e.summary.grossPay, format: .currency(code: currency))
                .font(.subheadline.monospacedDigit())
        }
    }

    private func summaryCard(_ summary: PaySummary) -> some View {
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
                Text("\(summary.tentativeCount) shift\(summary.tentativeCount == 1 ? "" : "s") still need times — not paid yet.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            Text(grossFooter(summary))
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

    private func lineRow(_ item: PayLineItem, employer: String?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.day.startOfDay(in: calendar), format: .dateTime.weekday(.abbreviated).day().month())
                    .font(.subheadline)
                HStack(spacing: 6) {
                    if let employer {
                        Text(employer).font(.caption2.weight(.medium)).foregroundStyle(accent)
                    }
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
    private func grossFooter(_ summary: PaySummary) -> String {
        var parts: [String] = []
        if summary.overtimeHours > 0 {
            parts.append("overtime above \(hoursText(rules.overtimeThresholdHours)) h/week at \(rules.overtimeMultiplier.formatted(.number))×")
        }
        if summary.premiumPay > 0 { parts.append("your premium pay rules") }
        guard !parts.isEmpty else { return "Gross, before tax, at a flat hourly rate." }
        return "Gross, before tax. Includes " + parts.joined(separator: " and ") + "."
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

        let p = pay
        let r = rows
        let summary = p.combined
        let multi = p.employers.count > 1
        // Place hours/pay in the right columns whether or not an Employer column exists.
        let width = multi ? 7 : 6
        func summaryRow(_ label: String, hours: Double? = nil, pay: Double? = nil) -> String {
            var cells = Array(repeating: "", count: width)
            cells[0] = label
            if let hours { cells[multi ? 5 : 4] = num(hours) }
            if let pay { cells[multi ? 6 : 5] = num(pay) }
            return csvRow(cells)
        }

        var header = ["Date", "Shift", "Start", "End", "Hours", "Pay (\(currency))"]
        if multi { header.insert("Employer", at: 1) }
        var lines = [csvRow(header)]
        for row in r {
            let item = row.item
            var cells = [
                df.string(from: item.day.startOfDay(in: calendar)),
                item.typeLabel ?? "",
                item.start.map { tf.string(from: $0) } ?? "",
                item.end.map { tf.string(from: $0) } ?? "",
                num(item.hours),
                num(item.pay),
            ]
            if multi { cells.insert(row.employer, at: 1) }
            lines.append(csvRow(cells))
        }
        lines.append("")
        if multi {
            for e in p.employers {
                lines.append(summaryRow("\(e.employer) — gross", hours: e.summary.totalHours, pay: e.summary.grossPay))
            }
            lines.append("")
        }
        lines.append(summaryRow("Total hours", hours: summary.totalHours))
        if summary.overtimeHours > 0 {
            lines.append(summaryRow("Base pay", pay: summary.basePay))
            lines.append(summaryRow("Overtime pay", pay: summary.overtimePay))
        }
        if summary.premiumPay > 0 {
            lines.append(summaryRow("Premium pay", pay: summary.premiumPay))
        }
        lines.append(summaryRow("Gross pay", pay: summary.grossPay))
        return lines.joined(separator: "\r\n") // RFC-4180 line ending
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
