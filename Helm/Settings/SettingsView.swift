//
//  SettingsView.swift
//  Helm
//

import SwiftUI

struct SettingsView: View {
    @AppStorage(ReminderSetting.key) private var reminderMinutes: Int = ReminderSetting.fallback
    @AppStorage(CalendarDestinationSetting.key) private var destinationRaw: String = CalendarTargetKind.eventkit.rawValue
    @AppStorage(GoogleConfig.defaultsKey) private var googleClientID: String = ""
    @AppStorage(GoogleConfig.signedInDefaultsKey) private var googleSignedIn: Bool = false
    @AppStorage(GoogleConfig.accountEmailDefaultsKey) private var googleEmail: String = ""
    @Environment(\.dismiss) private var dismiss

    @State private var isSigningIn = false
    @State private var authMessage: String?

    private var googleUsable: Bool { GoogleConfig.isConfigured && googleSignedIn }

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

                Section {
                    Picker("Add shifts to", selection: $destinationRaw) {
                        Text("Apple Calendar").tag(CalendarTargetKind.eventkit.rawValue)
                        if googleUsable {
                            Text("Google Calendar").tag(CalendarTargetKind.google.rawValue)
                        }
                    }
                } header: {
                    Text("Calendar destination")
                } footer: {
                    Text(googleUsable
                         ? "Each roster remembers where its shifts were written, so re-importing after switching moves them to the new destination."
                         : "Google Calendar appears here once it's set up and you're signed in below.")
                }

                googleSection
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    @ViewBuilder
    private var googleSection: some View {
        Section {
            if !GoogleConfig.isConfigured {
                TextField("OAuth client ID (…apps.googleusercontent.com)", text: $googleClientID, axis: .vertical)
                    .font(.caption.monospaced())
                    .autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.asciiCapable)
                #endif
                if !googleClientID.isEmpty {
                    Label("That doesn't look like a client ID yet — it should end in .apps.googleusercontent.com",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else if googleSignedIn {
                LabeledContent("Account", value: googleEmail.isEmpty ? "Signed in" : googleEmail)
                Button("Sign out", role: .destructive) {
                    Task {
                        await GoogleAuthService.shared.signOut()
                        // Writes fall back to Apple Calendar automatically.
                        authMessage = "Signed out of Google."
                    }
                }
            } else {
                Button {
                    signIn()
                } label: {
                    if isSigningIn {
                        ProgressView()
                    } else {
                        Label("Sign in with Google", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
                .disabled(isSigningIn)
            }
            if let authMessage {
                Text(authMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Google Calendar")
        } footer: {
            if !GoogleConfig.isConfigured {
                Text("To connect Google Calendar, create a free Google Cloud OAuth client ID (type “iOS”, bundle ID Fusion-Studios.Helm) and paste it here. Helm only ever touches a “Helm Shifts” calendar it creates — never your other calendars.")
            } else {
                Text("Helm writes to its own “Helm Shifts” calendar in your Google account — never your other calendars.")
            }
        }
    }

    private func signIn() {
        isSigningIn = true
        authMessage = nil
        Task {
            defer { isSigningIn = false }
            do {
                try await GoogleAuthService.shared.signIn()
                let email = await GoogleAuthService.shared.accountEmail()
                authMessage = email.map { "Signed in as \($0)." } ?? "Signed in."
            } catch WebAuthError.cancelled {
                authMessage = nil // user backed out; not an error
            } catch {
                authMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
