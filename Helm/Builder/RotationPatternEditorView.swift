//
//  RotationPatternEditorView.swift
//  Helm
//
//  Build a repeating cycle: a list of day-slots, each a shift type or OFF.
//

import SwiftUI
import SwiftData

struct RotationPatternEditorView: View {
    @Environment(\.modelContext) private var context
    @Bindable var pattern: RotationPattern

    private var slots: [RotationSlot] {
        (pattern.slots ?? []).sorted { $0.sortIndex < $1.sortIndex }
    }

    var body: some View {
        Form {
            Section("Cycle") {
                TextField("Name (e.g. HMI 8-day)", text: Binding(
                    get: { pattern.name ?? "" },
                    set: { pattern.name = $0.isEmpty ? nil : $0 }
                ))
                Stepper("Length: \(pattern.cycleLengthDays) day\(pattern.cycleLengthDays == 1 ? "" : "s")",
                        value: Binding(
                            get: { pattern.cycleLengthDays },
                            set: { pattern.cycleLengthDays = max(1, $0); syncSlots() }
                        ), in: 1...90)
            }
            Section {
                ForEach(slots) { slot in
                    ShiftTypePickerMenu(allowOff: true, onPick: { type in
                        slot.shiftType = type
                        slot.isOff = (type == nil)
                        try? context.save()
                    }) {
                        HStack {
                            Text("Day \(slot.sortIndex + 1)")
                            Spacer()
                            slotLabel(slot)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                Text("Days")
            } footer: {
                Text("Tap a day to set its shift or mark it off. The cycle repeats from its start date.")
            }
        }
        .themedPane() // v7.1 wash
        .navigationTitle("Cycle")
        .onAppear { syncSlots() }
    }

    @ViewBuilder
    private func slotLabel(_ slot: RotationSlot) -> some View {
        if slot.isOff || slot.shiftType == nil {
            Text("Off").foregroundStyle(.secondary)
        } else if let t = slot.shiftType {
            ShiftTypeChip(label: t.code ?? t.label ?? "?", colorHex: t.colorHex)
        }
    }

    private func syncSlots() { syncRotationSlots(pattern, context: context) }
}
