//
//  UnknownCodesPanel.swift
//  Helm
//
//  v6 Import Intelligence UI: the inline, SKIPPABLE review panel for unknown
//  shift codes (a collapsible card in the loaded phase — never a sheet), and
//  the always-visible import-health banner. Saving a mapping persists
//  eagerly (LegendBuilder.learn) and re-resolves the preview in place.
//

import SwiftUI
import SwiftData
import HelmDomain

/// "26 shifts · 2 all-day · 1 unknown (L)" — the contract that nothing is
/// ever silently dropped. Orange while unknowns remain.
struct ImportHealthBanner: View {
    let health: ImportHealth
    /// Tap-through: switch to the (outcome-grouped) list preview.
    var onShowDetails: (() -> Void)?

    var body: some View {
        Button {
            onShowDetails?()
        } label: {
            Label(health.summary, systemImage: health.hasUnknown ? "exclamationmark.triangle.fill" : "checkmark.seal")
                .font(.callout)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    (health.hasUnknown ? Color.orange : Color.green).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .foregroundStyle(health.hasUnknown ? Color.orange : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Import summary: \(health.summary)")
    }
}

/// One unknown code → one row with a Map/All-day/Ignore editor.
struct UnknownCodesPanel: View {
    let codes: [String]
    let result: RosterImportResult
    /// Persist + re-resolve (the coordinator's remapAndReplan funnel).
    let onLearn: (String, LegendBuilder.LearnAction) -> Void

    @Query(sort: \ShiftType.code) private var allTypes: [ShiftType]
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Unknown shift codes — teach Helm what they mean", systemImage: "graduationcap")
                .font(.subheadline.weight(.semibold))
            ForEach(codes, id: \.self) { code in
                UnknownCodeRow(
                    code: code,
                    occurrences: result.drafts.filter { $0.code == code }.count,
                    sampleTitle: result.drafts.first { $0.code == code && $0.title != nil }?.title,
                    suggestion: suggestion(for: code),
                    existingTypes: allTypes.filter { $0.code?.isEmpty == false },
                    onLearn: { onLearn(code, $0) }
                )
            }
            Text("Helm remembers these for next time. You can change them later under Shift Types.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    /// A smart, reasoned time prefill for an unknown code — composite span,
    /// common-UK starter library, semantic hint, or a flagged 9–5 default. Always
    /// returns something so every code opens with a one-tap suggestion to confirm.
    private func suggestion(for code: String) -> CodeSuggestion {
        let legend = LegendBuilder.legend(forSourceName: result.sourceName, in: modelContext)
        return UnknownCodeSuggester.suggest(for: code, legend: legend)
    }
}

private struct UnknownCodeRow: View {
    let code: String
    let occurrences: Int
    let sampleTitle: String?
    let suggestion: CodeSuggestion
    let existingTypes: [ShiftType]
    let onLearn: (LegendBuilder.LearnAction) -> Void

    private enum Mode: Hashable {
        case existing, newTimed, allDay, ignore
    }

    @State private var mode: Mode = .newTimed
    @State private var selectedTypeID: String?
    @State private var label = ""
    @State private var startMinutes = 9 * 60
    @State private var endMinutes = 17 * 60
    @State private var overnight = false
    @State private var isExpanded = false
    @State private var aiBusy = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Meaning", selection: $mode) {
                    if !existingTypes.isEmpty { Text("Existing type").tag(Mode.existing) }
                    Text("New times").tag(Mode.newTimed)
                    Text("All-day").tag(Mode.allDay)
                    Text("Ignore").tag(Mode.ignore)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch mode {
                case .existing:
                    Picker("Shift type", selection: $selectedTypeID) {
                        Text("Choose…").tag(String?.none)
                        ForEach(existingTypes) { type in
                            Text("\(type.code ?? "?") — \(type.label ?? "Untitled")").tag(String?.some(type.id))
                        }
                    }
                case .newTimed:
                    VStack(alignment: .leading, spacing: 2) {
                        Button("Use \(hhmm(suggestion.startMinute))–\(hhmm(suggestion.endMinute))\(suggestion.label.map { " · \($0)" } ?? "")") {
                            applyPrefill((suggestion.startMinute, suggestion.endMinute))
                            if label.isEmpty, let l = suggestion.label { label = l }
                        }
                        .font(.caption)
                        .buttonStyle(.glass)
                        Label(suggestion.reason, systemImage: confidenceIcon)
                            .font(.caption2)
                            .foregroundStyle(confidenceColor)
                    }
                    #if canImport(FoundationModels)
                    if SmartImport.isAvailable {
                        Button { Task { await decodeWithAI() } } label: {
                            HStack(spacing: 5) {
                                if aiBusy { ProgressView().controlSize(.mini) }
                                Label("Suggest with Apple Intelligence", systemImage: "sparkles")
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.glass)
                        .disabled(aiBusy)
                    }
                    #endif
                    TextField("Label (e.g. Late)", text: $label)
                    HStack {
                        minutePicker("Starts", selection: $startMinutes)
                        minutePicker("Ends", selection: $endMinutes)
                    }
                    Toggle("Ends next day", isOn: $overnight)
                case .allDay:
                    Text("Adds an all-day event, like leave or study days.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .ignore:
                    Text("Days with this code are skipped, and always listed so nothing is lost.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Save mapping") { save() }
                    .buttonStyle(.glassProminent)
                    .disabled((mode == .existing && selectedTypeID == nil)
                              // An equal pick is a mis-pick, not a 24h shift.
                              || (mode == .newTimed && endMinutes == startMinutes && !overnight))
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Text(code).font(.body.weight(.bold).monospaced())
                Text("\(occurrences) day\(occurrences == 1 ? "" : "s")\(sampleTitle.map { " · e.g. “\($0)”" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .onAppear {
            mode = .newTimed
            applyPrefill((suggestion.startMinute, suggestion.endMinute))
            if label.isEmpty, let l = suggestion.label { label = l }
        }
    }

    private var confidenceIcon: String {
        switch suggestion.confidence {
        case .high: "checkmark.circle.fill"
        case .medium: "sparkles"
        case .low: "questionmark.circle"
        }
    }
    private var confidenceColor: Color {
        switch suggestion.confidence {
        case .high: .green
        case .medium: .secondary
        case .low: .orange
        }
    }

    /// WRAP overnight ends (an effective 06:30-next-day is 1830 → 06:30 + the
    /// overnight flag), never clamp — clamping wrote 23:45-next-day types. Also
    /// snap to the 15-minute picker grid so the menus always show a selection.
    private func applyPrefill(_ suggestion: (start: Int, end: Int)) {
        func snap(_ minute: Int) -> Int { (minute / 15) * 15 }
        overnight = suggestion.end > 1439
        startMinutes = snap(suggestion.start)
        endMinutes = snap(overnight ? suggestion.end - 1440 : suggestion.end)
    }

    #if canImport(FoundationModels)
    /// Ask the on-device model what this code likely means and prefill the row.
    private func decodeWithAI() async {
        guard #available(iOS 26, macOS 26, *) else { return }
        aiBusy = true
        defer { aiBusy = false }
        guard let m = try? await SmartImport.decodeCode(code, sampleTitle: sampleTitle) else { return }
        let trimmed = m.label.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { label = trimmed }
        if let s = parseHHMM(m.startTime), let e = parseHHMM(m.endTime), s != e {
            applyPrefill((s, e <= s ? e + 1440 : e)) // wrap an overnight end
        }
    }

    private func parseHHMM(_ s: String) -> Int? {
        let parts = s.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }
    #endif

    private func save() {
        switch mode {
        case .existing:
            guard let selectedTypeID else { return }
            onLearn(.useExisting(typeID: selectedTypeID))
        case .newTimed:
            onLearn(.newTimed(
                label: label.isEmpty ? nil : label,
                startMinute: startMinutes,
                endMinute: endMinutes,
                overnight: overnight || endMinutes < startMinutes, // strict: equal is blocked above
                colorHex: nil
            ))
        case .allDay:
            onLearn(.allDay)
        case .ignore:
            onLearn(.ignore)
        }
    }

    private func minutePicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            ForEach(Array(stride(from: 0, to: 1440, by: 15)), id: \.self) { minute in
                Text(hhmm(minute)).tag(minute)
            }
        }
        .pickerStyle(.menu)
    }
}

private func hhmm(_ minute: Int) -> String {
    let m = ((minute % 1440) + 1440) % 1440
    return String(format: "%02d:%02d", m / 60, m % 60)
}
