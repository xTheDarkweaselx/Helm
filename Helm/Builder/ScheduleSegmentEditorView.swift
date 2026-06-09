//
//  ScheduleSegmentEditorView.swift
//  Helm
//
//  Edit one timeline segment: a repeating cycle (date-bounded, anchored) or an
//  explicit list of dated days.
//

import SwiftUI
import SwiftData

struct ScheduleSegmentEditorView: View {
    @Environment(\.modelContext) private var context
    @Bindable var segment: ScheduleSegment

    @State private var pickingDay: ExplicitDay?

    private var today: Date { Calendar.current.startOfDay(for: .now) }

    var body: some View {
        Form {
            Section {
                TextField("Title (optional)", text: Binding(
                    get: { segment.title ?? "" },
                    set: { segment.title = $0.isEmpty ? nil : $0 }
                ))
                DatePicker("From", selection: dateBinding($segment.effectiveFrom, default: today), displayedComponents: .date)
                DatePicker("Until", selection: dateBinding($segment.effectiveTo, default: today), displayedComponents: .date)
                TextField("Location (optional)", text: Binding(
                    get: { segment.locationName ?? "" },
                    set: { segment.locationName = $0.isEmpty ? nil : $0 }
                ))
            } header: {
                Text(segment.kind == .cyclic ? "Repeating cycle" : "Explicit days")
            }

            if segment.kind == .cyclic {
                cyclicSection
            } else {
                explicitSection
            }
        }
        .navigationTitle(segment.title ?? (segment.kind == .cyclic ? "Cycle segment" : "Explicit segment"))
        .onDisappear { try? context.save() }
        .sheet(item: $pickingDay) { day in
            ShiftTypePickerSheet { type in
                day.shiftType = type
                day.isOff = (type == nil)
                try? context.save()
            }
        }
    }

    // MARK: - Cyclic

    @ViewBuilder
    private var cyclicSection: some View {
        Section("Anchor") {
            DatePicker("Cycle starts on", selection: dateBinding($segment.anchorDate, default: segment.effectiveFrom ?? today), displayedComponents: .date)
            Stepper("Start \(segment.dayOffset) day\(segment.dayOffset == 1 ? "" : "s") into the cycle",
                    value: $segment.dayOffset, in: 0...90)
        }
        Section("Cycle") {
            if let pattern = segment.pattern {
                NavigationLink {
                    RotationPatternEditorView(pattern: pattern)
                } label: {
                    LabeledContent(pattern.name ?? "Cycle", value: "\(pattern.cycleLengthDays) days")
                }
            } else {
                Button("Create cycle") {
                    let p = RotationPattern(name: segment.title ?? "Cycle", cycleLengthDays: 7)
                    context.insert(p)
                    segment.pattern = p
                    try? context.save()
                }
            }
        }
    }

    // MARK: - Explicit

    private var explicitDays: [ExplicitDay] {
        (segment.explicitDays ?? []).sorted { ($0.localDate ?? .distantPast) < ($1.localDate ?? .distantPast) }
    }

    @ViewBuilder
    private var explicitSection: some View {
        Section {
            ForEach(explicitDays) { day in
                HStack {
                    DatePicker("", selection: dateBinding(Binding(get: { day.localDate }, set: { day.localDate = $0 }), default: today), displayedComponents: .date)
                        .labelsHidden()
                    Spacer()
                    Button { pickingDay = day } label: { dayTypeLabel(day) }
                        .buttonStyle(.plain)
                }
            }
            .onDelete { offsets in
                let days = explicitDays
                for i in offsets { context.delete(days[i]) }
                try? context.save()
            }
            Button("Add day", systemImage: "plus") {
                let day = ExplicitDay(localDate: today)
                day.segment = segment
                context.insert(day)
                try? context.save()
            }
        } header: {
            Text("Days")
        } footer: {
            Text("Add specific dated shifts — e.g. self-study or one-off days.")
        }
    }

    @ViewBuilder
    private func dayTypeLabel(_ day: ExplicitDay) -> some View {
        if day.isOff || day.shiftType == nil {
            Text("Off").foregroundStyle(.secondary)
        } else if let t = day.shiftType {
            ShiftTypeChip(label: t.code ?? t.label ?? "?", colorHex: t.colorHex)
        }
    }
}
