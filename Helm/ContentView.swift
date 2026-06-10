//
//  ContentView.swift
//  Helm
//
//  Created by Adam Ibrahim on 08/06/2026.
//

import SwiftUI
import SwiftData

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
        case calendar
        case shiftTypes
        case settings
        case roster(String)
        case schedule(String)
    }

    @State private var selection: Selection? = .overview
    @State private var isPresentingImport = false
    @State private var deleteErrorMessage: String?
    @State private var scheduleAwaitingForcedDelete: Schedule?

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
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 440)
        #endif
        .sheet(isPresented: $isPresentingImport) { ImportView() }
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
                NavigationLink(value: Selection.calendar) {
                    Label("Calendar", systemImage: "calendar")
                }
                NavigationLink(value: Selection.shiftTypes) {
                    Label("Shift Types", systemImage: "clock")
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
        #if os(macOS)
        .listStyle(.sidebar)
        #endif
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .overview, nil:
            OverviewView(importRoster: { isPresentingImport = true }, newSchedule: newSchedule)
        case .calendar:
            CalendarView(mode: .live)
                .navigationTitle("Calendar")
        case .shiftTypes:
            ShiftTypeLibraryView()
        case .settings:
            SettingsForm()
                .navigationTitle("Settings")
        case let .roster(id):
            if let roster = rosters.first(where: { $0.id == id }) {
                ShiftListView(roster: roster)
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
                Button("Import roster…", systemImage: "square.and.arrow.down") { isPresentingImport = true }
                Button("New schedule", systemImage: "slider.horizontal.3") { newSchedule() }
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
