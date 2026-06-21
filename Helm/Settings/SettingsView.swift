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
    // v9 Modules
    @AppStorage(AppModule.pay.key) private var payModule = true
    @AppStorage(AppModule.planning.key) private var planningModule = true
    @AppStorage(AppModule.insights.key) private var insightsModule = true
    // v9 Accessibility + welcome guide
    @AppStorage(A11ySettings.reduceTransparencyKey) private var reduceTransparency = false
    @AppStorage(OnboardingState.completedKey) private var hasCompletedOnboarding = false
    // v9 Paywall foundation
    @Environment(ProStore.self) private var proStore
    @State private var showingPaywall = false
    // v8 Pay
    @AppStorage(PaySettings.overtimeEnabledKey) private var payOvertimeEnabled: Bool = false
    @AppStorage(PaySettings.overtimeThresholdKey) private var payOvertimeThreshold: Double = PaySettings.defaultThreshold
    @AppStorage(PaySettings.overtimeMultiplierKey) private var payOvertimeMultiplier: Double = PaySettings.defaultMultiplier
    @AppStorage(PaySettings.taxYearPresetKey) private var payTaxYearPreset: String = "uk"
    // v9 Payday Forecast — pay cycle
    @AppStorage(PaySettings.payCycleEnabledKey) private var payCycleEnabled: Bool = false
    @AppStorage(PaySettings.payCycleFrequencyKey) private var payCycleFrequency: String = PayFrequency.monthly.rawValue
    @AppStorage(PaySettings.payCycleAnchorKey) private var payCycleAnchor: String = ""
    @AppStorage(PaySettings.payCycleLagKey) private var payCycleLag: Int = 0
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
    @Environment(ThemeManager.self) private var theme
    @Query private var importProfiles: [ImportProfile]

    @State private var isSigningIn = false
    @State private var authMessage: String?
    @State private var isConfirmingSignOut = false
    @FocusState private var rateFieldFocused: Bool
    @State private var removeAllCandidate: CalendarTargetKind?
    @State private var isCleaningUp = false
    @State private var cleanupMessage: String?
    // Data-export flow. The export is built off the tap (async + staged):
    // `isPreparingExport` drives the modal progress popup; once a non-empty
    // payload is encoded, `isExportingData` presents the save panel.
    @State private var isExportingData = false
    @State private var exportText = ""
    @State private var isPreparingExport = false
    @State private var exportProgress: Double = 0
    @State private var exportSummary: String?       // captured to confirm the save
    @State private var exportErrorMessage: String?  // surfaced via .alert
    @State private var exportSavedSummary: String?  // shown after a successful save
    @State private var showingPremiumRules = false  // v9 premium-pay editor (sheet — works in every Settings home)

    private var payDisplayCalendar: Calendar { CalendarViewModel.displayCalendar }

    /// DatePicker ↔ the stored "yyyy-MM-dd" anchor, in the display calendar.
    private var payCycleAnchorBinding: Binding<Date> {
        Binding(
            get: { PaySettings.anchorDayKey(payCycleAnchor)?.startOfDay(in: payDisplayCalendar) ?? .now },
            set: { payCycleAnchor = PaySettings.anchorString(DayKey(containing: $0, in: payDisplayCalendar)) }
        )
    }

    private var payCycleFooter: String {
        guard let cycle = PaySettings.payCycle else {
            return "Pick a recent payday and how often you're paid."
        }
        let today = DayKey(containing: .now, in: payDisplayCalendar)
        let pd = cycle.nextPayday(after: today, calendar: payDisplayCalendar)
        let date = pd.startOfDay(in: payDisplayCalendar).formatted(.dateTime.weekday().day().month())
        return "Your next payday is \(date). The projection shows on the Timesheet."
    }

    private func moduleBinding(_ module: AppModule) -> Binding<Bool> {
        switch module {
        case .pay: $payModule
        case .planning: $planningModule
        case .insights: $insightsModule
        }
    }

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

    var body: some View {
        Form {
            featuresSection

            Section {
                NavigationLink { calendarRemindersScreen } label: {
                    Label("Calendar & reminders", systemImage: "bell.badge")
                }
                if payModule {
                    NavigationLink { payScreen } label: {
                        Label("Pay & timesheet", systemImage: "banknote")
                    }
                }
                NavigationLink { appearanceScreen } label: {
                    Label("Appearance", systemImage: "paintpalette")
                }
                NavigationLink { dataScreen } label: {
                    Label("Privacy & data", systemImage: "lock.doc")
                }
            }

            #if os(iOS)
            appLockSection
            #endif

            helmProSection
        }
        .formStyle(.grouped)
        .themedPane() // v7.1 wash (iOS; passthrough on macOS)
        .navigationTitle("Settings")
        .sheet(isPresented: $showingPaywall) { PaywallView() }
        // Run the legacy single-value migrations so the new keys exist before
        // the @AppStorage defaults mask them.
        .onAppear {
            _ = ReminderSetting.offsets
            _ = CalendarDestinationSetting.chosenKinds
        }
    }

    // MARK: - Grouped sub-screens (v10: tuck the 14 flat sections behind ~4 links)

    @ViewBuilder
    private var calendarRemindersScreen: some View {
        Form {
            remindersSection
            #if os(iOS)
            alarmsSection
            #endif
            destinationsSection
            googleSection
            cleanupSection
        }
        .formStyle(.grouped)
        .themedPane()
        .navigationTitle("Calendar & reminders")
    }

    @ViewBuilder
    private var payScreen: some View {
        Form {
            paySection
            if hourlyRate > 0 { payCycleSection }
        }
        .formStyle(.grouped)
        .themedPane()
        .navigationTitle("Pay & timesheet")
        .onChange(of: payCycleEnabled) { _, on in
            // Seed a sensible anchor (today) the first time forecasting is enabled,
            // so the cycle resolves immediately instead of staying nil.
            if on, PaySettings.anchorDayKey(payCycleAnchor) == nil {
                payCycleAnchor = PaySettings.anchorString(DayKey(containing: .now, in: payDisplayCalendar))
            }
        }
        .sheet(isPresented: $showingPremiumRules) {
            NavigationStack {
                PremiumRulesView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingPremiumRules = false }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var appearanceScreen: some View {
        Form {
            ThemePickerSection()
            accessibilitySection
        }
        .formStyle(.grouped)
        .themedPane()
        .navigationTitle("Appearance")
    }

    @ViewBuilder
    private var dataScreen: some View {
        Form {
            dataSection
            welcomeSection
        }
        .formStyle(.grouped)
        .themedPane()
        .navigationTitle("Privacy & data")
        // While the export popup is up, hide the Form from VoiceOver so focus stays
        // trapped on the popup (the scrim only blocks pointer/touch, not assistive
        // tech) — otherwise a VoiceOver user could reach controls behind it.
        .accessibilityHidden(isPreparingExport)
        // The modal export progress popup, rendered INSIDE this screen so it shows
        // in every Settings home (iOS sheet, sidebar pane, AND the macOS ⌘, window).
        .overlay {
            if isPreparingExport {
                ExportProgressPopup(progress: exportProgress)
            }
        }
        .animation(.snappy(duration: 0.25), value: isPreparingExport)
        .fileExporter(isPresented: $isExportingData,
                      document: JSONDataFile(text: exportText),
                      contentType: .json,
                      defaultFilename: "Helm data export") { result in
            switch result {
            case .success:
                exportSavedSummary = exportSummary ?? "Your data was saved."
            case .failure(let error):
                // Cancelling the save panel isn't an error — only surface real ones.
                if (error as? CocoaError)?.code != .userCancelled {
                    exportErrorMessage = error.localizedDescription
                }
            }
        }
        .alert("Couldn’t export your data", isPresented: Binding(
            get: { exportErrorMessage != nil },
            set: { if !$0 { exportErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let exportErrorMessage { Text(exportErrorMessage) }
        }
    }

    // MARK: - Sections (lifted verbatim; now composed into the sub-screens above)

    @ViewBuilder
    private var featuresSection: some View {
        Section {
            ForEach(AppModule.allCases) { module in
                Toggle(isOn: moduleBinding(module)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(module.title, systemImage: module.icon)
                        Text(module.summary).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Features")
        } footer: {
            Text("Hide features you don't use. Nothing is deleted — switch one back on to restore it.")
        }
    }

    @ViewBuilder
    private var remindersSection: some View {
        Section {
            ForEach(ReminderSetting.presets, id: \.minutes) { preset in
                Toggle(preset.label, isOn: reminderBinding(for: preset.minutes))
                    .disabled(!reminderOffsets.contains(preset.minutes)
                              && reminderOffsets.count >= ReminderOffsets.maxCount)
            }
        } header: {
            Text("Default shift reminders")
        } footer: {
            Text("\(reminderOffsets.isEmpty ? "No reminders" : ReminderSetting.sentenceSummary(for: Array(reminderOffsets))) — pick up to \(ReminderOffsets.maxCount). Applied to new imports; a roster can override this. To update existing shifts, open a roster and Re-sync all shifts to calendar.")
        }
    }

    @ViewBuilder
    private var destinationsSection: some View {
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
                Text("Shifts go to both calendars. Each roster remembers where its shifts live, so re-applying moves them when you change this.")
            } else if googleUsable {
                Text("Each roster remembers where its shifts were written, so re-importing after switching moves them to the new destination.")
            } else {
                Text("Google Calendar appears here once it's set up and you're signed in below.")
            }
        }
    }

    @ViewBuilder
    private var paySection: some View {
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
            if hourlyRate > 0 {
                Button { showingPremiumRules = true } label: {
                    HStack {
                        Text("Premium pay rules")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
        } header: {
            Text("Pay")
        } footer: {
            Text("Set your hourly rate to unlock the Timesheet and Overview pay card. Figures are before tax.")
        }
    }

    @ViewBuilder
    private var payCycleSection: some View {
        Section {
            Toggle("Forecast my paydays", isOn: $payCycleEnabled)
            if payCycleEnabled {
                Picker("Pay frequency", selection: $payCycleFrequency) {
                    ForEach(PayFrequency.allCases, id: \.rawValue) { f in
                        Text(f.label).tag(f.rawValue)
                    }
                }
                DatePicker(payCycleFrequency == PayFrequency.monthly.rawValue ? "A recent payday" : "Start of a pay period",
                           selection: payCycleAnchorBinding, displayedComponents: .date)
                if payCycleFrequency != PayFrequency.monthly.rawValue {
                    Stepper(value: $payCycleLag, in: 0...14) {
                        LabeledContent("Paid", value: payCycleLag == 0
                                       ? "on the period's last day"
                                       : "\(payCycleLag) day\(payCycleLag == 1 ? "" : "s") later")
                    }
                }
            }
        } header: {
            Text("Pay cycle")
        } footer: {
            Text(payCycleEnabled
                 ? payCycleFooter
                 : "Tell Helm how often you're paid to forecast your next payday on the Timesheet.")
        }
    }

    #if os(iOS)
    @ViewBuilder
    private var appLockSection: some View {
        Section {
            Toggle("Require \(AppLockSetting.biometryLabel)", isOn: $requireAppLock)
                .disabled(!AppLockSetting.canAuthenticate)
        } header: {
            Text("App Lock")
        } footer: {
            if AppLockSetting.canAuthenticate {
                Text("Lock Helm with \(AppLockSetting.biometryLabel) or your passcode on launch and when you return, so only you can open it.")
            } else {
                Text("Set up Face ID, Touch ID, or a device passcode first to lock Helm.")
            }
        }
    }

    // Wake-up alarms use AlarmKit (iOS 26+); the Section hides itself on older
    // systems rather than presenting a toggle that does nothing.
    @ViewBuilder
    private var alarmsSection: some View {
        if #available(iOS 26.0, *) {
            Section {
                Toggle("Wake me up for shifts", isOn: $shiftAlarmsEnabled)
                if shiftAlarmsEnabled {
                    Picker("Alarm before shift", selection: $shiftAlarmLead) {
                        ForEach(ShiftAlarmSetting.leadChoices, id: \.self) { mins in
                            Text(ShiftAlarmSetting.label(forLead: mins)).tag(mins)
                        }
                    }
                }
            } header: {
                Text("Wake-up alarms")
            } footer: {
                Text("Rings a real alarm \(ShiftAlarmSetting.label(forLead: shiftAlarmLead)) before each timed shift — through Silent mode, Focus and Sleep. A roster can override the timing. (It's Helm's own alarm, separate from your Sleep schedule.)")
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
    }
    #endif

    @ViewBuilder
    private var accessibilitySection: some View {
        Section {
            Toggle("Reduce transparency", isOn: $reduceTransparency)
        } header: {
            Text("Accessibility")
        } footer: {
            Text("Flattens Helm's translucent glass to solid surfaces for easier reading. Helm also follows your device's text-size and motion settings.")
        }
    }

    @ViewBuilder
    private var welcomeSection: some View {
        Section {
            Button("Show welcome guide") { hasCompletedOnboarding = false }
        } footer: {
            Text("Replays the first-run tour — what Helm does, plus appearance and accessibility.")
        }
    }

    @ViewBuilder
    private var helmProSection: some View {
        Section {
            Button { showingPaywall = true } label: {
                HStack {
                    Label("Helm Pro", systemImage: "sailboat.fill")
                    Spacer()
                    if proStore.isPro { Text("Unlocked").foregroundStyle(.green) }
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            Button("Restore purchase") { Task { await proStore.restore() } }
                .disabled(proStore.isWorking)
        } header: {
            Text("Helm Pro")
        } footer: {
            Text(proStore.isPro
                 ? "Thanks for supporting Helm."
                 : "A one-time unlock. Everything's free right now — Pro just supports Helm's development.")
        }
    }

    // MARK: - Data export (v8.2: GDPR data portability)

    @ViewBuilder
    private var dataSection: some View {
        Section {
            Button("Export my data…", systemImage: "square.and.arrow.up", action: exportData)
                .disabled(isPreparingExport)
            if let exportSavedSummary {
                Label("Saved · \(exportSavedSummary)", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .accessibilityLabel("Export saved. \(exportSavedSummary)")
            }
        } header: {
            Text("Your data")
        } footer: {
            Text("Saves everything in Helm as one JSON file you can keep or move elsewhere. Your data never leaves your device and private iCloud.")
        }
    }

    /// Build + encode the export off the tap so the UI stays responsive and a
    /// determinate progress popup can animate. The SwiftData fetch stays on the
    /// MainActor (ModelContext isn't Sendable); only the finished, Sendable value
    /// is encoded on a detached task. The save panel is presented ONLY after a
    /// non-empty payload exists — never an empty 0-byte file, and any failure is
    /// surfaced instead of swallowed.
    private func exportData() {
        guard !isPreparingExport else { return } // ignore re-taps mid-export
        isPreparingExport = true
        exportProgress = 0
        exportErrorMessage = nil
        exportSavedSummary = nil
        Task {
            defer { isPreparingExport = false }
            // MainActor build; the bar climbs across ~0…0.85 as sections complete.
            let export = await HelmDataExporter.export(from: dataContext) { built in
                exportProgress = built * 0.85
            }
            // Encode the Sendable value off the main actor — the long pole — then
            // fill the bar. A throw or empty result becomes a surfaced error, not
            // a silently-saved empty file.
            let encoded = await Task.detached(priority: .userInitiated) { () -> ExportEncodeResult in
                do { return .success(try export.jsonString()) }
                catch { return .failure(error.localizedDescription) }
            }.value
            exportProgress = 1
            try? await Task.sleep(for: .milliseconds(160)) // let the bar reach 100%
            switch encoded {
            case .failure(let message):
                exportErrorMessage = message
            case .success(let json) where json.isEmpty:
                exportErrorMessage = "Helm couldn’t prepare your export. Please try again."
            case .success(let json):
                exportText = json               // assign BEFORE presenting (no race)
                exportSummary = export.itemSummary
                isExportingData = true
            }
        }
    }

    // MARK: - Cleanup (v4: delete everything Helm created in a calendar)

    @ViewBuilder
    private var cleanupSection: some View {
        Section {
            Button("Remove all Helm events from Apple Calendar", role: .destructive) {
                removeAllCandidate = .eventkit
            }
            .disabled(isCleaningUp)
            .tint(theme.destructive) // vivid, scheme-aware red (the inherited accent tint hides plain .red)
            if googleUsable {
                Button("Remove all Helm events from Google Calendar", role: .destructive) {
                    removeAllCandidate = .google
                }
                .disabled(isCleaningUp)
                .tint(theme.destructive)
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
            Text("Deletes every event Helm created there; your rosters and schedules stay in Helm. To put events back, open a roster and Re-sync all shifts to calendar. To remove just one, swipe it in its roster.")
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
            Text("Deletes every event in the “Helm Shifts” calendar in \(SyncSummary.name(for: kind)). Your Helm data is untouched.")
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
                .tint(theme.destructive)
                .confirmationDialog(
                    "\(googleRosterCount) roster\(googleRosterCount == 1 ? " has" : "s have") shifts in this Google account. Helm can't change them until you sign back in.",
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
                Text("Create a free Google Cloud OAuth client ID (type “iOS”, bundle ID Fusion-Studios.Helm) and paste it here. Helm only touches its own “Helm Shifts” calendar, never your others.")
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

/// Result of encoding the export on a detached task — a Sendable carrier so the
/// error message (not a non-Sendable `Error`) can cross back to the MainActor.
private enum ExportEncodeResult: Sendable {
    case success(String)
    case failure(String)
}

/// The modal "exporting…" popup: a dimmed scrim over the Settings surface with a
/// centred glass card carrying a determinate progress bar. Lives inside the Form
/// so it appears in every Settings home; the scrim swallows taps so the export
/// can't be re-triggered underneath it.
private struct ExportProgressPopup: View {
    let progress: Double

    private var percent: Int { Int((progress * 100).rounded()) }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.28))
                .ignoresSafeArea()
            VStack(spacing: 14) {
                Text("Exporting your data…")
                    .font(.headline)
                ProgressView(value: progress, total: 1)
                    .progressViewStyle(.linear)
                    .animation(.linear(duration: 0.2), value: progress)
                Text("\(percent)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(22)
            .frame(width: 260)
            .glassCard(cornerRadius: 16)
            .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits([.isModal, .updatesFrequently])
        .accessibilityLabel("Exporting your data, \(percent) percent complete")
    }
}
