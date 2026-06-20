//
//  RosterPayView.swift
//  Helm
//
//  v9 Multiple Jobs. Per-roster employer + pay overrides: name the job, give it
//  its own hourly rate, and (optionally) its own premium rules. Anything left on
//  "use default" inherits the global Settings ▸ Pay values. Mirrors the per-roster
//  Reminders editor — an in-window push that commits on disappear.
//

import SwiftUI
import SwiftData
import HelmDomain

struct RosterPayView: View {
    @Bindable var roster: Roster
    @Environment(\.modelContext) private var modelContext

    @State private var employer = ""
    @State private var useCustomRate = false
    @State private var rate = 0.0
    @State private var useCustomPremiums = false
    @State private var showingPremiums = false
    @State private var loaded = false
    @FocusState private var rateFocused: Bool

    private var globalRate: Double { PaySettings.rules.hourlyRate }
    private var currency: String { PaySettings.currencyCode }

    var body: some View {
        Form {
            Section {
                TextField(roster.title ?? "Employer", text: $employer)
                    .autocorrectionDisabled()
            } header: {
                Text("Job / employer")
            } footer: {
                Text("Shown in your timesheet's per-employer breakdown when you track more than one job. Leave blank to use the roster name.")
            }

            Section {
                Toggle("Set a rate for this job", isOn: $useCustomRate)
                if useCustomRate {
                    LabeledContent("Hourly rate") {
                        HStack(spacing: 2) {
                            Text(Locale.current.currencySymbol ?? "£").foregroundStyle(.secondary)
                            TextField("Rate", value: $rate, format: .number.precision(.fractionLength(0...2)))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 70)
                                .focused($rateFocused)
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                .toolbar {
                                    ToolbarItemGroup(placement: .keyboard) {
                                        Spacer(); Button("Done") { rateFocused = false }
                                    }
                                }
                                #endif
                        }
                    }
                }
            } header: {
                Text("Pay rate")
            } footer: {
                Text(useCustomRate
                     ? "This job is paid at \(rate.formatted(.currency(code: currency)))/h instead of the global rate."
                     : "Inherits the global rate — \(globalRate > 0 ? globalRate.formatted(.currency(code: currency)) + "/h" : "set one in Settings ▸ Pay").")
            }

            Section {
                Toggle("Custom premium rules for this job", isOn: $useCustomPremiums)
                if useCustomPremiums {
                    Button {
                        showingPremiums = true
                    } label: {
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
                Text("Premiums")
            } footer: {
                Text(useCustomPremiums
                     ? "This job uses its own night/weekend/etc. rules, ignoring the global ones."
                     : "Inherits your global premium rules from Settings ▸ Pay.")
            }
        }
        .formStyle(.grouped)
        .themedPane()
        .navigationTitle("Pay & employer")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            guard !loaded else { return }
            loaded = true
            employer = roster.employerName ?? ""
            useCustomRate = roster.hourlyRateOverride != nil
            rate = roster.hourlyRateOverride ?? globalRate
            useCustomPremiums = roster.premiumRulesData != nil
        }
        .onDisappear(perform: commit)
        .sheet(isPresented: $showingPremiums) {
            NavigationStack {
                PremiumRulesView(
                    load: { (roster.premiumRules ?? [], roster.premiumStacking ?? .highest) },
                    commit: { newRules, newStacking in
                        let newData = try? JSONEncoder().encode(newRules)
                        let newStackRaw = newStacking.rawValue
                        // Idempotent: the editor's load-time onChange re-commits the same
                        // values — skip the SwiftData (CloudKit) write unless they changed.
                        guard newData != roster.premiumRulesData || newStackRaw != roster.premiumStackingRaw else { return }
                        roster.premiumRulesData = newData
                        roster.premiumStackingRaw = newStackRaw
                        try? modelContext.save()
                    })
                .navigationTitle("\(roster.employerDisplayName) premiums")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingPremiums = false }
                    }
                }
            }
        }
    }

    private func commit() {
        guard loaded else { return }
        let trimmed = employer.trimmingCharacters(in: .whitespaces)
        roster.employerName = trimmed.isEmpty ? nil : trimmed
        // A custom rate of 0 means "inherit", not "this job pays £0" — collapse it to
        // nil so a stray zero never silently overrides a (later) global rate.
        roster.hourlyRateOverride = (useCustomRate && rate > 0) ? rate : nil
        if useCustomPremiums {
            // Enabled but never edited → persist an empty set so the choice sticks
            // (empty = no premiums for this job, distinct from inheriting the global ones).
            if roster.premiumRulesData == nil { roster.premiumRulesData = Data("[]".utf8) }
        } else {
            // Turning custom premiums off reverts this job to the global rules.
            roster.premiumRulesData = nil
            roster.premiumStackingRaw = nil
        }
        try? modelContext.save()
    }
}
