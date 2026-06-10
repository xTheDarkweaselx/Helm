//
//  RosterRemindersSheet.swift
//  Helm
//
//  v4: per-roster reminder overrides. A roster either inherits the global
//  default (reminderOffsetsRaw == nil) or carries its own offsets ("" = none).
//  v7: in-window (a NavigationStack push, no modal sheet). Changes commit on
//  back/disappear, and the caller re-syncs existing events if anything changed.
//

import SwiftUI
import HelmDomain

struct RosterRemindersView: View {
    @Bindable var roster: Roster
    /// Called after a change is committed, so the caller can re-apply to events.
    let onSave: () -> Void

    @State private var useDefault = true
    @State private var selected: Set<Int> = []
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                Toggle("Use the default reminders", isOn: $useDefault)
            } footer: {
                Text("Default: \(ReminderSetting.summary(for: ReminderSetting.offsets)). Change it in Settings.")
            }
            // (summary is lowercase mid-sentence by design)

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
                         : "\(ReminderSetting.sentenceSummary(for: Array(selected))) — pick up to \(ReminderOffsets.maxCount).")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Reminders")
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
        .onDisappear { commit() }
    }

    private func binding(for minutes: Int) -> Binding<Bool> {
        Binding(
            get: { selected.contains(minutes) },
            set: { isOn in
                if isOn { selected.insert(minutes) } else { selected.remove(minutes) }
            }
        )
    }

    private func commit() {
        guard loaded else { return }
        let newRaw: String? = useDefault ? nil : ReminderOffsets.encode(Array(selected))
        let changed = newRaw != roster.reminderOffsetsRaw
        roster.reminderOffsetsRaw = newRaw
        if changed { onSave() }
    }
}
