//
//  PlanningView.swift
//  Helm
//
//  v7 planning hub: leave balance, time-off entries, and availability (recurring
//  weekly rules + one-off windows). Editors are pushed in-window (no sheets).
//

import SwiftUI
import SwiftData
import HelmDomain

struct PlanningView: View {
    /// Jump to the quick-add-shift screen (owned by ContentView).
    var quickAdd: () -> Void

    @Environment(\.modelContext) private var context
    @Query(sort: \TimeOff.startDate, order: .reverse) private var timeOffs: [TimeOff]
    @Query(sort: \AvailabilityRule.createdAt) private var rules: [AvailabilityRule]
    @Query(sort: \AvailabilityWindow.localDate) private var windows: [AvailabilityWindow]

    @State private var editingTimeOff: TimeOff?
    @State private var editingRule: AvailabilityRule?
    @State private var editingWindow: AvailabilityWindow?

    private var calendar: Calendar { CalendarViewModel.displayCalendar }
    private var today: Date { Calendar.current.startOfDay(for: .now) }

    var body: some View {
        List {
            balanceSection
            timeOffSection
            weeklySection
            oneOffSection
            Section {
                Button("Quick add a shift", systemImage: "calendar.badge.plus", action: quickAdd)
            } footer: {
                Text("Adds a single shift to your calendar without importing a file or building a schedule.")
            }
        }
        .themedPane() // v7.1 wash
        .navigationTitle("Planning")
        .navigationDestination(item: $editingTimeOff) { TimeOffEditorView(timeOff: $0) }
        .navigationDestination(item: $editingRule) { AvailabilityRuleEditorView(rule: $0) }
        .navigationDestination(item: $editingWindow) { AvailabilityWindowEditorView(window: $0) }
    }

    // MARK: Leave balance

