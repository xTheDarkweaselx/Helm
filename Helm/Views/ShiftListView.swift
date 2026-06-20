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

/// How the roster detail lays its shifts out (persisted globally across rosters).
enum RosterViewMode: String, CaseIterable, Identifiable {
    case list, grid, calendar, compact, byType

    static let storageKey = "rosterViewMode"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .list: "List"
        case .grid: "Grid"
        case .calendar: "Calendar"
        case .compact: "Compact"
        case .byType: "By type"
        }
    }

    var systemImage: String {
        switch self {
        case .list: "list.bullet"
        case .grid: "square.grid.2x2"
        case .calendar: "calendar"
        case .compact: "list.dash"
        case .byType: "tag"
        }
    }
}

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
    @State private var isEditingPay = false
    @State private var instanceToRemove: ShiftInstance?
    @State private var editingShift: ShiftInstance?
    @State private var isAddingShift = false
    @AppStorage(RosterViewMode.storageKey) private var viewModeRaw = RosterViewMode.list.rawValue
    // Calendar view mode: the month on screen + the day whose shifts the agenda shows.
    @State private var visibleMonth: MonthKey?
    @State private var selectedCalendarDay: DayKey?

    private var viewMode: RosterViewMode { RosterViewMode(rawValue: viewModeRaw) ?? .list }

    private var calendar: Calendar { CalendarViewModel.displayCalendar }

    private var sortedInstances: [ShiftInstance] {
        (roster.instances ?? []).sorted {
            ($0.localDate ?? .distantPast, $0.sortIndex) < ($1.localDate ?? .distantPast, $1.sortIndex)
        }
    }

    /// Cheap emptiness check — avoids a full sort just to test `.isEmpty`.
    private var hasShifts: Bool { !(roster.instances ?? []).isEmpty }

    /// Shifts grouped by civil month, in date order.
    private var monthGroups: [(month: MonthKey, shifts: [ShiftInstance])] {
        let grouped = Dictionary(grouping: sortedInstances) { instance in
            MonthKey(containing: instance.localDate ?? .distantPast, in: calendar)
        }
        return grouped.keys.sorted().map { (month: $0, shifts: grouped[$0] ?? []) }
    }

    /// Shifts grouped by their shift type (untyped shifts share one group),
    /// sorted by type label. Each group's shifts stay in date order.
    private var typeGroups: [(key: String, label: String, color: Color?, shifts: [ShiftInstance])] {
        // Key on the type's stable identity (NOT code/label, which could collide
        // across two distinct types); all untyped shifts fold into one group.
        let grouped = Dictionary(grouping: sortedInstances) { inst in
            inst.shiftType.map { "\($0.persistentModelID)" } ?? "untyped"
        }
        return grouped.map { key, shifts -> (key: String, label: String, color: Color?, shifts: [ShiftInstance]) in
            let type = shifts.first?.shiftType
            let label = type?.label ?? type?.code ?? "Untyped"
            return (key: key, label: label, color: Color(hex: type?.colorHex), shifts: shifts)
        }
        .sorted { ($0.label.localizedLowercase, $0.key) < ($1.label.localizedLowercase, $1.key) }
    }

    private var rosterFirstDay: DayKey {
        let earliest = (roster.instances ?? []).compactMap(\.localDate).min() ?? .now
        return DayKey(containing: earliest, in: calendar)
    }
    private var displayedMonth: MonthKey { visibleMonth ?? MonthKey(of: rosterFirstDay) }
    private var calendarSelectedDay: Binding<DayKey> {
        Binding(
            get: { selectedCalendarDay ?? rosterFirstDay },
            set: { selectedCalendarDay = $0; visibleMonth = MonthKey(of: $0) }
        )
    }

    // MARK: - View-mode content

    @ViewBuilder
    private var content: some View {
        switch viewMode {
        case .list: listContent
        case .compact: compactContent
        case .byType: byTypeContent
        case .grid: gridContent
        case .calendar: calendarContent
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No shifts", systemImage: "calendar")
        } description: {
            Text("This roster has no shifts yet.")
        } actions: {
            Button("Add shift", systemImage: "plus") { isAddingShift = true }
                .buttonStyle(.borderedProminent)
                .disabled(syncProgress.isActive)
        }
    }

    /// The default: month-grouped detailed rows.
    private var listContent: some View {
        List {
            summarySection
            ForEach(monthGroups, id: \.month) { group in
                Section {
                    ForEach(group.shifts) { instance in
                        listRow(instance) { ShiftRow(instance: instance, accent: accent) }
                    }
                } header: {
                    Text(monthTitle(group.month))
                }
            }
        }
    }

    /// Dense, one-line-per-shift rows, still month-grouped.
    private var compactContent: some View {
        List {
            summarySection
            ForEach(monthGroups, id: \.month) { group in
                Section {
                    ForEach(group.shifts) { instance in
                        listRow(instance) { CompactShiftRow(instance: instance, accent: accent) }
                    }
                } header: {
                    Text(monthTitle(group.month))
                }
            }
        }
    }

    /// Sections grouped by shift type instead of by month.
    private var byTypeContent: some View {
        List {
            summarySection
            ForEach(typeGroups, id: \.key) { group in
                Section {
                    ForEach(group.shifts) { instance in
                        listRow(instance) { ShiftRow(instance: instance, accent: accent) }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Circle().fill(group.color ?? accent).frame(width: 8, height: 8)
                        Text(group.label)
                        Text("(\(group.shifts.count))").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Responsive grid of compact shift cards, grouped by month.
    private var gridContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                summaryCard
                ForEach(monthGroups, id: \.month) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(monthTitle(group.month))
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                            ForEach(group.shifts) { instance in
                                ShiftCard(instance: instance, accent: accent)
                                    .contentShape(RoundedRectangle(cornerRadius: 12))
                                    .onTapGesture { editShift(instance) }
                                    .contextMenu { shiftContextMenu(instance) }
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    /// This roster's shifts on a month grid, with the selected day's agenda below.
    private var calendarContent: some View {
        // Shared bucketer: items (correct overnight flag) feed the grid chips;
        // instances feed the agenda (it edits/removes the real ShiftInstance).
        let sorted = sortedInstances
        let itemsByDay = ShiftBucketer.itemsByDay(sorted)
        let instancesByDay = ShiftBucketer.byDay(sorted) { instance, _ in instance }
        let today = DayKey(containing: .now, in: calendar)
        return VStack(spacing: 8) {
            calendarHeader
            weekdayHeaderRow
            MonthGridView(
                grid: MonthGrid.make(month: displayedMonth, calendar: calendar),
                selectedDay: calendarSelectedDay,
                today: today,
                compact: false,
                cellHeight: 64,
                dayContent: { day in
                    DayCellSummary(shifts: itemsByDay[day] ?? [],
                                   previews: [], eventCount: 0, eventColors: [], hasConflict: false)
                }
            )
            Divider()
            calendarAgenda(byDay: instancesByDay)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private var calendarHeader: some View {
        HStack {
            Text(displayedMonth.start(in: calendar), format: .dateTime.month(.wide).year())
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Spacer()
            Button { visibleMonth = displayedMonth.advanced(by: -1) } label: {
                Label("Previous month", systemImage: "chevron.left").labelStyle(.iconOnly)
            }
            Button("Today") {
                let t = DayKey(containing: .now, in: calendar)
                selectedCalendarDay = t
                visibleMonth = MonthKey(of: t)
            }
            Button { visibleMonth = displayedMonth.advanced(by: 1) } label: {
                Label("Next month", systemImage: "chevron.right").labelStyle(.iconOnly)
            }
        }
        .buttonStyle(.borderless)
    }

    private var weekdayHeaderRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(CalendarGridMath.orderedWeekdaySymbols(calendar).enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func calendarAgenda(byDay: [DayKey: [ShiftInstance]]) -> some View {
        let day = calendarSelectedDay.wrappedValue
        let shifts = byDay[day] ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(day.startOfDay(in: calendar), format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if shifts.isEmpty {
                    Text("No shifts on this day.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(shifts) { instance in
                        ShiftRow(instance: instance, accent: accent)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)
                            .glassCard(cornerRadius: 12)
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                            .onTapGesture { editShift(instance) }
                            .contextMenu { shiftContextMenu(instance) }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Shared row interactions

    private func editShift(_ instance: ShiftInstance) {
        guard !syncProgress.isActive else { return }
        editingShift = instance
    }

    /// A List row with the standard tap-to-edit, swipe-to-remove, and right-click
    /// menu — shared by the list / compact / by-type modes.
    @ViewBuilder
    private func listRow<V: View>(_ instance: ShiftInstance, @ViewBuilder _ row: () -> V) -> some View {
        row()
            .contentShape(Rectangle())
            .onTapGesture { editShift(instance) }
            .swipeActions {
                Button("Remove", systemImage: "trash", role: .destructive) {
                    instanceToRemove = instance
                }
                .disabled(syncProgress.isActive)
            }
            .contextMenu { shiftContextMenu(instance) }
    }

    @ViewBuilder
    private func shiftContextMenu(_ instance: ShiftInstance) -> some View {
        Button("Edit shift…", systemImage: "pencil") { editShift(instance) }
            .disabled(syncProgress.isActive)
        Button("Remove shift…", systemImage: "trash", role: .destructive) {
            instanceToRemove = instance
        }
        .disabled(syncProgress.isActive)
    }

    var body: some View {
        Group {
            if hasShifts {
                content
            } else {
                emptyState
            }
        }
        .navigationTitle(roster.title ?? "Roster")
        .toolbar {
            if hasShifts {
                ToolbarItem {
                    Menu {
                        Picker("View", selection: $viewModeRaw) {
                            ForEach(RosterViewMode.allCases) { mode in
                                Label(mode.label, systemImage: mode.systemImage).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.inline) // options inline (with checkmarks), not a submenu
                    } label: {
                        Label("View as \(viewMode.label)", systemImage: viewMode.systemImage)
                    }
                    .menuIndicator(.hidden)
                }
            }
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
                    Button("Reminders & wake-up alarm…", systemImage: "bell.badge") {
                        isEditingReminders = true
                    }
                    Button("Pay & employer…", systemImage: "sterlingsign.circle") {
                        isEditingPay = true
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
        .navigationDestination(isPresented: $isEditingPay) {
            RosterPayView(roster: roster)
        }
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

    /// The stats block, shared by the List section and the grid's glass card.
    @ViewBuilder
    private var summaryContent: some View {
        let stats = rosterStats()
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
    }

    /// Summary as a List section (list / compact / by-type modes).
    private var summarySection: some View {
        Section {
            summaryContent
                .padding(.vertical, 4)
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
        }
    }

    /// Summary as a standalone glass card (grid mode).
    private var summaryCard: some View {
        summaryContent
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 14)
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
        let instances = roster.instances ?? [] // order-independent (sum + min/max below)
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
        let dates = instances.compactMap(\.localDate)
        if let first = dates.min(), let last = dates.max() {
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

// MARK: - Compact + grid rows

/// A short times label for the compact / grid layouts: resolved wall-clock times
/// in the shift's own zone, or a status word (TBC / All-day / Off / —). The
/// optional tint highlights an awaiting-times (TBC) shift.
private func shiftTimesLabel(_ instance: ShiftInstance) -> (text: String, tint: Color?) {
    if instance.isAllDay == true {
        return instance.overrideKind == .none ? ("Times TBC", .orange) : ("All-day", nil)
    }
    if let start = instance.startUTC, let end = instance.endUTC, end > start {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: instance.timeZoneIdentifier) ?? .current
        func hm(_ date: Date) -> String {
            let c = cal.dateComponents([.hour, .minute], from: date)
            return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        }
        return ("\(hm(start))–\(hm(end))", nil)
    }
    if instance.shiftType?.workKind == .off { return ("Off", nil) }
    return ("—", nil)
}

/// Dense one-line row: colour bar · weekday/day · title · times. Used by Compact.
private struct CompactShiftRow: View {
    let instance: ShiftInstance
    let accent: Color

    private var typeColor: Color { Color(hex: instance.shiftType?.colorHex) ?? accent }

    var body: some View {
        let times = shiftTimesLabel(instance)
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(typeColor).frame(width: 3, height: 20)
            if let date = instance.localDate {
                Text(date, format: .dateTime.weekday(.abbreviated).day())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7) // scale down rather than wrap at large Dynamic Type
                    .frame(width: 58, alignment: .leading)
            }
            Text(instance.title ?? instance.shiftType?.label ?? instance.shiftType?.code ?? "Shift")
                .font(.subheadline)
                .lineLimit(1)
            if instance.overrideKind != .none {
                Image(systemName: instance.overrideKind == .added ? "plus.circle.fill" : "pencil.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(instance.overrideKind == .added ? "Added by you" : "Edited by you")
            }
            Spacer(minLength: 8)
            Text(times.text)
                .font(.caption.monospacedDigit())
                .foregroundStyle(times.tint ?? .secondary)
        }
        .padding(.vertical, 1)
    }
}

/// A compact card for the grid: type dot · weekday/day, title, times, location.
private struct ShiftCard: View {
    let instance: ShiftInstance
    let accent: Color

    private var typeColor: Color { Color(hex: instance.shiftType?.colorHex) ?? accent }

    var body: some View {
        let times = shiftTimesLabel(instance)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(typeColor).frame(width: 8, height: 8)
                if let date = instance.localDate {
                    Text(date, format: .dateTime.weekday(.abbreviated).day())
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                if instance.overrideKind != .none {
                    Image(systemName: instance.overrideKind == .added ? "plus.circle.fill" : "pencil.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(instance.overrideKind == .added ? "Added by you" : "Edited by you")
                }
            }
            Text(instance.title ?? instance.shiftType?.label ?? instance.shiftType?.code ?? "Shift")
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(times.text)
                .font(.caption.monospacedDigit())
                .foregroundStyle(times.tint ?? .secondary)
            if let location = instance.locationName, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .glassCard(cornerRadius: 12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(typeColor.opacity(0.35), lineWidth: 1)
        )
    }
}
