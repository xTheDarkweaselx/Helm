//
//  RosterRemindersSheet.swift
//  Helm
//
//  v4: per-roster reminder overrides. A roster either inherits the global
//  default (reminderOffsetsRaw == nil) or carries its own offsets ("" = none).
//  Saving hands control back to the caller, which re-syncs existing events.
//

import SwiftUI
import HelmDomain

struct RosterRemindersSheet: View {
    @Bindable var roster: Roster
    /// Called after a change is saved, so the caller can re-apply to events.
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var useDefault = true
    @State private var selected: Set<Int> = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Use the default reminders", isOn: $useDefault)
                } footer: {
                    Text("Default: \(ReminderSetting.summary(for: ReminderSetting.offsets)). Change it in Settings.")
                }

                if !useDefault {
                    Section {
                        ForEach(ReminderSetting.presets, id: \.minutes) { preset in
                            Toggle(preset.label, isOn: binding(for: preset.minutes))
                                .disabled(!selected.contains(preset.minutes)
                                          && selected.count >= ReminderOffsets.maxCount)
                        }
                    } header: {
                        Text("Reminders for this roster")
                    } footer: {
                        Text(selected.isEmpty
                             ? "No reminders for this roster's shifts."
                             : "\(ReminderSetting.summary(for: Array(selected)).capitalized) — pick up to \(ReminderOffsets.maxCount).")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Reminders")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if let raw = roster.reminderOffsetsRaw {
                    useDefault = false
                    selected = Set(ReminderOffsets.parse(raw))
                } else {
                    useDefault = true
                    selected = Set(ReminderSetting.offsets)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 380)
        #endif
    }

    private func binding(for minutes: Int) -> Binding<Bool> {
        Binding(
            get: { selected.contains(minutes) },
            set: { isOn in
                if isOn { selected.insert(minutes) } else { selected.remove(minutes) }
            }
        )
    }

    private func save() {
        let newRaw: String? = useDefault ? nil : ReminderOffsets.encode(Array(selected))
        let changed = newRaw != roster.reminderOffsetsRaw
        roster.reminderOffsetsRaw = newRaw
        dismiss()
        if changed { onSave() }
    }
}
