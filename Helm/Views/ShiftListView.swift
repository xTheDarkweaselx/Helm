//
//  ShiftListView.swift
//  Helm
//
//  Detail pane: the shifts of a selected roster. v7.3 redesign — a glass
//  summary header (shifts/hours/TBC/range), month-grouped sections, modern
//  rows (type colour bar, tags, notes, TBC + overnight + edited badges), and
//  the roster is now EDITABLE: tap a shift to edit it (set real times on a
//  TBC), add one-off shifts into this roster, or re-import an updated file —
//  all in-window pushes, never sheets.
//

import SwiftUI
import SwiftData
import HelmCalendar
import HelmDomain

struct ShiftListView: View {
    let roster: Roster
    /// Called after the roster (and its events) are gone — the host navigates
    /// away instead of leaving a stale placeholder.
    var onDeleted: () -> Void = {}
    /// Routes to the import flow (re-import the source / an updated version).
    var onImportUpdate: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Environment(SyncProgress.self) private var syncProgress
    @Environment(\.helmAccent) private var accent
    @State private var isConfirmingDelete = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var applyingReminders = false
    @State private var icsURL: URL?
    @State private var isEditingReminders = false
    @State private var instanceToRemove: ShiftInstance?
    @State private var editingShift: ShiftInstance?
    @State private var isAddingShift = false

    private var calendar: Calendar { CalendarViewModel.displayCalendar }

    private var sortedInstances: [ShiftInstance] {
        (roster.instances ?? []).sorted {
            ($0.localDate ?? .distantPast, $0.sortIndex) < ($1.localDate ?? .distantPast, $1.sortIndex)
        }
    }

    /// Shifts grouped by civil month, in date order.
    private var monthGroups: [(month: MonthKey, shifts: [ShiftInstance])] {
        let grouped = Dictionary(grouping: sortedInstances) { instance in
            MonthKey(containing: instance.localDate ?? .distantPast, in: calendar)
        }
        return grouped.keys.sorted().map { (month: $0, shifts: grouped[$0] ?? []) }
    }

