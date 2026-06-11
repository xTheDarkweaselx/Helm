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
        /// v7 one-off shift. Carries an ISO "yyyy-MM-dd" seed ("" = today).
        case quickAddShift(String)
    }

    @State private var selection: Selection? = .overview
    @State private var deleteErrorMessage: String?
    @State private var scheduleAwaitingForcedDelete: Schedule?
    @Environment(\.scenePhase) private var scenePhase

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
        List(selection: $selection) {
            Section {
                NavigationLink(value: Selection.overview) {
                    Label("Overview", systemImage: "rectangle.grid.2x2")
                }
                NavigationLink(value: Selection.calendar(nil)) {
                    Label("Calendar", systemImage: "calendar")
                }
                NavigationLink(value: Selection.search) {
                    Label("Search", systemImage: "magnifyingglass")
                }
                NavigationLink(value: Selection.shiftTypes) {
                    Label("Shift Types", systemImage: "clock")
                }
                NavigationLink(value: Selection.planning) {
                    Label("Planning", systemImage: "calendar.badge.clock")
                }
                NavigationLink(value: Selection.settings) {
                    Label("Settings", systemImage: "gearshape")
                }
            }

            if !importedRosters.isEmpty {
                Section("Rosters") {
                    ForEach(importedRosters) { roster in
                        NavigationLink(value: Selection.roster(roster.id)) {
                            Label(roster.title ?? "Untitled roster", systemImage: "tablecells")
                        }
                    }
                }
            }

            if !schedules.isEmpty {
                Section("Schedules") {
                    ForEach(schedules) { schedule in
                        NavigationLink(value: Selection.schedule(schedule.id)) {
                            Label(schedule.title?.isEmpty == false ? schedule.title! : "Untitled schedule",
                                  systemImage: "slider.horizontal.below.square.filled.and.square")
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
                    }
                }
            }
        }
        .themedPane() // v7.1 wash (iOS; passthrough on macOS — glass sidebar samples the window)
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
        case let .quickAddShift(iso):
            QuickAddShiftView(dateISO: iso, onDone: { selection = .calendar($0) })
        case let .roster(id):
            if let roster = rosters.first(where: { $0.id == id }) {
                ShiftListView(roster: roster, onDeleted: { selection = .overview }, onImportUpdate: { selection = .importer })
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
