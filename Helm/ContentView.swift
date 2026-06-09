//
//  ContentView.swift
//  Helm
//
//  Created by Adam Ibrahim on 08/06/2026.
//

import SwiftUI
import SwiftData

/// The app's universal shell: a `NavigationSplitView` (ADR-12). The sidebar lists
/// imported rosters and built schedules; the detail shows the selected one.
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Roster.createdAt, order: .reverse) private var rosters: [Roster]
    @Query(sort: \Schedule.createdAt, order: .reverse) private var schedules: [Schedule]

    enum Selection: Hashable {
        case roster(String)
        case schedule(String)
    }

    @State private var selection: Selection?
    @State private var isPresentingImport = false
    @State private var isPresentingSettings = false

    private var isEmpty: Bool { rosters.isEmpty && schedules.isEmpty }

    var body: some View {
        NavigationSplitView {
            Group {
                if isEmpty {
                    emptyState
                } else {
                    sidebar
                }
            }
            .navigationTitle("Helm")
            .toolbar { toolbarContent }
        } detail: {
            NavigationStack { detail }
        }
        .sheet(isPresented: $isPresentingImport) { ImportView() }
        .sheet(isPresented: $isPresentingSettings) { SettingsView() }
#if DEBUG
        .task { await DemoImport.runIfRequested(modelContext: modelContext) }
#endif
    }

    private var sidebar: some View {
        List(selection: $selection) {
            if !rosters.isEmpty {
                Section("Rosters") {
                    ForEach(rosters) { roster in
                        NavigationLink(value: Selection.roster(roster.id)) {
                            Label(roster.title ?? "Untitled roster", systemImage: "calendar")
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
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing here yet", systemImage: "calendar.badge.plus")
        } description: {
            Text("Import a spreadsheet, or build a custom rota, to add your shifts.")
        } actions: {
            Button("Import roster", systemImage: "square.and.arrow.down") { isPresentingImport = true }
                .buttonStyle(.borderedProminent)
            Button("New schedule", systemImage: "slider.horizontal.3") { newSchedule() }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case let .roster(id):
            if let roster = rosters.first(where: { $0.id == id }) {
                ShiftListView(roster: roster)
            } else { placeholder }
        case let .schedule(id):
            if let schedule = schedules.first(where: { $0.id == id }) {
                ScheduleEditorView(schedule: schedule)
            } else { placeholder }
        case nil:
            placeholder
        }
    }

    private var placeholder: some View {
        ContentUnavailableView("Select a roster or schedule", systemImage: "sidebar.left")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Menu {
                Button("Import roster…", systemImage: "square.and.arrow.down") { isPresentingImport = true }
                Button("New schedule", systemImage: "slider.horizontal.3") { newSchedule() }
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
        ToolbarItem {
            Button("Settings", systemImage: "gearshape") { isPresentingSettings = true }
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
}

#Preview {
    let container = try! ModelContainer(
        for: HelmApp.schema,
        configurations: ModelConfiguration(schema: HelmApp.schema, isStoredInMemoryOnly: true)
    )
    ContentView()
        .modelContainer(container)
}
