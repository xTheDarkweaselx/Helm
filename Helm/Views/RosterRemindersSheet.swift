//
//  RosterRemindersSheet.swift
//  Helm
//
//  v4: per-roster reminder overrides. A roster either inherits the global
//  default (reminderOffsetsRaw == nil) or carries its own offsets ("" = none).
//  v7: in-window (a NavigationStack push, no modal sheet). Changes commit on
//  back/disappear, and the caller re-syncs existing events if anything changed.
//  v8.4: also the per-roster WAKE-UP ALARM lead override (presets + a custom
//  hours/minutes value). Editable on every platform — the iOS scheduler reads
//  the chosen value, so it can be set from the Mac and rings on the iPhone.
//

import SwiftUI
import SwiftData
import HelmDomain

struct RosterRemindersView: View {
    @Bindable var roster: Roster
    /// Called after a reminder change is committed, so the caller can re-apply to events.
    let onSave: () -> Void

    @Environment(\.modelContext) private var modelContext

    // Calendar reminders.
    @State private var useDefault = true
    @State private var selected: Set<Int> = []
    // Wake-up alarm lead.
    @State private var useDefaultAlarm = true
    @State private var leadSelection: LeadSelection = .preset(ShiftAlarmSetting.defaultLeadMinutes)
    @State private var customHours = 1
    @State private var customMinutes = 0

    @State private var loaded = false

    /// A roster's chosen lead is either a quick-pick preset or a custom hh:mm.
    private enum LeadSelection: Hashable {
        case preset(Int)
        case custom
    }

    /// The lead (minutes) the alarm section currently represents.
    private var chosenLead: Int {
        switch leadSelection {
        case .preset(let minutes): return minutes
        case .custom: return customHours * 60 + customMinutes
        }
    }

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

            alarmSection
        }
        .formStyle(.grouped)
        .themedPane() // v7.1 wash (iOS; passthrough on macOS)
        .navigationTitle("Reminders & alarm")
        .onAppear {
            guard !loaded else { return }
            loaded = true
            loadReminders()
            loadAlarm()
        }
        .onDisappear { commit() }
    }

    // MARK: - Wake-up alarm

    @ViewBuilder
    private var alarmSection: some View {
        Section {
            Toggle("Use the default alarm timing", isOn: $useDefaultAlarm)
            if !useDefaultAlarm {
                Picker("Alarm before shift", selection: $leadSelection) {
                    ForEach(ShiftAlarmSetting.leadChoices, id: \.self) { minutes in
                        Text(ShiftAlarmSetting.label(forLead: minutes)).tag(LeadSelection.preset(minutes))
                    }
                    Text("Custom…").tag(LeadSelection.custom)
                }
                if leadSelection == .custom {
                    Stepper("Hours: \(customHours)", value: $customHours, in: 0...24)
                    Stepper("Minutes: \(customMinutes)", value: $customMinutes, in: 0...55, step: 5)
                }
            }
        } header: {
            Text("Wake-up alarm")
        } footer: {
            Text(alarmFooter)
        }
    }

    private var alarmFooter: String {
        if useDefaultAlarm {
            return "Inherits the default wake-up timing — \(ShiftAlarmSetting.label(forLead: ShiftAlarmSetting.leadMinutes)) before each shift. The default and the on/off switch live in Settings on your iPhone."
        }
        // A 0 lead means "ring at the shift's start" — drop the "before" clause so
        // it doesn't read "at shift start before each shift".
        let when = chosenLead == 0
            ? "right at each timed shift's start"
            : "\(ShiftAlarmSetting.label(forLead: chosenLead)) before each timed shift"
        return "A real alarm \(when) in this roster. Rings on your iPhone (iOS 26+) through Silent mode and Sleep Focus, like a Clock alarm."
    }

    // MARK: - Load / commit

    private func loadReminders() {
        if let raw = roster.reminderOffsetsRaw {
            useDefault = false
            selected = Set(ReminderOffsets.parse(raw))
        } else {
            useDefault = true
            selected = Set(ReminderSetting.offsets)
        }
    }

    private func loadAlarm() {
        // Seed the editor from the roster's override, or from the global default
        // (so flipping "use default" off starts at a sensible value).
        let seed = roster.alarmLeadMinutesOverride ?? ShiftAlarmSetting.leadMinutes
        useDefaultAlarm = (roster.alarmLeadMinutesOverride == nil)
        if ShiftAlarmSetting.leadChoices.contains(seed) {
            leadSelection = .preset(seed)
        } else {
            leadSelection = .custom
        }
        customHours = seed / 60
        customMinutes = (seed % 60) - (seed % 60) % 5 // snap to the 5-min stepper grid
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

        // Calendar reminders — re-sync existing events if they changed.
        let newRaw: String? = useDefault ? nil : ReminderOffsets.encode(Array(selected))
        let remindersChanged = newRaw != roster.reminderOffsetsRaw
        roster.reminderOffsetsRaw = newRaw
        if remindersChanged { onSave() }

        // Wake-up alarm lead — reschedule alarms (iOS) if it changed.
        let newLead: Int? = useDefaultAlarm ? nil : max(0, chosenLead)
        let alarmChanged = newLead != roster.alarmLeadMinutesOverride
        roster.alarmLeadMinutesOverride = newLead
        if alarmChanged { SnapshotWriter.refresh(context: modelContext) }
    }
}
