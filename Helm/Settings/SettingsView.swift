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
import UniformTypeIdentifiers
import HelmDomain
import HelmCalendar // CalendarTarget.removeAll (MemberImportVisibility: the using file must import the defining module)

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
    /// Backed by the canonical UserDefaults key (NOT a @State snapshot): the
    /// macOS ⌘, Settings window and the sidebar Settings pane can be alive at
    /// once, and snapshots would silently revert each other's changes.
    @AppStorage(ReminderSetting.offsetsKey) private var reminderOffsetsCSV: String = ReminderOffsets.encode(ReminderSetting.fallback)
    @AppStorage(CalendarDestinationSetting.key) private var destinationsCSV: String = CalendarTargetKind.eventkit.rawValue
    @AppStorage(GoogleConfig.defaultsKey) private var googleClientID: String = ""
    @AppStorage(GoogleConfig.signedInDefaultsKey) private var googleSignedIn: Bool = false
    @AppStorage(GoogleConfig.accountEmailDefaultsKey) private var googleEmail: String = ""
    @AppStorage("hourlyRate") private var hourlyRate: Double = 0
    // v8 Pay
    @AppStorage(PaySettings.overtimeEnabledKey) private var payOvertimeEnabled: Bool = false
    @AppStorage(PaySettings.overtimeThresholdKey) private var payOvertimeThreshold: Double = PaySettings.defaultThreshold
    @AppStorage(PaySettings.overtimeMultiplierKey) private var payOvertimeMultiplier: Double = PaySettings.defaultMultiplier
    @AppStorage(PaySettings.taxYearPresetKey) private var payTaxYearPreset: String = "uk"
    // v7.6: App Lock + wake-up alarms (both iOS only).
    #if os(iOS)
    @AppStorage(AppLockSetting.enabledKey) private var requireAppLock: Bool = false
    @AppStorage(ShiftAlarmSetting.enabledKey) private var shiftAlarmsEnabled: Bool = false
    @AppStorage(ShiftAlarmSetting.leadMinutesKey) private var shiftAlarmLead: Int = ShiftAlarmSetting.defaultLeadMinutes
    #endif
    // All-platform (data export needs it on macOS too). Named `dataContext`, not
    // `modelContext`: a `modelContext` property on a View collides with the
    // `View.modelContext(_:)` modifier and the bare name resolves to the
    // (curried) modifier instead of this property.
    @Environment(\.modelContext) private var dataContext
    @Query private var importProfiles: [ImportProfile]

    @State private var isSigningIn = false
    @State private var authMessage: String?
    @State private var isConfirmingSignOut = false
    @FocusState private var rateFieldFocused: Bool
    @State private var removeAllCandidate: CalendarTargetKind?
    @State private var isCleaningUp = false
    @State private var cleanupMessage: String?
    /// Built once when "Export my data" is tapped (not on every render).
    @State private var isExportingData = false
    @State private var exportText = ""

    private var googleUsable: Bool { GoogleConfig.isConfigured && googleSignedIn }
    private var reminderOffsets: Set<Int> { Set(ReminderOffsets.parse(reminderOffsetsCSV)) }
    private var chosenDestinations: Set<CalendarTargetKind> {
        let kinds = CalendarDestinationSetting.parse(destinationsCSV)
        return kinds.isEmpty ? [.eventkit] : kinds
    }
    /// Rosters whose events currently live in Google (sign-out makes them unmanageable).
    private var googleRosterCount: Int {
        importProfiles.filter { $0.targets.contains(.google) }.count
    }
    /// Human label for an alarm lead time, e.g. "30 min", "1 hr", "1.5 hr".
    private func leadLabel(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let hours = Double(minutes) / 60
        return hours == hours.rounded() ? "\(Int(hours)) hr" : String(format: "%.1f hr", hours)
    }

    var body: some View {
        Form {
            Section {
                ForEach(ReminderSetting.presets, id: \.minutes) { preset in
                    Toggle(preset.label, isOn: reminderBinding(for: preset.minutes))
                        .disabled(!reminderOffsets.contains(preset.minutes)
                                  && reminderOffsets.count >= ReminderOffsets.maxCount)
                }
            } header: {
                Text("Default shift reminders")
            } footer: {
                Text("\(reminderOffsets.isEmpty ? "No reminders" : ReminderSetting.sentenceSummary(for: Array(reminderOffsets))) — pick up to \(ReminderOffsets.maxCount). Applied to shifts as you import them; a roster can override this from its own page. To update shifts already in your calendar, open a roster and choose “Re-sync all shifts to calendar”.")
            }

            Section {
                Toggle("Apple Calendar", isOn: destinationBinding(for: .eventkit))
                if GoogleConfig.isConfigured {
                    Toggle("Google Calendar", isOn: destinationBinding(for: .google))
                        .disabled(!googleUsable && !chosenDestinations.contains(.google))
                }
            } header: {
                Text("Calendar destinations")
            } footer: {
                if chosenDestinations.contains(.google) && !googleUsable {
                    Text("Google is signed out — shifts go only to Apple Calendar until you sign in again below.")
                        .foregroundStyle(.orange)
                } else if chosenDestinations.count > 1 {
                    Text("New and updated shifts are written to BOTH calendars. Each roster remembers where its shifts live, so re-applying moves them when you change this.")
                } else if googleUsable {
                    Text("Each roster remembers where its shifts were written, so re-importing after switching moves them to the new destination.")
                } else {
                    Text("Google Calendar appears here once it's set up and you're signed in below.")
                }
            }

            Section {
                LabeledContent("Hourly rate") {
                    HStack(spacing: 2) {
                        Text(Locale.current.currencySymbol ?? "£").foregroundStyle(.secondary)
                        TextField("Hourly rate", value: $hourlyRate, format: .number.precision(.fractionLength(0...2)))
                            .labelsHidden() // otherwise the title renders next to the value ("0  0")
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 60)
                            .focused($rateFieldFocused)
                            #if os(iOS)
                            // The decimal pad has no Return key — this toolbar
                            // is the only way to dismiss it.
                            .keyboardType(.decimalPad)
                            .toolbar {
                                ToolbarItemGroup(placement: .keyboard) {
                                    Spacer()
                                    Button("Done") { rateFieldFocused = false }
                                }
                            }
                            #endif
                    }
                }
                Toggle("Overtime", isOn: $payOvertimeEnabled)
                if payOvertimeEnabled {
                    Stepper(value: $payOvertimeThreshold, in: 1...100, step: 1) {
                        LabeledContent("Over", value: "\(Int(payOvertimeThreshold)) h / week")
                    }
                    Picker("Overtime rate", selection: $payOvertimeMultiplier) {
                        Text("1.25×").tag(1.25)
                        Text("1.5×").tag(1.5)
                        Text("2×").tag(2.0)
                    }
                }
                Picker("Tax year starts", selection: $payTaxYearPreset) {
                    Text("6 April (UK)").tag("uk")
                    Text("1 January").tag("calendar")
                }
            } header: {
                Text("Pay")
            } footer: {
                Text("Set your hourly rate to unlock the Timesheet — gross pay, weekly/monthly/tax-year totals, and CSV export — plus the Overview pay card. Figures are before tax.")
            }

            #if os(iOS)
            Section {
                Toggle("Require \(AppLockSetting.biometryLabel)", isOn: $requireAppLock)
                    .disabled(!AppLockSetting.canAuthenticate)
            } header: {
                Text("App Lock")
            } footer: {
                if AppLockSetting.canAuthenticate {
                    Text("Lock Helm with \(AppLockSetting.biometryLabel) (or your device passcode) on launch and when you return to it, so only you can open your schedule.")
                } else {
                    Text("Set up Face ID, Touch ID, or a device passcode first to lock Helm.")
                }
            }

            // Wake-up alarms use AlarmKit (iOS 26+); the Section hides itself on
            // older systems rather than presenting a toggle that does nothing.
            if #available(iOS 26.0, *) {
                Section {
                    Toggle("Wake me up for shifts", isOn: $shiftAlarmsEnabled)
                    if shiftAlarmsEnabled {
                        Picker("Alarm before shift", selection: $shiftAlarmLead) {
                            ForEach(ShiftAlarmSetting.leadChoices, id: \.self) { mins in
                                Text(leadLabel(mins)).tag(mins)
                            }
                        }
                    }
                } header: {
                    Text("Wake-up alarms")
                } footer: {
                    Text("Sets a real alarm \(leadLabel(shiftAlarmLead)) before each upcoming timed shift. Like a Clock alarm it rings through Silent mode and Focus — including Sleep. Apple doesn't let apps change your Sleep schedule's wake-up alarm, so this is Helm's own alarm.")
                }
                .onChange(of: shiftAlarmsEnabled) { _, on in
                    if on {
                        SnapshotWriter.refresh(context: dataContext)
                    } else {
                        Task { await ShiftAlarmScheduler.shared.cancelAll() }
                    }
                }
                .onChange(of: shiftAlarmLead) { _, _ in
                    UserDefaults.standard.removeObject(forKey: ShiftAlarmSetting.signatureKey)
                    SnapshotWriter.refresh(context: dataContext)
                }
            }
            #endif

            ThemePickerSection()

            googleSection

            dataSection

            cleanupSection
        }
        .formStyle(.grouped)
        .themedPane() // v7.1 wash (iOS; passthrough on macOS)
        .fileExporter(isPresented: $isExportingData,
                      document: JSONDataFile(text: exportText),
                      contentType: .json,
                      defaultFilename: "Helm data export") { _ in }
        // Run the legacy single-value migrations so the new keys exist before
        // the @AppStorage defaults mask them.
        .onAppear {
            _ = ReminderSetting.offsets
            _ = CalendarDestinationSetting.chosenKinds
        }
    }

    // MARK: - Data export (v8.2: GDPR data portability)

    @ViewBuilder
    private var dataSection: some View {
        Section {
            Button("Export my data…", systemImage: "square.and.arrow.up", action: exportData)
        } header: {
            Text("Your data")
        } footer: {
            Text("Saves everything in Helm — shift types, rosters and their shifts, schedules, time-off, availability and your preferences — as one JSON file you can keep or move elsewhere. Helm never sends your roster data anywhere; it stays on your device and in your private iCloud.")
        }
    }

    private func exportData() {
        exportText = (try? HelmDataExporter.export(from: dataContext).jsonString()) ?? ""
        isExportingData = true
    }

    // MARK: - Cleanup (v4: delete everything Helm created in a calendar)

    @ViewBuilder
    private var cleanupSection: some View {
        Section {
            Button("Remove all Helm events from Apple Calendar", role: .destructive) {
                removeAllCandidate = .eventkit
            }
            .disabled(isCleaningUp)
            .tint(.red) // destructive → red (the inherited accent tint would otherwise hide it)
            if googleUsable {
                Button("Remove all Helm events from Google Calendar", role: .destructive) {
                    removeAllCandidate = .google
                }
                .disabled(isCleaningUp)
                .tint(.red)
            }
            if isCleaningUp {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Removing…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let cleanupMessage {
                Text(cleanupMessage).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Remove Helm events")
        } footer: {
            Text("Deletes every calendar event Helm has created there. Your rosters and schedules stay in Helm. To put events back, open a roster and choose “Re-sync all shifts to calendar”, or open a schedule's Preview and choose “Re-sync to Calendar” (a plain re-import sees them as unchanged and writes nothing). To remove a single shift, swipe it in its roster or right-click it in the calendar.")
        }
        .confirmationDialog(
            "Remove ALL Helm events from \(removeAllCandidate.map(SyncSummary.name(for:)) ?? "this calendar")?",
            isPresented: Binding(
                get: { removeAllCandidate != nil },
                set: { if !$0 { removeAllCandidate = nil } }
            ),
            titleVisibility: .visible,
            presenting: removeAllCandidate
        ) { kind in
            Button("Remove all", role: .destructive) { removeAll(from: kind) }
            Button("Cancel", role: .cancel) {}
        } message: { kind in
            Text("Every event in the “Helm Shifts” calendar in \(SyncSummary.name(for: kind)) will be deleted. Helm's own data is untouched.")
        }
    }

    private func removeAll(from kind: CalendarTargetKind) {
        isCleaningUp = true
        cleanupMessage = nil
        Task {
            defer {
                isCleaningUp = false
                SyncProgress.shared.end()
            }
            SyncProgress.shared.begin("Removing all Helm events from \(SyncSummary.name(for: kind))…", total: nil)
            do {
                let target = try await CalendarTargetProvider.authorizedTarget(for: kind)
                let removed = try await target.removeAll()
                cleanupMessage = "Removed \(removed) event\(removed == 1 ? "" : "s") from \(SyncSummary.name(for: kind))."
            } catch {
                cleanupMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func destinationBinding(for kind: CalendarTargetKind) -> Binding<Bool> {
        Binding(
            get: { chosenDestinations.contains(kind) },
            set: { isOn in
                var kinds = chosenDestinations
                if isOn { kinds.insert(kind) } else { kinds.remove(kind) }
                if kinds.isEmpty { kinds = [.eventkit] } // never write to nowhere
                destinationsCSV = CalendarDestinationSetting.encode(kinds)
            }
        )
    }

    private func reminderBinding(for minutes: Int) -> Binding<Bool> {
        Binding(
            get: { reminderOffsets.contains(minutes) },
            set: { isOn in
                var offsets = reminderOffsets
                if isOn { offsets.insert(minutes) } else { offsets.remove(minutes) }
                reminderOffsetsCSV = ReminderOffsets.encode(Array(offsets))
            }
        )
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
                .tint(.red) // destructive → red
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

/// Minimal JSON document for the data export's `.fileExporter`.
struct JSONDataFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
