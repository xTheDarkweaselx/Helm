//
//  ScheduleEditorView.swift
//  Helm
//
//  The heart of the rota builder: a schedule = a horizon + a timeline of segments
//  (cycles / explicit days) + per-date exceptions. Preview shows the diff vs the
//  calendar; Apply writes through the same engine as imports.
//

import SwiftUI
import SwiftData
import HelmDomain

struct ScheduleEditorView: View {
    @Environment(\.modelContext) private var context
    @Bindable var schedule: Schedule
    @State private var isPreviewing = false

    private var today: Date { Calendar.current.startOfDay(for: .now) }
    private var segments: [ScheduleSegment] {
        (schedule.segments ?? []).sorted { $0.sortIndex < $1.sortIndex }
    }
    private var exceptions: [ScheduleException] {
        (schedule.exceptions ?? []).sorted { ($0.localDate ?? .distantPast) < ($1.localDate ?? .distantPast) }
    }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: Binding(
                    get: { schedule.title ?? "" },
                    set: { schedule.title = $0.isEmpty ? nil : $0 }
                ))
                DatePicker("Horizon from", selection: dateBinding($schedule.horizonStart, default: today), displayedComponents: .date)
                DatePicker("Horizon until", selection: dateBinding($schedule.horizonEnd, default: defaultHorizonEnd),
                           in: (schedule.horizonStart ?? today)..., displayedComponents: .date)
            } header: {
                Text("Schedule")
            } footer: {
                Text("Helm generates shifts between these dates.")
            }

            Section {
                NavigationLink { ShiftTypeLibraryView() } label: {
                    Label("Shift Types", systemImage: "clock")
                }
            }

            Section("Segments (top of list wins on overlap)") {
                ForEach(segments.reversed()) { segment in   // highest sortIndex first
                    NavigationLink { ScheduleSegmentEditorView(segment: segment) } label: {
                        segmentRow(segment)
                    }
                }
                .onDelete { offsets in
                    let shown = segments.reversed().map { $0 }
                    for i in offsets { context.delete(shown[i]) }
                    try? context.save()
                }
                Menu {
                    Button("Repeating cycle") { addSegment(.cyclic) }
                    Button("Explicit days") { addSegment(.explicit) }
                } label: {
                    Label("Add segment", systemImage: "plus")
                }
            }

            Section("Exceptions") {
                ForEach(exceptions) { ex in
                    NavigationLink { ScheduleExceptionEditorView(exception: ex) } label: {
                        exceptionRow(ex)
                    }
                }
                .onDelete { offsets in
                    for i in offsets { context.delete(exceptions[i]) }
                    try? context.save()
                }
                Button("Add exception", systemImage: "plus") { addException() }
            }
        }
        .navigationTitle(schedule.title?.isEmpty == false ? schedule.title! : "Schedule")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Preview & apply", systemImage: "calendar.badge.checkmark") { isPreviewing = true }
            }
        }
        .sheet(isPresented: $isPreviewing) { SchedulePreviewView(schedule: schedule) }
    }

    private var defaultHorizonEnd: Date {
        Calendar.current.date(byAdding: .month, value: 6, to: today) ?? today
    }

    @ViewBuilder
    private func segmentRow(_ segment: ScheduleSegment) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(segment.title ?? (segment.kind == .cyclic ? "Cycle" : "Explicit days"))
                    .font(.subheadline.weight(.medium))
                Text(segment.kind == .cyclic ? "Cycle" : "Explicit")
                    .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Text(rangeText(segment.effectiveFrom, segment.effectiveTo))
                .font(.caption).foregroundStyle(.secondary)
            if segment.kind == .cyclic, let p = segment.pattern {
                cyclePreview(p)
            }
        }
    }

    @ViewBuilder
    private func cyclePreview(_ pattern: RotationPattern) -> some View {
        let slots = (pattern.slots ?? []).sorted { $0.sortIndex < $1.sortIndex }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(slots.prefix(14)) { slot in
                    if slot.isOff || slot.shiftType == nil {
                        Text("·").frame(width: 22, height: 18).background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    } else if let t = slot.shiftType {
                        Text(t.code ?? "?").font(.caption2)
                            .frame(width: 22, height: 18)
                            .background((Color(hex: t.colorHex) ?? .accentColor).opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
    }

    private func exceptionRow(_ ex: ScheduleException) -> some View {
        HStack {
            Text(ex.localDate ?? .now, format: .dateTime.day().month().year())
            Spacer()
            Text(ex.kind.rawValue.capitalized).foregroundStyle(.secondary)
            if let t = ex.shiftType { ShiftTypeChip(label: t.code ?? "?", colorHex: t.colorHex) }
        }
    }

    private func rangeText(_ from: Date?, _ to: Date?) -> String {
        let f = from.map { $0.formatted(.dateTime.day().month()) } ?? "start"
        let t = to.map { $0.formatted(.dateTime.day().month().year()) } ?? "ongoing"
        return "\(f) – \(t)"
    }

    private func addSegment(_ kind: SegmentKind) {
        let nextIndex = (segments.map(\.sortIndex).max() ?? -1) + 1
        let segment = ScheduleSegment(kind: kind, sortIndex: nextIndex)
        segment.effectiveFrom = schedule.horizonStart ?? today
        segment.effectiveTo = schedule.horizonEnd ?? defaultHorizonEnd
        segment.schedule = schedule
        context.insert(segment)
        if kind == .cyclic {
            segment.anchorDate = segment.effectiveFrom
            let pattern = RotationPattern(name: "Cycle", cycleLengthDays: 7)
            context.insert(pattern)
            segment.pattern = pattern
            syncRotationSlots(pattern, context: context) // eager 7 OFF slots
        }
        try? context.save()
    }

    private func addException() {
        let ex = ScheduleException(localDate: today, kind: .swapped)
        ex.schedule = schedule
        context.insert(ex)
        try? context.save()
    }
}

struct ScheduleExceptionEditorView: View {
    @Environment(\.modelContext) private var context
    @Bindable var exception: ScheduleException
    @State private var pickingType = false

    private let kinds: [OverrideKind] = [.modified, .swapped, .added, .cancelled]

    var body: some View {
        Form {
            DatePicker("Date", selection: dateBinding(Binding(get: { exception.localDate }, set: { exception.localDate = $0 }), default: .now), displayedComponents: .date)
            Picker("Action", selection: Binding(get: { exception.kind }, set: { exception.kind = $0 })) {
                ForEach(kinds, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            if exception.kind != .cancelled {
                Section("Shift") {
                    Button { pickingType = true } label: {
                        HStack {
                            Text("Shift")
                            Spacer()
                            if let t = exception.shiftType {
                                ShiftTypeChip(label: t.code ?? t.label ?? "?", colorHex: t.colorHex)
                            } else {
                                Text("Choose…").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Exception")
        .onDisappear { try? context.save() }
        .sheet(isPresented: $pickingType) {
            ShiftTypePickerSheet(allowOff: false) { type in
                exception.shiftType = type
                try? context.save()
            }
        }
    }
}

struct SchedulePreviewView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let schedule: Schedule
    @State private var coordinator = ScheduleCoordinator()
    @State private var previewStyle: ImportView.PreviewStyle = .calendar
    @State private var overlay: PreviewOverlay?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Preview")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
                .task {
                    coordinator.preparePlan(for: schedule, in: context)
                    if let plan = coordinator.plan {
                        overlay = PlanOverlayBuilder.build(from: plan, in: context)
                    }
                }
        }
        #if os(macOS)
        // macOS sheets default tiny — the side-by-side preview needs room.
        .frame(minWidth: 940, idealWidth: 1000, minHeight: 620, idealHeight: 700)
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.phase {
        case .idle:
            ProgressView()
        case .loaded:
            if let plan = coordinator.plan { planView(plan) }
        case .writing:
            ProgressView("Writing to your calendar…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .finished(summary):
            ContentUnavailableView {
                Label("Calendar updated", systemImage: "checkmark.circle.fill")
            } description: {
                Text(summary.userDescription)
            } actions: {
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn’t apply", systemImage: "exclamationmark.triangle")
            } description: { Text(message) }
        }
    }

    private func planView(_ plan: RosterSyncEngine.Plan) -> some View {
        let diff = plan.diff
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("View", selection: $previewStyle) {
                    Label("Calendar", systemImage: "calendar").tag(ImportView.PreviewStyle.calendar)
                    Label("List", systemImage: "list.bullet").tag(ImportView.PreviewStyle.list)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 240)
                Spacer()
                CalendarDestinationPicker()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            // ZStack so toggling never resets the calendar's month/selection.
            ZStack {
                Group {
                    if let overlay {
                        CalendarView(mode: .preview(overlay))
                    } else {
                        ProgressView()
                    }
                }
                .opacity(previewStyle == .calendar ? 1 : 0)
                .allowsHitTesting(previewStyle == .calendar)
                List {
                    Section {
                        LabeledContent("Add", value: "\(diff.added.count)")
                        LabeledContent("Update", value: "\(diff.updated.count)")
                        LabeledContent("Remove", value: "\(diff.removed.count)")
                        LabeledContent("Unchanged", value: "\(diff.unchanged.count)")
                    } header: {
                        Text(plan.isReimport ? "Changes to apply" : "New shifts")
                    }
                }
                .opacity(previewStyle == .list ? 1 : 0)
                .allowsHitTesting(previewStyle == .list)
            }
        }
        .safeAreaInset(edge: .bottom) {
            // With no diff, offer a full re-write instead of a dead button —
            // the restore path after Settings' "Remove Helm events".
            Button {
                Task {
                    if diff.hasChanges {
                        await coordinator.commit(in: context)
                    } else {
                        await coordinator.resyncExisting(for: schedule, in: context)
                    }
                }
            } label: {
                Text(diff.hasChanges ? "Apply to Calendar" : "Re-sync to Calendar").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .padding()
        }
    }
}
