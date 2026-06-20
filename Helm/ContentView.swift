//
//  ContentView.swift
//  Helm
//
//  Created by Adam Ibrahim on 08/06/2026.
//

import SwiftUI
import SwiftData
import Combine // NotificationCenter publisher (MemberImportVisibility)
import HelmDomain // DayKey (calendar-jump from search)

/// The app's universal shell: a `NavigationSplitView` (ADR-12) with a permanent,
/// feature-structured sidebar (standard Mac design): Overview + Shift Types up
/// top, then the user's Rosters and Schedules. First-launch onboarding lives in
/// the DETAIL pane (Overview), never squeezed into the sidebar column.
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Roster.createdAt, order: .reverse) private var rosters: [Roster]
    @Query(sort: \Schedule.createdAt, order: .reverse) private var schedules: [Schedule]
    @Query private var importProfiles: [ImportProfile]

    /// Profiles that back a built schedule (so their materialized Roster is shown
    /// under "Schedules", not duplicated under "Rosters").
    private var scheduleProfileIDs: Set<String> {
        Set(importProfiles.filter { ($0.sourceFingerprint ?? "").hasPrefix("schedule:") }.map(\.id))
    }
    private var importedRosters: [Roster] {
        rosters.filter { !scheduleProfileIDs.contains($0.sourceImportProfileID ?? "") }
    }

    enum Selection: Hashable {
        case overview
        /// v7: carries an optional day so a search result can jump to it.
        case calendar(DayKey?)
        case shiftTypes
        case search
        case settings
        /// Not a sidebar row — entered from toolbar/Overview actions. Keeping
        /// the import IN the main window (no sheet) keeps the design coherent.
        case importer
        case roster(String)
        case schedule(String)
        /// v7 planning hub (time off + availability).
        case planning
        /// v8 pay & timesheets.
        case timesheet
        /// v7 one-off shift. Carries an ISO "yyyy-MM-dd" seed ("" = today).
        case quickAddShift(String)
    }

    @State private var selection: Selection? = .overview
    // v9 Modules — hide switched-off secondary features (default ON).
    @AppStorage("module_pay") private var payModule = true
    @AppStorage("module_planning") private var planningModule = true
    @State private var deleteErrorMessage: String?
    @State private var scheduleAwaitingForcedDelete: Schedule?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SyncProgress.self) private var syncProgress
    @Environment(ThemeManager.self) private var theme
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    /// Whether a sidebar row should read as selected (Calendar lights for ANY
    /// calendar day; rosters/schedules match by id).
    private func rowSelected(_ value: Selection) -> Bool {
        switch (selection, value) {
        case (.calendar, .calendar): return true
        case let (.roster(a), .roster(b)): return a == b
        case let (.schedule(a), .schedule(b)): return a == b
        default: return selection == value
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("Helm")
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
                #endif
                .toolbar { toolbarContent }
        } detail: {
            NavigationStack { detail }
                // v7.2: bulk calendar work (import/delete/re-sync) reports
                // progress here — centred on the CONTENT pane (window-centred
                // read as off-centre next to the sidebar), never blocking.
                .overlay(alignment: .bottom) {
                    SyncProgressHUD().padding(.bottom, 14).padding(.horizontal, 16)
                }
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 440)
        #endif
        .alert(
            "Couldn't remove this schedule's shifts",
            isPresented: .constant(scheduleAwaitingForcedDelete != nil),
            presenting: scheduleAwaitingForcedDelete
        ) { schedule in
            Button("Delete anyway (leave events)", role: .destructive) {
                scheduleAwaitingForcedDelete = nil
                deleteSchedule(schedule, force: true)
            }
            Button("Cancel", role: .cancel) { scheduleAwaitingForcedDelete = nil }
        } message: { _ in
            Text(deleteErrorMessage ?? "Its calendar isn't reachable right now. Deleting anyway leaves the events behind.")
        }
        // Keep the synchronous Google sign-in flags honest with the Keychain
        // truth (they diverge across reinstalls).
        .task { await GoogleAuthService.shared.reconcileMirror() }
        // Siri/Shortcuts "Show my Helm calendar" (v6). The pending flag covers
        // cold launches where the intent ran before this view subscribed.
        .onReceive(NotificationCenter.default.publisher(for: .helmOpenCalendar)) { _ in
            selection = .calendar(nil)
        }
        // If a module is switched off while you're on its screen, step back to Overview.
        .onChange(of: payModule) { _, on in if !on, selection == .timesheet { selection = .overview } }
        .onChange(of: planningModule) { _, on in if !on, selection == .planning { selection = .overview } }
        .task {
            if PendingRoute.openCalendar {
                PendingRoute.openCalendar = false
                selection = .calendar(nil)
            }
        }
        // Keep the home/lock-screen widget snapshot fresh (no-ops until the
        // App Group is configured) — on launch and whenever we re-foreground
        // (so "today"/week roll-overs republish).
        .task { SnapshotWriter.refresh(context: modelContext) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { SnapshotWriter.refresh(context: modelContext) }
        }
        #if DEBUG
        .task { await DemoImport.runIfRequested(modelContext: modelContext) }
        #endif
    }

    private var sidebar: some View {
        sidebarList
            #if os(iOS)
            // Compact (iPhone): the detail-pane HUD is invisible while the
            // collapsed sidebar is frontmost — mirror it here.
            .overlay(alignment: .bottom) {
                if horizontalSizeClass == .compact {
                    SyncProgressHUD().padding(.bottom, 14).padding(.horizontal, 16)
                }
            }
            #endif
    }

    /// A sidebar nav row whose selection highlight follows the THEME accent on
    /// macOS (the system otherwise paints a fixed system-blue pill that ignores
    /// SwiftUI `.tint`). iOS keeps its native highlight (its tint already works).
    /// Sidebar Label with the ICON pinned to the theme accent (or white when the
    /// row is selected) — macOS otherwise paints sidebar icons system-blue and
    /// ignores `.tint`/`.foregroundStyle` on the row. The title stays primary.
    @ViewBuilder
    private func sidebarLabel(_ title: String, _ icon: String, selected: Bool) -> some View {
        Label {
            Text(title)
                #if os(macOS)
                .foregroundStyle(selected ? theme.onAccent : theme.primaryText)
                #endif
        } icon: {
            Image(systemName: icon)
                #if os(macOS)
                // The vivid, contrast-shifted accent (raw `theme.accent` sits on the
                // wash and reads grey); on the selected row it sits on the accent
                // capsule, so use the contrasting on-accent colour (black or white).
                .foregroundStyle(selected ? theme.onAccent : theme.legibleAccent)
                #endif
        }
    }

    @ViewBuilder
    private func navRow(_ value: Selection, _ title: String, _ icon: String) -> some View {
        NavigationLink(value: value) {
            sidebarLabel(title, icon, selected: rowSelected(value))
        }
        #if os(macOS)
        .listRowBackground(rowSelected(value)
            ? AnyView(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.accent))
            : AnyView(Color.clear))
        #endif
    }

    private var sidebarList: some View {
        List(selection: $selection) {
            Section {
                navRow(.overview, "Overview", "rectangle.grid.2x2")
                navRow(.calendar(nil), "Calendar", "calendar")
                navRow(.search, "Search", "magnifyingglass")
                navRow(.shiftTypes, "Shift Types", "clock")
                if planningModule { navRow(.planning, "Planning", "calendar.badge.clock") }
                if payModule { navRow(.timesheet, "Timesheet", "banknote") }
                navRow(.settings, "Settings", "gearshape")
            }

            if !importedRosters.isEmpty {
                Section("Rosters") {
                    ForEach(importedRosters) { roster in
                        NavigationLink(value: Selection.roster(roster.id)) {
                            sidebarLabel(roster.title ?? "Untitled roster", "tablecells",
                                         selected: rowSelected(.roster(roster.id)))
                        }
                        #if os(macOS)
                        .listRowBackground(rowSelected(.roster(roster.id))
                            ? AnyView(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.accent))
                            : AnyView(Color.clear))
                        .foregroundStyle(rowSelected(.roster(roster.id)) ? theme.onAccent : theme.primaryText)
                        #endif
                    }
                }
            }

            if !schedules.isEmpty {
                Section("Schedules") {
                    ForEach(schedules) { schedule in
                        NavigationLink(value: Selection.schedule(schedule.id)) {
                            sidebarLabel(schedule.title?.isEmpty == false ? schedule.title! : "Untitled schedule",
                                         "slider.horizontal.below.square.filled.and.square",
                                         selected: rowSelected(.schedule(schedule.id)))
                        }
                        .swipeActions {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                deleteSchedule(schedule)
                            }
                        }
                        // Right-click parity for macOS (no swipe actions there).
                        .contextMenu {
                            Button("Delete schedule", systemImage: "trash", role: .destructive) {
                                deleteSchedule(schedule)
                            }
                        }
                        #if os(macOS)
                        .listRowBackground(rowSelected(.schedule(schedule.id))
                            ? AnyView(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.accent))
                            : AnyView(Color.clear))
                        .foregroundStyle(rowSelected(.schedule(schedule.id)) ? theme.onAccent : theme.primaryText)
                        #endif
                    }
                }
            }
        }
        .themedPane()
        #if os(macOS)
        .listStyle(.sidebar)
        #endif
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .overview, nil:
            OverviewView(importRoster: { selection = .importer }, newSchedule: newSchedule)
        case let .calendar(day):
            CalendarView(mode: .live, initialDay: day)
                .navigationTitle("Calendar")
        case .search:
            SearchView(
                onOpenDay: { selection = .calendar($0) },
                onOpenRoster: { selection = .roster($0) },
                onOpenSchedule: { selection = .schedule($0) }
            )
        case .shiftTypes:
            ShiftTypeLibraryView()
        case .settings:
            SettingsForm()
                .navigationTitle("Settings")
        case .importer:
            ImportView(onDone: { selection = .overview })
        case .planning:
            PlanningView(quickAdd: { selection = .quickAddShift("") })
        case .timesheet:
            TimesheetView(openSettings: { selection = .settings })
        case let .quickAddShift(iso):
            QuickAddShiftView(dateISO: iso, onDone: { selection = .calendar($0) })
        case let .roster(id):
            if let roster = rosters.first(where: { $0.id == id }) {
                // Identity tied to the roster: switching rosters reuses this same
                // structural position, so without .id the view-mode @State (the
                // calendar's selected day/month, etc.) would carry over to the
                // next roster. .id resets it on every roster change.
                ShiftListView(roster: roster, onDeleted: { selection = .overview }, onImportUpdate: { selection = .importer })
                    .id(roster.id)
            } else { placeholder }
        case let .schedule(id):
            if let schedule = schedules.first(where: { $0.id == id }) {
                ScheduleEditorView(schedule: schedule)
            } else { placeholder }
        }
    }

    private var placeholder: some View {
        ContentUnavailableView("Select a roster or schedule", systemImage: "sidebar.left")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Settings lives in the sidebar (and ⌘, on macOS) — no toolbar gear.
        ToolbarItem {
            Menu {
                Button("Import roster…", systemImage: "square.and.arrow.down") { selection = .importer }
                Button("New schedule", systemImage: "slider.horizontal.3") { newSchedule() }
                Button("Quick add shift", systemImage: "calendar.badge.plus") { selection = .quickAddShift("") }
                    .disabled(syncProgress.isActive)
                Button("Plan time off", systemImage: "airplane") { selection = .planning }
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
    }

    private func newSchedule() {
        let schedule = Schedule(title: "New schedule")
        let today = Calendar.current.startOfDay(for: .now)
        schedule.horizonStart = today
        schedule.horizonEnd = Calendar.current.date(byAdding: .month, value: 6, to: today)
        modelContext.insert(schedule)
        try? modelContext.save()
        selection = .schedule(schedule.id)
    }

    private func deleteSchedule(_ schedule: Schedule, force: Bool = false) {
        let context = modelContext
        if case .schedule(schedule.id) = selection { selection = .overview }
        Task {
            do {
                try await ScheduleCoordinator.deleteSchedule(schedule, in: context, force: force)
            } catch {
                // Calendar unreachable (e.g. Google signed out): nothing was
                // deleted — offer an explicit "delete anyway" escape hatch.
                deleteErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                scheduleAwaitingForcedDelete = schedule
            }
        }
    }
}

#Preview {
    let container = try! ModelContainer(
        for: HelmApp.schema,
        configurations: ModelConfiguration(schema: HelmApp.schema, isStoredInMemoryOnly: true)
    )
    ContentView()
        .modelContainer(container)
}
