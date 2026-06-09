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
    @State private var pickingSlot: RotationSlot?

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
                    Button { pickingSlot = slot } label: {
                        HStack {
                            Text("Day \(slot.sortIndex + 1)")
                            Spacer()
                            slotLabel(slot)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Days")
            } footer: {
                Text("Tap a day to set its shift or mark it off. The cycle repeats from its start date.")
            }
        }
        .navigationTitle("Cycle")
        .onAppear { syncSlots() }
        .sheet(item: $pickingSlot) { slot in
            ShiftTypePickerSheet { type in
                slot.shiftType = type
                slot.isOff = (type == nil)
                try? context.save()
            }
        }
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

struct ShiftTypePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \ShiftType.code) private var types: [ShiftType]
    var allowOff: Bool = true
    let onPick: (ShiftType?) -> Void

    var body: some View {
        NavigationStack {
            List {
                if allowOff {
                    Button { onPick(nil); dismiss() } label: {
                        Label("Off", systemImage: "moon.zzz")
                    }
                }
                Section("Shift types") {
                    if types.isEmpty {
                        Text("No shift types yet. Add some in Shift Types first.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(types) { type in
                        Button { onPick(type); dismiss() } label: {
                            HStack {
                                ShiftTypeChip(label: type.code ?? type.label ?? "?", colorHex: type.colorHex)
                                Text(type.label ?? type.code ?? "Shift").foregroundStyle(.primary)
                                Spacer()
                                if type.workKind != .off {
                                    Text("\(hhmmString(type.startMinuteOfDay))–\(hhmmString(type.endMinuteOfDay))")
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Choose shift")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
