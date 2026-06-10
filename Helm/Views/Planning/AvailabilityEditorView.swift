//
//  AvailabilityEditorView.swift
//  Helm
//
//  v7: edit a recurring weekly availability rule, or a one-off availability
//  window, in-window. @Bindable, auto-commit on back.
//

import SwiftUI
import SwiftData
import HelmDomain

// MARK: - Recurring weekly rule

struct AvailabilityRuleEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.helmAccent) private var accent
    @Bindable var rule: AvailabilityRule

    private var today: Date { Calendar.current.startOfDay(for: .now) }

    var body: some View {
        Form {
            Section {
                Picker("Status", selection: Binding(get: { rule.kind }, set: { rule.kind = $0 })) {
                    ForEach(AvailabilityKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(rule.kind == .unavailable
                     ? "Shifts overlapping this time on these days are flagged as clashes."
                     : "Marks when you prefer to work; shown on the calendar.")
            }

            Section("Days") {
                weekdayPicker
            }

            Section("Time") {
                DatePicker("From", selection: timeOfDayBinding($rule.startMinuteOfDay), displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: timeOfDayBinding($rule.endMinuteOfDay), displayedComponents: .hourAndMinute)
            }

            Section {
                Toggle("Limit to a date range", isOn: boundedBinding)
                if rule.effectiveFrom != nil || rule.effectiveTo != nil {
                    DatePicker("Starts", selection: dateBinding($rule.effectiveFrom, default: today), displayedComponents: .date)
                    DatePicker("Ends", selection: dateBinding($rule.effectiveTo, default: today), displayedComponents: .date)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Weekly Availability")
        .onDisappear {
            // A weekly rule with no weekdays can never match — drop an abandoned
            // blank one rather than CloudKit-syncing junk.
            if rule.weekdays.isEmpty { context.delete(rule) }
            try? context.save()
        }
    }

    private var weekdayPicker: some View {
        let symbols = Calendar.current.shortWeekdaySymbols
        let ordered = (0..<7).map { ((Calendar.current.firstWeekday - 1 + $0) % 7) + 1 }
        return HStack(spacing: 6) {
            ForEach(ordered, id: \.self) { wd in
                let on = rule.weekdays.contains(wd)
                Button {
                    var days = rule.weekdays
                    if on { days.remove(wd) } else { days.insert(wd) }
                    rule.weekdays = days
                } label: {
                    Text(symbols[wd - 1].prefix(2))
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(on ? accent.opacity(0.25) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(on ? accent : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var boundedBinding: Binding<Bool> {
        Binding(
            get: { rule.effectiveFrom != nil || rule.effectiveTo != nil },
            set: { on in
                if on {
                    rule.effectiveFrom = rule.effectiveFrom ?? today
                    rule.effectiveTo = rule.effectiveTo ?? today
                } else {
                    rule.effectiveFrom = nil
                    rule.effectiveTo = nil
                }
            }
        )
    }
}

// MARK: - One-off window

struct AvailabilityWindowEditorView: View {
    @Environment(\.modelContext) private var context
    @Bindable var window: AvailabilityWindow

    private var today: Date { Calendar.current.startOfDay(for: .now) }

    var body: some View {
        Form {
            Section {
                Picker("Status", selection: Binding(get: { window.kind }, set: { window.kind = $0 })) {
                    ForEach(AvailabilityKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("When") {
                DatePicker("Date", selection: dateBinding(Binding(get: { window.localDate }, set: { window.localDate = $0 }), default: today), displayedComponents: .date)
                Toggle("All day", isOn: $window.allDay)
                if !window.allDay {
                    DatePicker("From", selection: timeOfDayBinding($window.startMinuteOfDay), displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: timeOfDayBinding($window.endMinuteOfDay), displayedComponents: .hourAndMinute)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("One-off Availability")
        .onDisappear { try? context.save() }
    }
}
