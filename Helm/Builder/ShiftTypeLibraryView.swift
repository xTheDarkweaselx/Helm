//
//  ShiftTypeLibraryView.swift
//  Helm
//
//  Manage the shared shift-type vocabulary (Morning 06:30–13:30, etc.) used by
//  cycles, explicit days and exceptions.
//

import SwiftUI
import SwiftData

private enum ShiftTypeEditTarget: Identifiable {
    case new
    case edit(ShiftType)
    var id: String { switch self { case .new: "new"; case .edit(let t): t.id } }
    var type: ShiftType? { switch self { case .new: nil; case .edit(let t): t } }
}

struct ShiftTypeLibraryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ShiftType.code) private var types: [ShiftType]
    @Query(sort: \ShiftCodeMapping.rawCode) private var learnedMappings: [ShiftCodeMapping]
    @State private var editing: ShiftTypeEditTarget?
    @State private var pendingDeletion: [ShiftType] = []

    var body: some View {
        List {
            ForEach(types) { type in
                Button { editing = .edit(type) } label: { row(type) }
                    .buttonStyle(.plain)
            }
            .onDelete { offsets in
                let targets = offsets.map { types[$0] }
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
                    Text("Taught during imports — each applies to its own roster source. Forget one and the next import will ask again.")
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
            Text("This is used by \(pendingRefCount) day\(pendingRefCount == 1 ? "" : "s") in your cycles/schedules. Deleting it turns those days off on the next update.")
        }
        .navigationTitle("Shift Types")
        .overlay {
            if types.isEmpty {
                ContentUnavailableView("No shift types", systemImage: "clock",
                    description: Text("Add the shifts you work — e.g. Morning 06:30–13:30."))
            }
        }
        .toolbar {
            ToolbarItem { Button("Add shift type", systemImage: "plus") { editing = .new } }
        }
        .sheet(item: $editing) { target in
            ShiftTypeEditorView(existing: target.type)
        }
    }

    private var pendingRefCount: Int { pendingDeletion.reduce(0) { $0 + referenceCount($1) } }

    private func referenceCount(_ type: ShiftType) -> Int {
        (type.rotationSlots?.count ?? 0) + (type.explicitDays?.count ?? 0) + (type.exceptions?.count ?? 0)
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
        HStack {
            ShiftTypeChip(label: type.code ?? type.label ?? "?", colorHex: type.colorHex)
            VStack(alignment: .leading, spacing: 1) {
                Text(type.label ?? type.code ?? "Shift").foregroundStyle(.primary)
                if let loc = type.locationName, !loc.isEmpty {
                    Text(loc).font(.caption).foregroundStyle(.secondary)
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

struct ShiftTypeEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let existing: ShiftType?

    @State private var label = ""
    @State private var code = ""
    @State private var startMinute = 9 * 60
    @State private var endMinute = 17 * 60
    @State private var endsNextDay = false
    @State private var breakMinutes = 0
    @State private var workKind: WorkKind = .worked
    @State private var color = Color.accentColor
    @State private var location = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Label (e.g. Morning)", text: $label)
                    TextField("Code (e.g. M)", text: $code)
                }
                if workKind != .off {
                    Section("Times") {
                        DatePicker("Start", selection: timeOfDayBinding($startMinute), displayedComponents: .hourAndMinute)
                        DatePicker("End", selection: timeOfDayBinding($endMinute), displayedComponents: .hourAndMinute)
                        Toggle("Ends next day (overnight)", isOn: $endsNextDay)
                        Stepper("Unpaid break: \(breakMinutes) min", value: $breakMinutes, in: 0...240, step: 15)
                        LabeledContent("Paid duration", value: durationText)
                    }
                }
                Section("Details") {
                    Picker("Kind", selection: $workKind) {
                        ForEach(WorkKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    ColorPicker("Colour", selection: $color, supportsOpacity: false)
                    TextField("Default location", text: $location)
                }
            }
            .navigationTitle(existing == nil ? "New Shift Type" : "Edit Shift Type")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(label.isEmpty && code.isEmpty)
                }
            }
            .onAppear(perform: prefill)
        }
    }

    private var durationText: String {
        var endTotal = endMinute + (endsNextDay ? 1440 : 0)
        if endTotal <= startMinute { endTotal += 1440 } // overnight
        let mins = max(0, endTotal - startMinute - breakMinutes)
        return String(format: "%.2gh", Double(mins) / 60)
    }

    private func prefill() {
        guard let t = existing else { return }
        label = t.label ?? ""
        code = t.code ?? ""
        startMinute = t.startMinuteOfDay
        endMinute = t.endMinuteOfDay
        endsNextDay = t.endDayOffset > 0
        breakMinutes = t.breakMinutes
        workKind = t.workKind
        color = Color(hex: t.colorHex) ?? .accentColor
        location = t.locationName ?? ""
    }

    private func save() {
        let t = existing ?? ShiftType()
        t.label = label.isEmpty ? nil : label
        t.code = code.isEmpty ? nil : code.uppercased()
        t.startMinuteOfDay = startMinute
        t.endMinuteOfDay = endMinute
        t.endDayOffset = endsNextDay ? 1 : 0
        t.breakMinutes = breakMinutes
        t.workKind = workKind
        t.colorHex = color.hexString
        t.locationName = location.isEmpty ? nil : location
        if existing == nil { context.insert(t) }
        try? context.save()
        dismiss()
    }
}
