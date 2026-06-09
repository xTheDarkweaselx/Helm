//
//  SettingsView.swift
//  Helm
//
//  One SettingsForm, three homes: a sidebar destination (all platforms), the
//  macOS ⌘, Settings window, and an iOS sheet wrapper. Grouped form style +
//  popup pickers so labels and footers never clip on macOS.
//

import SwiftUI
import SwiftData

/// iOS/iPadOS sheet wrapper (kept for any modal presentation).
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsForm()
                .navigationTitle("Settings")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}

/// The actual settings content. Embedded in the sidebar's detail pane, the
/// macOS Settings window, and the iOS sheet.
struct SettingsForm: View {
    @AppStorage(ReminderSetting.key) private var reminderMinutes: Int = ReminderSetting.fallback
    @AppStorage(CalendarDestinationSetting.key) private var destinationRaw: String = CalendarTargetKind.eventkit.rawValue
    @AppStorage(GoogleConfig.defaultsKey) private var googleClientID: String = ""
    @AppStorage(GoogleConfig.signedInDefaultsKey) private var googleSignedIn: Bool = false
    @AppStorage(GoogleConfig.accountEmailDefaultsKey) private var googleEmail: String = ""
    @Query private var importProfiles: [ImportProfile]

    @State private var isSigningIn = false
    @State private var authMessage: String?
    @State private var isConfirmingSignOut = false

    private var googleUsable: Bool { GoogleConfig.isConfigured && googleSignedIn }
    /// Rosters whose events currently live in Google (sign-out makes them unmanageable).
    private var googleRosterCount: Int {
        importProfiles.filter { $0.target == .google }.count
    }

    var body: some View {
        Form {
            Section {
                Picker("Remind me", selection: $reminderMinutes) {
                    ForEach(ReminderSetting.presets, id: \.minutes) { preset in
                        Text(preset.label).tag(preset.minutes)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Shift reminder")
            } footer: {
                Text("Applied to shifts as you import them. To update shifts already in your calendar, open a roster and choose “Apply reminders to all shifts”.")
            }

            Section {
                Picker("Add shifts to", selection: $destinationRaw) {
                    Text("Apple Calendar").tag(CalendarTargetKind.eventkit.rawValue)
                    if GoogleConfig.isConfigured {
                        // Always present once configured (a selected-but-removed
                        // tag would blank the picker after sign-out); selectable
                        // only while actually signed in.
                        Text("Google Calendar")
                            .tag(CalendarTargetKind.google.rawValue)
                            .selectionDisabled(!googleUsable)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Calendar destination")
            } footer: {
                if destinationRaw == CalendarTargetKind.google.rawValue && !googleUsable {
                    Text("Google is signed out — shifts go to Apple Calendar until you sign in again below.")
                        .foregroundStyle(.orange)
                } else if googleUsable {
                    Text("Each roster remembers where its shifts were written, so re-importing after switching moves them to the new destination.")
                } else {
                    Text("Google Calendar appears here once it's set up and you're signed in below.")
                }
            }

            googleSection
        }
        .formStyle(.grouped)
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
                    if googleRosterCount > 0 {
                        isConfirmingSignOut = true
                    } else {
                        signOut()
                    }
                }
                .confirmationDialog(
                    "\(googleRosterCount) roster\(googleRosterCount == 1 ? " has" : "s have") shifts in this Google account. After signing out, Helm can't update or remove them until you sign in again.",
                    isPresented: $isConfirmingSignOut,
                    titleVisibility: .visible
                ) {
                    Button("Sign out anyway", role: .destructive) { signOut() }
                    Button("Cancel", role: .cancel) {}
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

    private func signOut() {
        Task {
            await GoogleAuthService.shared.signOut()
            // Writes fall back to Apple Calendar automatically (footer explains).
            authMessage = "Signed out of Google."
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
