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
                    spanningSuggestion: spanningSuggestion(for: code),
                    existingTypes: allTypes.filter { $0.code?.isEmpty == false },
                    onLearn: { onLearn(code, $0) }
                )
            }
            Text("Mappings are remembered for this roster — the next import resolves them automatically. You can change them later under Shift Types.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    /// "M/A"-style composites: a confirm-first prefill spanning both parts.
    private func spanningSuggestion(for code: String) -> (start: Int, end: Int)? {
        let parts = CompositeShiftCode.split(code)
        guard !parts.isEmpty else { return nil }
        let legend = LegendBuilder.legend(forSourceName: result.sourceName, in: modelContext)
        var entries: [ShiftLegendEntry] = []
        for part in parts {
            guard case let .timed(entry)? = legend.resolution(for: part) else { return nil }
            entries.append(entry)
        }
        guard let span = CompositeShiftCode.spanningSuggestion(parts: entries) else { return nil }
        return (span.startMinute, span.endMinute)
    }
}

private struct UnknownCodeRow: View {
    let code: String
    let occurrences: Int
    let sampleTitle: String?
    let spanningSuggestion: (start: Int, end: Int)?
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
                    if let suggestion = spanningSuggestion {
                        Button("Use \(hhmm(suggestion.start))–\(hhmm(suggestion.end)) (spans \(CompositeShiftCode.split(code).joined(separator: " + ")))") {
                            startMinutes = suggestion.start
                            endMinutes = min(suggestion.end, 1439)
                            overnight = suggestion.end > 1439
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    }
                    TextField("Label (e.g. Late)", text: $label)
                    HStack {
                        minutePicker("Starts", selection: $startMinutes)
                        minutePicker("Ends", selection: $endMinutes)
                    }
                    Toggle("Ends next day", isOn: $overnight)
                case .allDay:
                    Text("Writes an all-day event (like leave or study days).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .ignore:
                    Text("Days with this code will be skipped — always listed as “ignored by your rules”, never silently.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Save mapping") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(mode == .existing && selectedTypeID == nil)
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
            if existingTypes.isEmpty == false && spanningSuggestion == nil { mode = .newTimed }
            if let suggestion = spanningSuggestion {
                startMinutes = suggestion.start
                endMinutes = min(suggestion.end, 1439)
                overnight = suggestion.end > 1439
            }
        }
    }

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
                overnight: overnight || endMinutes <= startMinutes,
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