    var body: some View {
        Group {
            if sortedInstances.isEmpty {
                ContentUnavailableView {
                    Label("No shifts", systemImage: "calendar")
                } description: {
                    Text("This roster has no shifts yet.")
                } actions: {
                    Button("Add shift", systemImage: "plus") { isAddingShift = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(syncProgress.isActive)
                }
            } else {
                List {
                    summarySection
                    ForEach(monthGroups, id: \.month) { group in
                        Section {
                            ForEach(group.shifts) { instance in
                                ShiftRow(instance: instance, accent: accent)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        guard !syncProgress.isActive else { return }
                                        editingShift = instance
                                    }
                                    .swipeActions {
                                        Button("Remove", systemImage: "trash", role: .destructive) {
                                            instanceToRemove = instance
                                        }
                                        .disabled(syncProgress.isActive)
                                    }
                                    .contextMenu { // right-click parity on macOS
                                        Button("Edit shift…", systemImage: "pencil") {
                                            editingShift = instance
                                        }
                                        .disabled(syncProgress.isActive)
                                        Button("Remove shift…", systemImage: "trash", role: .destructive) {
                                            instanceToRemove = instance
                                        }
                                        .disabled(syncProgress.isActive)
                                    }
                            }
                        } header: {
                            Text(monthTitle(group.month))
                        }
                    }
                }
            }
        }
        .navigationTitle(roster.title ?? "Roster")
        .toolbar {
            ToolbarItem {
                Button("Add shift", systemImage: "plus") { isAddingShift = true }
                    .disabled(syncProgress.isActive)
            }
            ToolbarItem {
                Menu {
                    if let icsURL {
                        ShareLink("Export .ics", item: icsURL)
                    }
                    Button("Import updated file…", systemImage: "square.and.arrow.down") {
                        onImportUpdate()
                    }
                    Button("Reminders for this roster…", systemImage: "bell.badge") {
                        isEditingReminders = true
                    }
                    // Full rewrite of every event — also the restore path after
                    // "Remove Helm events" in Settings (re-import alone sees
                    // unchanged shifts and writes nothing).
                    Button("Re-sync all shifts to calendar", systemImage: "arrow.triangle.2.circlepath") {
                        applyReminders()
                    }
                    .disabled(applyingReminders || syncProgress.isActive)
                    Divider()
                    Button("Remove from Calendar & delete", systemImage: "trash", role: .destructive) {
                        isConfirmingDelete = true
                    }
                    .disabled(syncProgress.isActive)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Delete this roster and remove its events from your calendar?",
                            isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete roster & events", role: .destructive) {
                let roster = roster
                let context = modelContext
                Task {
                    do {
                        let destinations = RosterSyncEngine.destinations(for: roster, in: context)
                        let targets = try await CalendarTargetProvider.authorizedTargets(for: destinations)
                        try await RosterSyncEngine.delete(roster: roster, targets: targets, in: context)
                        onDeleted()
                    } catch CalendarAccessError.eventKitDenied {
                        errorMessage = "Helm needs calendar access to remove these events. Enable it for Helm in Settings, then try again."
                    } catch {
                        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Something went wrong", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("Reminders updated", isPresented: .constant(infoMessage != nil)) {
            Button("OK") { infoMessage = nil }
        } message: {
            Text(infoMessage ?? "")
        }
        // Regenerate the shareable .ics off the render path whenever the content
        // or the reminder setting changes (never during body evaluation).
        .task(id: rosterSignature) { await refreshICS() }
        // In-window pushes (no sheets): reminders, shift editor, add-shift.
        .navigationDestination(isPresented: $isEditingReminders) {
            RosterRemindersView(roster: roster) {
                applyReminders() // push the new offsets onto existing events
            }
        }
        .navigationDestination(item: $editingShift) { instance in
            ShiftEditorView(instance: instance)
        }
        .navigationDestination(isPresented: $isAddingShift) {
            QuickAddShiftView(dateISO: "", rosterID: roster.id, onDone: { _ in isAddingShift = false })
        }
        .themedPane() // v7.1 wash
        .confirmationDialog(
            "Remove this shift from your calendar and from Helm?",
            isPresented: Binding(get: { instanceToRemove != nil }, set: { if !$0 { instanceToRemove = nil } }),
            titleVisibility: .visible,
            presenting: instanceToRemove
        ) { instance in
            Button("Remove shift", role: .destructive) { remove(instance) }
            Button("Cancel", role: .cancel) {}
        } message: { instance in
            Text("“\(instance.title ?? "Shift")” will be deleted from the calendar and from this roster. Re-importing the file or re-applying its schedule would add it back.")
        }
    }

    // MARK: - Summary header

    @ViewBuilder
    private var summarySection: some View {
        let stats = rosterStats()
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    summaryStat(value: "\(stats.count)", caption: "shifts")
                    summaryStat(value: stats.hours.formatted(.number.precision(.fractionLength(0...1))) + " h", caption: "scheduled")
                    if stats.tbc > 0 {
                        summaryStat(value: "\(stats.tbc)", caption: "TBC", tint: .orange)
                    }
                    if stats.edited > 0 {
                        summaryStat(value: "\(stats.edited)", caption: "edited")
                    }
                    Spacer(minLength: 0)
                }
                if let range = stats.rangeText {
                    Label(range, systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
        }
    }

    private func summaryStat(value: String, caption: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func rosterStats() -> (count: Int, hours: Double, tbc: Int, edited: Int, rangeText: String?) {
        let instances = sortedInstances
        var hours = 0.0
        var tbc = 0
        var edited = 0
        for instance in instances {
            if instance.isAllDay == true {
                // "TBC" means an IMPORTED tentative row; a user-made all-day
                // shift (.added/.modified) is deliberate, not awaiting times.
                if instance.overrideKind == .none { tbc += 1 }
            } else if let paid = instance.computedPaidHours {
                hours += paid
            } else if let s = instance.startUTC, let e = instance.endUTC, e > s {
                hours += e.timeIntervalSince(s) / 3600
            }
            if instance.overrideKind != .none { edited += 1 }
        }
        var rangeText: String?
        if let first = instances.first?.localDate, let last = instances.last?.localDate {
            let f = first.formatted(.dateTime.day().month())
            let l = last.formatted(.dateTime.day().month().year())
            rangeText = first == last ? l : "\(f) – \(l)"
        }
        return (instances.count, hours, tbc, edited, rangeText)
    }

    private func monthTitle(_ month: MonthKey) -> String {
        month.start(in: calendar).formatted(.dateTime.month(.wide).year())
    }

    // MARK: - Actions (unchanged behaviour)

    private func remove(_ instance: ShiftInstance) {
        let context = modelContext
        Task {
            do {
                let destinations = RosterSyncEngine.destinations(for: roster, in: context)
                let targets = try await CalendarTargetProvider.authorizedTargets(for: destinations)
                try await RosterSyncEngine.removeInstance(instance, targets: targets, in: context)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Changes when any shift's identity/title/times/all-day/location or the
    /// reminder default changes (drives .ics regeneration — the editor can now
    /// change end/location/all-day without touching title/start).
    private var rosterSignature: String {
        let parts: [String] = (roster.instances ?? []).map { inst in
            let key = inst.dedupKey ?? inst.id
            let title = inst.title ?? ""
            let start = Int(inst.startUTC?.timeIntervalSince1970 ?? 0)
            let end = Int(inst.endUTC?.timeIntervalSince1970 ?? 0)
            let allDay = inst.isAllDay == true ? "1" : "0"
            let location = inst.locationName ?? ""
            return "\(key)|\(title)|\(start)|\(end)|\(allDay)|\(location)"
        }
        let joined = parts.sorted().joined(separator: ";")
        let offsets = ReminderOffsets.encode(RosterSyncEngine.effectiveReminderOffsets(for: roster))
        return "\(joined)#\(offsets)"
    }

    private func refreshICS() async {
        let drafts = RosterSyncEngine.drafts(for: roster) // main-actor read of @Model
        guard !drafts.isEmpty else { icsURL = nil; return }
        let name = roster.title ?? "Helm Shifts"
        let subdir = roster.id
        icsURL = await Task.detached(priority: .utility) {
            Self.writeICS(drafts: drafts, name: name, subdir: subdir)
        }.value
    }

    /// Serialize + write the .ics off the main actor. Per-roster temp subdir avoids
    /// cross-roster collisions and accumulation; the name is sanitized.
    nonisolated private static func writeICS(drafts: [CalendarEventDraft], name: String, subdir: String) -> URL? {
        let ics = ICSExporter.export(drafts, calendarName: name, generatedAt: .now)
        var safe = name
            .components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if safe.isEmpty { safe = "roster" }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("helm-ics/\(subdir)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(safe).ics")
            try Data(ics.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func applyReminders() {
        let roster = roster
        applyingReminders = true
        Task {
            defer { applyingReminders = false }
            do {
                let destinations = RosterSyncEngine.destinations(for: roster, in: modelContext)
                let targets = try await CalendarTargetProvider.authorizedTargets(for: destinations)
                let n = try await RosterSyncEngine.resync(roster: roster, targets: targets)
                infoMessage = n == 0
                    ? "This roster has no shifts to update."
                    : "Reminders applied to \(n) shift\(n == 1 ? "" : "s")."
            } catch CalendarAccessError.eventKitDenied {
                errorMessage = "Helm needs calendar access to update reminders. Enable it for Helm in Settings, then try again."
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

// MARK: - Row

private struct ShiftRow: View {
    let instance: ShiftInstance
    let accent: Color

    private var typeColor: Color {
        Color(hex: instance.shiftType?.colorHex) ?? accent
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(typeColor)
                .frame(width: 4)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(instance.title ?? instance.shiftType?.label ?? instance.shiftType?.code ?? "Shift")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    switch instance.overrideKind {
                    case .added:
                        Image(systemName: "plus.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Added by you")
                    case .modified, .swapped, .cancelled:
                        Image(systemName: "pencil.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Edited by you")
                    case .none:
                        EmptyView()
                    }
                }
                if let location = instance.locationName, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let type = instance.shiftType, !type.tags.isEmpty {
                    TagPillRow(tags: type.tags, colorFor: { type.colorHex(forTag: $0) })
                }
                if let note = instance.note, !note.isEmpty {
                    Label(note, systemImage: "note.text")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                if let date = instance.localDate {
                    Text(date, format: .dateTime.weekday().day())
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                }
                timeBadge
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var timeBadge: some View {
        if instance.isAllDay == true {
            if instance.overrideKind == .none {
                // Imported without times — genuinely awaiting confirmation.
                Text("Times TBC")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.16), in: Capsule())
                    .foregroundStyle(.orange)
            } else {
                // Deliberately all-day (user-added/edited) — not a warning.
                Text("All-day")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let start = instance.startUTC, let end = instance.endUTC, end > start {
            // Resolved times win even over an "off" type — the user confirmed
            // them in the editor, so show them.
            HStack(spacing: 3) {
                Text("\(timeText(start))–\(timeText(end))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if endsOnLaterDay(start, end) {
                    Text("+1")
                        .font(.caption2.weight(.bold)) // relative → scales with Dynamic Type
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(typeColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(typeColor)
                        .accessibilityLabel("Ends the next day")
                }
            }
        } else if instance.shiftType?.workKind == .off {
            Text("Off")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("—").font(.caption).foregroundStyle(.tertiary)
        }
    }

    /// Wall-clock in the SHIFT's own zone (edited shifts may differ from the
    /// type's template times, so never derive from the type here).
    private func timeText(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: instance.timeZoneIdentifier) ?? .current
        let c = cal.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private func endsOnLaterDay(_ start: Date, _ end: Date) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: instance.timeZoneIdentifier) ?? .current
        // Exclusive-midnight rule (same as the calendar): ending exactly at
        // 00:00 belongs to the PREVIOUS day, so it isn't "+1".
        let effectiveEnd = end == cal.startOfDay(for: end) ? end.addingTimeInterval(-1) : end
        return !cal.isDate(start, inSameDayAs: effectiveEnd)
    }
}
