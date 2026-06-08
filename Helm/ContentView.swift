//
//  ContentView.swift
//  Helm
//
//  Created by Adam Ibrahim on 08/06/2026.
//

import SwiftUI
import SwiftData

/// The app's universal shell: a `NavigationSplitView` that auto-collapses to a
/// stack on iPhone and shows columns on iPad/Mac (ADR-12). Sidebar lists rosters;
/// detail shows the selected roster's shifts. The import wizard is presented as a
/// sheet (built in a later phase).
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Roster.createdAt, order: .reverse) private var rosters: [Roster]

    @State private var selectedRosterID: Roster.ID?
    @State private var isPresentingImport = false

    private var selectedRoster: Roster? {
        guard let selectedRosterID else { return nil }
        return rosters.first { $0.id == selectedRosterID }
    }

    var body: some View {
        NavigationSplitView {
            Group {
                if rosters.isEmpty {
                    ContentUnavailableView {
                        Label("No rosters yet", systemImage: "calendar.badge.plus")
                    } description: {
                        Text("Import a spreadsheet to add your shifts.")
                    } actions: {
                        Button("Import roster", systemImage: "square.and.arrow.down") {
                            isPresentingImport = true
                        }
                    }
                } else {
                    List(selection: $selectedRosterID) {
                        Section("Rosters") {
                            ForEach(rosters) { roster in
                                NavigationLink(value: roster.id) {
                                    Label(roster.title ?? "Untitled roster", systemImage: "calendar")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Helm")
            .toolbar {
                ToolbarItem {
                    Button("Import roster", systemImage: "square.and.arrow.down") {
                        isPresentingImport = true
                    }
                }
            }
        } detail: {
            if let selectedRoster {
                ShiftListView(roster: selectedRoster)
            } else {
                ContentUnavailableView("Select a roster", systemImage: "sidebar.left")
            }
        }
        .sheet(isPresented: $isPresentingImport) {
            ImportView()
        }
#if DEBUG
        .task {
            if rosters.isEmpty {
                await DemoImport.runIfRequested(modelContext: modelContext)
            }
        }
#endif
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