    @ViewBuilder
    private var balanceSection: some View {
        let summary = leaveSummary()
        if summary.totalDays > 0 {
            Section {
                HStack(spacing: 16) {
                    balanceStat("This year", "\(summary.totalDays)d", "booked")
                    balanceStat("Paid", "\(summary.paidDays)d", "leave")
                    if summary.hours > 0 {
                        balanceStat("Hours", summary.hours.formatted(.number.precision(.fractionLength(0...1))), "credited")
                    }
                }
                if !summary.byKind.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(summary.byKind, id: \.kind) { kc in
                            Text("\(kc.kind.displayName): \(kc.days)d")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if kc.kind != summary.byKind.last?.kind { Text("·").foregroundStyle(.tertiary) }
                        }
                    }
                }
            } header: {
                Text("Leave balance")
            }
        }
    }

    private func balanceStat(_ title: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.bold)).monospacedDigit()
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func leaveSummary() -> LeaveAccumulator.LeaveSummary {
        let now = Date.now
        let year = calendar.component(.year, from: now)
        let range = DayKey(year: year, month: 1, day: 1)...DayKey(year: year, month: 12, day: 31)
        let entries: [LeaveEntry] = timeOffs.compactMap { to in
            guard let s = to.startDate, let e = to.endDate else { return nil }
            return LeaveEntry(id: to.id,
                              start: DayKey(containing: s, in: calendar),
                              end: DayKey(containing: e, in: calendar),
                              kind: to.kind, paid: to.paid, hoursPerDay: to.hoursPerDay)
        }
        return LeaveAccumulator.summary(entries, in: range, calendar: calendar)
    }

    // MARK: Time off

    @ViewBuilder
    private var timeOffSection: some View {
        Section {
            ForEach(timeOffs) { to in
                Button { editingTimeOff = to } label: { timeOffRow(to) }
                    .buttonStyle(.plain)
            }
            .onDelete { offsets in
                for i in offsets { context.delete(timeOffs[i]) }
                try? context.save()
            }
            Button("Add time off", systemImage: "plus") {
                let to = TimeOff(startDate: today, endDate: today, kind: .annual, paid: true)
                context.insert(to)
                try? context.save()
                editingTimeOff = to
            }
        } header: {
            Text("Time off")
        } footer: {
            if timeOffs.isEmpty {
                Text("Record holidays, sick days and other leave. They show as bands on your calendar.")
            }
        }
    }

    private func timeOffRow(_ to: TimeOff) -> some View {
        HStack {
            Image(systemName: icon(for: to.kind)).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(to.title?.isEmpty == false ? to.title! : to.kind.displayName)
                Text(dateRangeText(to)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !to.paid { Text("Unpaid").font(.caption2).foregroundStyle(.orange) }
        }
    }

    private func dateRangeText(_ to: TimeOff) -> String {
        guard let s = to.startDate, let e = to.endDate else { return "—" }
        if calendar.isDate(s, inSameDayAs: e) {
            return s.formatted(.dateTime.weekday().day().month().year())
        }
        return "\(s.formatted(.dateTime.day().month())) – \(e.formatted(.dateTime.day().month().year()))"
    }

    private func icon(for kind: LeaveKind) -> String {
        switch kind {
        case .annual: "sun.max"
        case .sick: "cross.case"
        case .unpaid: "minus.circle"
        case .publicHoliday: "flag"
        case .other: "calendar"
        }
    }

    // MARK: Weekly availability

    @ViewBuilder
    private var weeklySection: some View {
        Section {
            ForEach(rules) { rule in
                Button { editingRule = rule } label: { ruleRow(rule) }
                    .buttonStyle(.plain)
            }
            .onDelete { offsets in
                for i in offsets { context.delete(rules[i]) }
                try? context.save()
            }
            Button("Add weekly rule", systemImage: "plus") {
                let rule = AvailabilityRule(kind: .unavailable, weekdays: [])
                context.insert(rule)
                try? context.save()
                editingRule = rule
            }
        } header: {
            Text("Weekly availability")
        } footer: {
            if rules.isEmpty {
                Text("Mark times you can't work, e.g. “Mondays before noon”. Clashing shifts get flagged.")
            }
        }
    }

    private func ruleRow(_ rule: AvailabilityRule) -> some View {
        HStack {
            Image(systemName: rule.kind == .unavailable ? "nosign" : "checkmark.circle")
                .foregroundStyle(rule.kind == .unavailable ? .orange : .green)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(weekdaysText(rule.weekdays))
                Text("\(rule.kind.displayName) · \(hhmmString(rule.startMinuteOfDay))–\(hhmmString(rule.endMinuteOfDay))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: One-off availability

    @ViewBuilder
    private var oneOffSection: some View {
        Section {
            ForEach(windows) { window in
                Button { editingWindow = window } label: { windowRow(window) }
                    .buttonStyle(.plain)
            }
            .onDelete { offsets in
                for i in offsets { context.delete(windows[i]) }
                try? context.save()
            }
            Button("Add one-off", systemImage: "plus") {
                let window = AvailabilityWindow(kind: .unavailable, localDate: today, allDay: true)
                context.insert(window)
                try? context.save()
                editingWindow = window
            }
        } header: {
            Text("One-off availability")
        }
    }

    private func windowRow(_ window: AvailabilityWindow) -> some View {
        HStack {
            Image(systemName: window.kind == .unavailable ? "nosign" : "checkmark.circle")
                .foregroundStyle(window.kind == .unavailable ? .orange : .green)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(window.localDate?.formatted(.dateTime.weekday().day().month().year()) ?? "—")
                Text(window.allDay ? "\(window.kind.displayName) · all day"
                     : "\(window.kind.displayName) · \(hhmmString(window.startMinuteOfDay))–\(hhmmString(window.endMinuteOfDay))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func weekdaysText(_ days: Set<Int>) -> String {
        guard !days.isEmpty else { return "No days" }
        let symbols = Calendar.current.shortWeekdaySymbols
        let ordered = (0..<7).map { ((Calendar.current.firstWeekday - 1 + $0) % 7) + 1 }
        return ordered.filter { days.contains($0) }.map { symbols[$0 - 1] }.joined(separator: " ")
    }
}
