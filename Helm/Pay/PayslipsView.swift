//
//  PayslipsView.swift
//  Helm
//
//  v9 Payslip Reconcile (the "ledger + drill-down" model). A list of pay periods
//  the user reconciles against real payslips, plus a per-payslip view that ticks
//  individual shifts Paid / Not paid / Wrong to pin down a discrepancy.
//

import SwiftUI
import SwiftData
import HelmDomain

// MARK: - List

struct PayslipsView: View {
    @Query(sort: \Payslip.createdAt, order: .reverse) private var payslips: [Payslip]
    @Query private var instances: [ShiftInstance]
    @Query private var users: [UserProfile]
    @Environment(\.modelContext) private var modelContext

    @State private var addingPayslip = false
    @State private var selected: Payslip?

    private var calendar: Calendar { CalendarViewModel.displayCalendar }
    private var currency: String { PaySettings.currencyCode }

    var body: some View {
        List {
            if payslips.isEmpty {
                Section {
                    Text("No payslips yet. Add one, then tick what landed to check it against Helm's estimate.")
                        .foregroundStyle(.secondary).font(.callout)
                }
            }
            ForEach(payslips) { slip in
                Button { selected = slip } label: { row(slip) }
                    .buttonStyle(.plain)
            }
            .onDelete { offsets in
                offsets.map { payslips[$0] }.forEach(modelContext.delete)
                try? modelContext.save()
            }
        }
        .themedPane()
        .navigationTitle("Payslips")
        .toolbar {
            ToolbarItem { Button("Add payslip", systemImage: "plus") { addingPayslip = true } }
        }
        .sheet(isPresented: $addingPayslip) {
            NewPayslipSheet(user: users.first) { addingPayslip = false }
        }
        .navigationDestination(item: $selected) { slip in
            PayslipReconcileView(payslip: slip)
        }
    }

    private func row(_ slip: Payslip) -> some View {
        let r = Reconcile.result(for: slip, allInstances: instances, calendar: calendar)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(periodLabel(slip)).font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    if let label = slip.employerLabel {
                        Text(label).font(.caption2.weight(.medium)).foregroundStyle(.tint)
                    }
                    Text("Expected \(r.expected, format: .currency(code: currency))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            statusChip(r, resolved: slip.resolved)
        }
    }

    @ViewBuilder
    private func statusChip(_ r: ReconcileResult, resolved: Bool) -> some View {
        if let delta = r.delta {
            let isShort = delta < -0.005
            let isOver = delta > 0.005
            VStack(alignment: .trailing, spacing: 1) {
                Text(r.actual ?? 0, format: .currency(code: currency))
                    .font(.subheadline.monospacedDigit())
                Text(isShort ? "short \((-delta).formatted(.currency(code: currency)))"
                     : isOver ? "over \(delta.formatted(.currency(code: currency)))"
                     : "matches")
                    .font(.caption2)
                    .foregroundStyle(isShort ? .red : isOver ? .orange : .green)
            }
        } else {
            Text(resolved ? "Resolved" : "Awaiting")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func periodLabel(_ slip: Payslip) -> String {
        guard let s = slip.periodStart, let e = slip.periodEnd else { return "Pay period" }
        let lo = s.formatted(.dateTime.day().month())
        let hi = e.formatted(.dateTime.day().month().year())
        return "\(lo) – \(hi)"
    }
}

// MARK: - New payslip

struct NewPayslipSheet: View {
    let user: UserProfile?
    let onDone: () -> Void

    @Query private var rosters: [Roster]
    @Environment(\.modelContext) private var modelContext

    @State private var start = Date.now
    @State private var end = Date.now
    @State private var payday = Date.now
    @State private var rosterID: String = ""   // "" = all jobs
    @State private var seeded = false

    private var calendar: Calendar { CalendarViewModel.displayCalendar }

    var body: some View {
        NavigationStack {
            Form {
                Section("Pay period") {
                    DatePicker("From", selection: $start, displayedComponents: .date)
                    DatePicker("To", selection: $end, displayedComponents: .date)
                    DatePicker("Payday", selection: $payday, displayedComponents: .date)
                }
                if rosters.count > 1 {
                    Section("Employer") {
                        Picker("This payslip is from", selection: $rosterID) {
                            Text("All jobs").tag("")
                            ForEach(rosters) { Text($0.employerDisplayName).tag($0.id) }
                        }
                    }
                }
            }
            .navigationTitle("New payslip")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) }
                ToolbarItem(placement: .confirmationAction) { Button("Add", action: add) }
            }
            .onAppear(perform: seedDefaults)
        }
    }

    private func seedDefaults() {
        guard !seeded else { return }
        seeded = true
        let today = DayKey(containing: .now, in: calendar)
        if let cycle = PaySettings.payCycle {
            // Default to the most recently completed period + its payday.
            let current = cycle.period(containing: today, calendar: calendar)
            let prev = cycle.period(containing: current.lowerBound.advanced(by: -1, in: calendar), calendar: calendar)
            start = prev.lowerBound.startOfDay(in: calendar)
            end = prev.upperBound.startOfDay(in: calendar)
            payday = cycle.payday(forPeriodContaining: prev.lowerBound, calendar: calendar).startOfDay(in: calendar)
        } else {
            // Last calendar month.
            let prevMonth = MonthKey(of: today).advanced(by: -1)
            let range = InsightsMath.monthRange(prevMonth, calendar: calendar)
            start = range.lowerBound.startOfDay(in: calendar)
            end = range.upperBound.startOfDay(in: calendar)
            payday = range.upperBound.startOfDay(in: calendar)
        }
    }

    private func add() {
        let roster = rosters.first { $0.id == rosterID }
        let slip = Payslip(periodStart: calendar.startOfDay(for: start),
                           periodEnd: calendar.startOfDay(for: end),
                           payday: calendar.startOfDay(for: payday),
                           rosterID: roster?.id,
                           employerLabel: roster?.employerDisplayName,
                           user: user)
        modelContext.insert(slip)
        try? modelContext.save()
        onDone()
    }
}

