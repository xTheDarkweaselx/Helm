//
//  SettingsView.swift
//  Helm
//

import SwiftUI

struct SettingsView: View {
    @AppStorage(ReminderSetting.key) private var reminderMinutes: Int = ReminderSetting.fallback
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Remind me", selection: $reminderMinutes) {
                        ForEach(ReminderSetting.presets, id: \.minutes) { preset in
                            Text(preset.label).tag(preset.minutes)
                        }
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text("Default shift reminder")
                } footer: {
                    Text("Applied to shifts as you import them. To update shifts already in your calendar, open a roster and choose “Apply reminders to all shifts”.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
