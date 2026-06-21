//
//  TimeOffEditorView.swift
//  Helm
//
//  v7: edit one time-off / leave entry in-window. Direct @Bindable editing,
//  auto-commit on back; the date range is kept sane (end ≥ start).
//

import SwiftUI
import SwiftData
import HelmDomain

struct TimeOffEditorView: View {
    @Environment(\.modelContext) private var context
    @Bindable var timeOff: TimeOff

    private var today: Date { Calendar.current.startOfDay(for: .now) }

    var body: some View {
        Form {
            Section("Dates") {
                DatePicker("From", selection: dateBinding($timeOff.startDate, default: today), displayedComponents: .date)
                DatePicker("To", selection: dateBinding($timeOff.endDate, default: today), displayedComponents: .date)
            }

            Section("Type") {
                Picker("Type", selection: Binding(get: { timeOff.kind }, set: { timeOff.kind = $0 })) {
                    ForEach(LeaveKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Paid", isOn: $timeOff.paid)
            }

            Section {
                Toggle("Credit hours per day", isOn: hasHoursBinding)
                if timeOff.hoursPerDay != nil {
                    HStack {
                        Text("Hours per day")
                        Spacer()
                        TextField("0", value: $timeOff.hoursPerDay, format: .number.precision(.fractionLength(0...2)))
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 80)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                    }
                }
            } footer: {
                Text("Optional. Used for the leave-hours total on the Planning screen.")
            }

            Section("Details") {
                TextField("Title (optional)", text: optBinding(\.title))
                TextField("Notes (optional)", text: optBinding(\.note), axis: .vertical)
                    .lineLimit(1...4)
            }
        }
        .formStyle(.grouped)
        .themedPane() // v7.1 wash (iOS; passthrough on macOS)
        .navigationTitle(timeOff.title?.isEmpty == false ? timeOff.title! : timeOff.kind.displayName)
        .onDisappear { commit() }
    }

    private var hasHoursBinding: Binding<Bool> {
        Binding(get: { timeOff.hoursPerDay != nil },
                set: { timeOff.hoursPerDay = $0 ? (timeOff.hoursPerDay ?? 7.5) : nil })
    }

    private func optBinding(_ kp: ReferenceWritableKeyPath<TimeOff, String?>) -> Binding<String> {
        Binding(get: { timeOff[keyPath: kp] ?? "" }, set: { timeOff[keyPath: kp] = $0.isEmpty ? nil : $0 })
    }

    private func commit() {
        // Keep the range sane.
        if let s = timeOff.startDate, let e = timeOff.endDate, e < s {
            timeOff.endDate = s
        }
        try? context.save()
    }
}