// MARK: - Reconcile detail

struct PayslipReconcileView: View {
    @Bindable var payslip: Payslip
    @Query private var instances: [ShiftInstance]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.helmAccent) private var accent

    @State private var actual: Double = 0
    @State private var loaded = false

    private var calendar: Calendar { CalendarViewModel.displayCalendar }
    private var currency: String { PaySettings.currencyCode }
    private var periodShifts: [ShiftInstance] { Reconcile.shifts(for: payslip, from: instances, calendar: calendar) }
    private var result: ReconcileResult { Reconcile.result(for: payslip, allInstances: instances, calendar: calendar) }

    var body: some View {
        List {
            Section { summaryCard(result) }

            Section {
                LabeledContent("You were paid") {
                    TextField("Actual gross", value: $actual, format: .currency(code: currency))
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                }
            } footer: {
                Text("Enter the gross on your payslip, then tick the shifts below to spot any gap.")
            }

            Section("Shifts (\(periodShifts.count))") {
                if periodShifts.isEmpty {
                    Text("No shifts in this period for this employer.").foregroundStyle(.secondary).font(.callout)
                }
                ForEach(periodShifts) { shiftRow($0) }
            }

            Section {
                Toggle("Mark resolved", isOn: $payslip.resolved)
            } footer: {
                Text("Tick when this payslip is sorted — paid right, or chased up.")
            }
        }
        .themedPane()
        .navigationTitle("Payslip")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            guard !loaded else { return }
            loaded = true
            actual = payslip.actualGross ?? 0
        }
        .onChange(of: actual) { _, v in
            payslip.actualGross = v > 0 ? v : nil
            try? modelContext.save()
        }
        .onChange(of: payslip.resolved) { _, _ in try? modelContext.save() }
    }

    private func summaryCard(_ r: ReconcileResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let payday = payslip.payday {
                Text("Payday \(payday.formatted(.dateTime.weekday().day().month().year()))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 18) {
                metric("Expected", r.expected.formatted(.currency(code: currency)), .secondary)
                if let delta = r.delta {
                    let short = delta < -0.005
                    metric(short ? "Short by" : delta > 0.005 ? "Over by" : "Matches",
                           abs(delta) < 0.005 ? "✓" : abs(delta).formatted(.currency(code: currency)),
                           short ? .red : delta > 0.005 ? .orange : .green)
                }
            }
            if r.flaggedShortfall > 0.005 {
                Text("You flagged \(r.flaggedShortfall.formatted(.currency(code: currency))) in unpaid or short shifts below.")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private func metric(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func shiftRow(_ inst: ShiftInstance) -> some View {
        let status = inst.paidStatus
        let expected = Reconcile.expectedPay(for: inst, calendar: calendar)
        return VStack(spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text((inst.localDate ?? .now), format: .dateTime.weekday(.abbreviated).day().month())
                        .font(.subheadline)
                    Text(inst.shiftType?.label ?? inst.shiftType?.code ?? inst.title ?? "Shift")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(expected, format: .currency(code: currency))
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                statusMenu(inst, status: status)
            }
            if status == .wrong {
                HStack {
                    Text("Actually paid").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    TextField("Amount", value: Binding(
                        get: { inst.actualPay ?? 0 },
                        set: { inst.actualPay = $0; try? modelContext.save() }
                    ), format: .currency(code: currency))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 110)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                }
            }
        }
    }

    private func statusMenu(_ inst: ShiftInstance, status: ShiftPaidStatus) -> some View {
        Menu {
            ForEach(ShiftPaidStatus.allCases) { s in
                Button {
                    inst.paidStatus = s
                    try? modelContext.save()
                } label: {
                    Label(s.label, systemImage: status == s ? "checkmark" : s.icon)
                }
            }
        } label: {
            Image(systemName: status.icon)
                .foregroundStyle(status.tint)
                .imageScale(.large)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
