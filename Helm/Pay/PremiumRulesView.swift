//
//  PremiumRulesView.swift
//  Helm
//
//  v9 Premium Pay authoring. Edit the user's enhanced-rate rules (night /
//  weekend / bank-holiday / on-call) that the pure HelmDomain PayEngine applies.
//  Everything is the user's own configuration and clearly an estimate.
//

import SwiftUI
import HelmDomain

struct PremiumRulesView: View {
    @State private var rules: [PremiumRule] = []
    @State private var stacking: PremiumStacking = .highest
    @State private var editing: PremiumRule?
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                if rules.isEmpty {
                    Text("No premium rules yet. Add one to enhance pay for nights, weekends, bank holidays or on-call shifts.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    ForEach(rules) { rule in
                        Button { editing = rule } label: { ruleRow(rule) }
                            .buttonStyle(.plain)
                    }
                    .onDelete { rules.remove(atOffsets: $0); persist() }
                }
                Button("Add premium rule", systemImage: "plus") {
                    editing = PremiumRule(name: "", trigger: .timeWindow(startMinute: 22 * 60, endMinute: 6 * 60),
                                          adjustment: .multiplier(1.5))
                }
            } header: {
                Text("Premium rules")
            } footer: {
                Text("Applied on top of your base rate when a shift matches. Helm doesn't know any pay law — these are your rules, and the result is an estimate.")
            }

            if rules.filter(\.enabled).count > 1 {
                Section {
                    Picker("When rules overlap", selection: $stacking) {
                        Text("Use the highest").tag(PremiumStacking.highest)
                        Text("Add them together").tag(PremiumStacking.sum)
                    }
                } footer: {
                    Text(stacking == .highest
                         ? "A weekend night hour gets the better of the two enhancements, not both."
                         : "Overlapping enhancements stack — a weekend night hour gets both.")
                }
            }
        }
        .formStyle(.grouped)
        .themedPane()
        .navigationTitle("Premium pay")
        .onAppear {
            guard !loaded else { return }
            loaded = true
            rules = PaySettings.premiumRules
            stacking = PaySettings.premiumStacking
        }
        .onChange(of: stacking) { _, new in PaySettings.premiumStacking = new }
        .sheet(item: $editing) { rule in
            NavigationStack {
                PremiumRuleEditor(rule: rule) { saved in
                    if let i = rules.firstIndex(where: { $0.id == saved.id }) { rules[i] = saved }
                    else { rules.append(saved) }
                    persist()
                    editing = nil
                } onCancel: { editing = nil }
            }
        }
    }

    private func ruleRow(_ rule: PremiumRule) -> some View {
        HStack(spacing: 10) {
            Image(systemName: PremiumRuleEditor.icon(for: rule.trigger))
                .foregroundStyle(rule.enabled ? Color.accentColor : Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name.isEmpty ? PremiumRuleEditor.defaultName(for: rule.trigger) : rule.name)
                    .foregroundStyle(rule.enabled ? .primary : .secondary)
                Text(PremiumRuleEditor.summary(for: rule))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !rule.enabled {
                Text("Off").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private func persist() { PaySettings.premiumRules = rules }
}

// MARK: - Editor

struct PremiumRuleEditor: View {
    let original: PremiumRule
    let onSave: (PremiumRule) -> Void
    let onCancel: () -> Void

    private enum TriggerKind: String, CaseIterable, Identifiable {
        case timeWindow, weekdays, bankHoliday, shiftTag
        var id: String { rawValue }
        var label: String {
            switch self {
            case .timeWindow: "Time of day"
            case .weekdays: "Day of week"
            case .bankHoliday: "Bank holiday"
            case .shiftTag: "Shift tag"
            }
        }
    }
    private enum AdjustKind: String, CaseIterable, Identifiable {
        case multiplier, flat
        var id: String { rawValue }
        var label: String { self == .multiplier ? "Rate multiplier" : "Flat per hour" }
    }

    @State private var name: String
    @State private var enabled: Bool
    @State private var triggerKind: TriggerKind
    @State private var windowStart: Date
    @State private var windowEnd: Date
    @State private var weekdays: Set<Int>
    @State private var tag: String
    @State private var adjustKind: AdjustKind
    @State private var multiplier: Double
    @State private var flat: Double

    init(rule: PremiumRule, onSave: @escaping (PremiumRule) -> Void, onCancel: @escaping () -> Void) {
        self.original = rule
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: rule.name)
        _enabled = State(initialValue: rule.enabled)
        // Trigger
        let cal = Calendar.current
        func date(_ minutes: Int) -> Date { cal.startOfDay(for: .now).addingTimeInterval(Double(minutes) * 60) }
        switch rule.trigger {
        case .timeWindow(let s, let e):
            _triggerKind = State(initialValue: .timeWindow)
            _windowStart = State(initialValue: date(s)); _windowEnd = State(initialValue: date(e))
            _weekdays = State(initialValue: [1, 7]); _tag = State(initialValue: "")
        case .weekdays(let days):
            _triggerKind = State(initialValue: .weekdays)
            _windowStart = State(initialValue: date(22 * 60)); _windowEnd = State(initialValue: date(6 * 60))
            _weekdays = State(initialValue: days); _tag = State(initialValue: "")
        case .bankHoliday:
            _triggerKind = State(initialValue: .bankHoliday)
            _windowStart = State(initialValue: date(22 * 60)); _windowEnd = State(initialValue: date(6 * 60))
            _weekdays = State(initialValue: [1, 7]); _tag = State(initialValue: "")
        case .shiftTag(let t):
            _triggerKind = State(initialValue: .shiftTag)
            _windowStart = State(initialValue: date(22 * 60)); _windowEnd = State(initialValue: date(6 * 60))
            _weekdays = State(initialValue: [1, 7]); _tag = State(initialValue: t)
        }
        // Adjustment
        switch rule.adjustment {
        case .multiplier(let m):
            _adjustKind = State(initialValue: .multiplier); _multiplier = State(initialValue: m); _flat = State(initialValue: 2)
        case .flatPerHour(let f):
            _adjustKind = State(initialValue: .flat); _multiplier = State(initialValue: 1.5); _flat = State(initialValue: f)
        }
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField(Self.defaultName(for: builtTrigger), text: $name)
            }
            Section {
                Picker("Applies to", selection: $triggerKind) {
                    ForEach(TriggerKind.allCases) { Text($0.label).tag($0) }
                }
                switch triggerKind {
                case .timeWindow:
                    DatePicker("From", selection: $windowStart, displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: $windowEnd, displayedComponents: .hourAndMinute)
                case .weekdays:
                    weekdayGrid
                case .bankHoliday:
                    Text("Applies to shifts on dates you mark as bank holidays.")
                        .font(.caption).foregroundStyle(.secondary)
                case .shiftTag:
                    TextField("Tag (e.g. On-call)", text: $tag).autocorrectionDisabled()
                }
            } header: {
                Text("Trigger")
            } footer: {
                if triggerKind == .timeWindow {
                    Text("Only the hours inside the window are enhanced (it may cross midnight).")
                }
            }
            Section("Enhancement") {
                Picker("Type", selection: $adjustKind) {
                    ForEach(AdjustKind.allCases) { Text($0.label).tag($0) }
                }
                if adjustKind == .multiplier {
                    Stepper(value: $multiplier, in: 1...3, step: 0.05) {
                        LabeledContent("Multiplier", value: "×\(multiplier.formatted(.number.precision(.fractionLength(0...2)))) (+\(Int((multiplier - 1) * 100))%)")
                    }
                } else {
                    LabeledContent("Per hour") {
                        TextField("Amount", value: $flat, format: .currency(code: PaySettings.currencyCode))
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                    }
                }
            }
            Section {
                Toggle("Enabled", isOn: $enabled)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(original.name.isEmpty ? "New rule" : "Edit rule")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { onSave(built) }.disabled(!isValid)
            }
        }
    }

    private var weekdayGrid: some View {
        // Calendar weekday: 1=Sun … 7=Sat. Show Mon-first for the UI.
        let order = [2, 3, 4, 5, 6, 7, 1]
        let symbols = Calendar.current.shortWeekdaySymbols // index 0 = Sunday
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
            ForEach(order, id: \.self) { wd in
                let on = weekdays.contains(wd)
                Button {
                    if on { weekdays.remove(wd) } else { weekdays.insert(wd) }
                } label: {
                    Text(symbols[wd - 1])
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(on ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Color.accentColor : .clear))
                        .foregroundStyle(on ? .primary : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }

    private var builtTrigger: PremiumTrigger {
        switch triggerKind {
        case .timeWindow: return .timeWindow(startMinute: minutes(windowStart), endMinute: minutes(windowEnd))
        case .weekdays: return .weekdays(weekdays)
        case .bankHoliday: return .bankHoliday
        case .shiftTag: return .shiftTag(tag.trimmingCharacters(in: .whitespaces))
        }
    }
    private var builtAdjustment: PremiumAdjustment {
        adjustKind == .multiplier ? .multiplier(multiplier) : .flatPerHour(flat)
    }
    private var built: PremiumRule {
        PremiumRule(id: original.id,
                    name: name.trimmingCharacters(in: .whitespaces).isEmpty ? Self.defaultName(for: builtTrigger) : name,
                    trigger: builtTrigger, adjustment: builtAdjustment, enabled: enabled)
    }
    private var isValid: Bool {
        switch triggerKind {
        case .weekdays: return !weekdays.isEmpty
        case .shiftTag: return !tag.trimmingCharacters(in: .whitespaces).isEmpty
        default: return true
        }
    }

    private func minutes(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    // MARK: - Presentation helpers (shared with the list)

    static func icon(for trigger: PremiumTrigger) -> String {
        switch trigger {
        case .timeWindow: "moon.stars"
        case .weekdays: "calendar"
        case .bankHoliday: "star"
        case .shiftTag: "tag"
        }
    }
    static func defaultName(for trigger: PremiumTrigger) -> String {
        switch trigger {
        case .timeWindow: "Unsocial hours"
        case .weekdays: "Weekend"
        case .bankHoliday: "Bank holiday"
        case .shiftTag: "Premium"
        }
    }
    static func summary(for rule: PremiumRule) -> String {
        let when: String
        switch rule.trigger {
        case .timeWindow(let s, let e): when = "\(hhmm(s))–\(hhmm(e))"
        case .weekdays(let days): when = days.sorted().map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
        case .bankHoliday: when = "Bank holidays"
        case .shiftTag(let t): when = "Tagged “\(t)”"
        }
        let amount: String
        switch rule.adjustment {
        case .multiplier(let m): amount = "×\(m.formatted(.number.precision(.fractionLength(0...2))))"
        case .flatPerHour(let f): amount = "+\(f.formatted(.currency(code: PaySettings.currencyCode)))/hr"
        }
        return "\(when) · \(amount)"
    }
    private static func hhmm(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}
