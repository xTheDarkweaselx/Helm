//
//  ShiftTypeLibraryView.swift
//  Helm
//
//  Manage the shared shift-type vocabulary (Morning 06:30–13:30, etc.) used by
//  cycles, explicit days and exceptions. v7: the editor is now an IN-WINDOW
//  push (no more macOS sheet), with tag and colour-preset editing.
//

import SwiftUI
import SwiftData
import HelmDomain

struct ShiftTypeLibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ShiftType.code) private var types: [ShiftType]
    @Query(sort: \ShiftCodeMapping.rawCode) private var learnedMappings: [ShiftCodeMapping]
    /// The shift type being edited (pushed in-window). nil = none.
    @State private var editing: ShiftType?
    @State private var pendingDeletion: [ShiftType] = []

    /// Favourites first, then user order, then code.
    private var orderedTypes: [ShiftType] {
        types.sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite && !b.isFavorite }
            if a.sortIndex != b.sortIndex { return a.sortIndex < b.sortIndex }
            return (a.code ?? a.label ?? "") < (b.code ?? b.label ?? "")
        }
    }

    var body: some View {
        List {
            ForEach(orderedTypes) { type in
                Button { editing = type } label: { row(type) }
                    .buttonStyle(.plain)
            }
            .onDelete { offsets in
                let targets = offsets.map { orderedTypes[$0] }
                if targets.reduce(0, { $0 + referenceCount($1) }) > 0 {
                    pendingDeletion = targets // confirm — would turn dependent days off
                } else {
                    delete(targets)
                }
            }

            // v6 Import Intelligence: what Helm has learned per source.
            if !learnedMappings.isEmpty {
                Section {
                    ForEach(learnedMappings) { mapping in
                        learnedRow(mapping)
                            .swipeActions {
                                Button("Forget", systemImage: "trash", role: .destructive) {
                                    LegendBuilder.forget(mapping, in: context)
                                }
                            }
                            .contextMenu {
                                Button("Forget mapping", systemImage: "trash", role: .destructive) {
                                    LegendBuilder.forget(mapping, in: context)
                                }
                            }
                    }
                } header: {
                    Text("Learned codes")
                } footer: {
                    Text("Learned per roster source during imports. Forget one to be asked again next import.")
                }
            }
        }
        .confirmationDialog("Delete shift type?",
                            isPresented: Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } }),
                            titleVisibility: .visible) {
            Button("Delete — turns \(pendingRefCount) day\(pendingRefCount == 1 ? "" : "s") off", role: .destructive) {
                delete(pendingDeletion); pendingDeletion = []
            }
            Button("Cancel", role: .cancel) { pendingDeletion = [] }
        } message: {
            Text("Used by \(pendingRefCount) day\(pendingRefCount == 1 ? "" : "s") in your schedules. Deleting it turns them off on the next update.")
        }
        .navigationTitle("Shift Types")
        .overlay {
            if types.isEmpty {
                ContentUnavailableView("No shift types", systemImage: "clock",
                    description: Text("Add the shifts you work, e.g. Morning 06:30–13:30."))
            }
        }
        .toolbar {
            ToolbarItem { Button("Add shift type", systemImage: "plus") { addType() } }
        }
        // In-window editor: a push within the detail NavigationStack, never a sheet.
        .navigationDestination(item: $editing) { type in
            ShiftTypeEditorView(type: type)
        }
        .themedPane() // v7.1 wash
    }

    private var pendingRefCount: Int { pendingDeletion.reduce(0) { $0 + referenceCount($1) } }

    private func referenceCount(_ type: ShiftType) -> Int {
        (type.rotationSlots?.count ?? 0) + (type.explicitDays?.count ?? 0) + (type.exceptions?.count ?? 0)
    }

    private func addType() {
        let type = ShiftType()
        type.sortIndex = (types.map(\.sortIndex).max() ?? 0) + 1
        context.insert(type)
        try? context.save()
        editing = type // push the editor; emptied-and-abandoned types self-delete on back
    }

    @ViewBuilder
    private func learnedRow(_ mapping: ShiftCodeMapping) -> some View {
        HStack {
            Text(mapping.rawCode ?? "?")
                .font(.body.weight(.bold).monospaced())
            VStack(alignment: .leading, spacing: 1) {
                switch mapping.actionRaw ?? "timed" {
                case "allDay":
                    Text("All-day event")
                case "ignore":
                    Text("Ignored").foregroundStyle(.secondary)
                default:
                    Text(mapping.shiftType.map { "\($0.label ?? $0.code ?? "Shift")" } ?? "Missing type")
                        .foregroundStyle(mapping.shiftType == nil ? .red : .primary)
                }
                if let source = mapping.importProfile?.name {
                    Text(source).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            if let type = mapping.shiftType {
                ShiftTypeChip(label: type.code ?? "?", colorHex: type.colorHex)
            }
        }
    }

    private func delete(_ targets: [ShiftType]) {
        for t in targets { context.delete(t) }
        try? context.save()
    }

    private func row(_ type: ShiftType) -> some View {
        HStack(alignment: .top) {
            ShiftTypeChip(label: type.code ?? type.label ?? "?", colorHex: type.colorHex)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(type.label ?? type.code ?? "Shift").foregroundStyle(.primary)
                    if type.isFavorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                }
                if let loc = type.locationName, !loc.isEmpty {
                    Text(loc).font(.caption).foregroundStyle(.secondary)
                }
                if !type.tags.isEmpty {
                    TagPillRow(tags: type.tags, colorFor: { type.colorHex(forTag: $0) })
                }
            }
            Spacer()
            if type.workKind == .off {
                Text("Off").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("\(hhmmString(type.startMinuteOfDay))–\(hhmmString(type.endMinuteOfDay))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - In-window editor

struct ShiftTypeEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.helmAccent) private var accent
    @Bindable var type: ShiftType
    @State private var newTag = ""
    @FocusState private var tagFieldFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 36), spacing: 10)]

    var body: some View {
        Form {
            Section("Name") {
                TextField("Label (e.g. Morning)", text: optBinding(\.label))
                TextField("Code (e.g. M)", text: codeBinding)
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
            }

            Picker("Kind", selection: Binding(get: { type.workKind }, set: { type.workKind = $0 })) {
                ForEach(WorkKind.allCases, id: \.self) { Text(kindLabel($0)).tag($0) }
            }

            if type.workKind != .off {
                Section("Times") {
                    DatePicker("Start", selection: timeOfDayBinding($type.startMinuteOfDay), displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: timeOfDayBinding($type.endMinuteOfDay), displayedComponents: .hourAndMinute)
                    Toggle("Ends next day (overnight)", isOn: endsNextDayBinding)
                    Stepper("Unpaid break: \(type.breakMinutes) min", value: $type.breakMinutes, in: 0...240, step: 15)
                    LabeledContent("Paid duration", value: durationText)
                }
            }

            Section("Colour") {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(ShiftColorPresets.all, id: \.self) { hex in
                        Button { type.colorHex = hex } label: {
                            Circle()
                                .fill(Color(hex: hex) ?? .gray)
                                .frame(width: 30, height: 30)
                                .overlay(Circle().strokeBorder(.primary.opacity(isSelectedColor(hex) ? 0.85 : 0.12),
                                                               lineWidth: isSelectedColor(hex) ? 2.5 : 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                ColorPicker("Custom colour", selection: colorBinding, supportsOpacity: false)
            }

            tagsSection

            Section("Location") {
                TextField("Default location (optional)", text: optBinding(\.locationName))
            }

            Section {
                Toggle("Favourite (pin to top)", isOn: $type.isFavorite)
            }
        }
        .formStyle(.grouped)
        .themedPane() // v7.1 wash (iOS; passthrough on macOS)
        .navigationTitle(titleText)
        #if os(macOS)
        .navigationSubtitle(type.workKind == .off ? "Off" : "\(hhmmString(type.startMinuteOfDay))–\(hhmmString(type.endMinuteOfDay))")
        #endif
        .onDisappear { commit() }
    }

    private var titleText: String {
        if let l = type.label, !l.isEmpty { return l }
        if let c = type.code, !c.isEmpty { return c }
        return "New Shift Type"
    }

    // MARK: Tags

    @ViewBuilder
    private var tagsSection: some View {
        Section {
            if !type.tags.isEmpty {
                WrappingHStack(type.tags, spacing: 6, lineSpacing: 6) { tag in
                    HStack(spacing: 3) {
                        TagPill(text: tag, colorHex: type.colorHex(forTag: tag))
                        Button {
                            type.tags = type.tags.filter { $0.caseInsensitiveCompare(tag) != .orderedSame }
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                TextField("Add a tag (e.g. Night, Senior)", text: $newTag)
                    .focused($tagFieldFocused)
                    .onSubmit(addTag)
                Button("Add", action: addTag)
                    .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty || type.tags.count >= ShiftTags.maxCount)
            }
        } header: {
            Text("Tags")
        } footer: {
            Text("Optional categories shown on shifts and searchable — up to \(ShiftTags.maxCount).")
        }
    }

    private func addTag() {
        let trimmed = newTag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var tags = type.tags
        tags.append(trimmed)
        type.tags = tags // the setter sanitises, dedupes, caps
        newTag = ""
    }

    // MARK: Bindings & helpers

    private func optBinding(_ kp: ReferenceWritableKeyPath<ShiftType, String?>) -> Binding<String> {
        Binding(get: { type[keyPath: kp] ?? "" }, set: { type[keyPath: kp] = $0.isEmpty ? nil : $0 })
    }

    private var codeBinding: Binding<String> {
        Binding(get: { type.code ?? "" }, set: { type.code = $0.isEmpty ? nil : $0.uppercased() })
    }

    private var endsNextDayBinding: Binding<Bool> {
        Binding(get: { type.endDayOffset > 0 }, set: { type.endDayOffset = $0 ? 1 : 0 })
    }

    private var colorBinding: Binding<Color> {
        Binding(get: { Color(hex: type.colorHex) ?? accent }, set: { type.colorHex = $0.hexString })
    }

    private func isSelectedColor(_ hex: String) -> Bool {
        (type.colorHex ?? "").uppercased() == hex.uppercased()
    }

    private func kindLabel(_ k: WorkKind) -> String {
        switch k {
        case .worked: "Worked"
        case .onCall: "On call"
        case .standby: "Standby"
        case .off: "Off"
        case .leave: "Leave"
        }
    }

    private var durationText: String {
        var endTotal = type.endMinuteOfDay + (type.endDayOffset > 0 ? 1440 : 0)
        if endTotal <= type.startMinuteOfDay { endTotal += 1440 } // overnight
        let mins = max(0, endTotal - type.startMinuteOfDay - type.breakMinutes)
        return String(format: "%.2gh", Double(mins) / 60)
    }

    /// Auto-save on leave. A brand-new type left empty and unreferenced is
    /// removed, so a mis-tapped "Add" leaves no junk row (and can't CloudKit-sync).
    private func commit() {
        let empty = (type.label ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            && (type.code ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        let unreferenced = (type.instances ?? []).isEmpty
            && (type.rotationSlots ?? []).isEmpty
            && (type.explicitDays ?? []).isEmpty
            && (type.exceptions ?? []).isEmpty
            && (type.codeMappings ?? []).isEmpty
        if empty && unreferenced {
            context.delete(type)
        }
        try? context.save()
    }
}
