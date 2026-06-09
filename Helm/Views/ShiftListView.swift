//
//  ShiftListView.swift
//  Helm
//
//  Detail pane: the shifts of a selected roster. Re-import to update in place
//  (idempotent); the overflow menu removes the roster and its calendar events.
//

import SwiftUI
import SwiftData

struct ShiftListView: View {
    let roster: Roster
    @Environment(\.modelContext) private var modelContext
    @State private var isConfirmingDelete = false

    private var sortedInstances: [ShiftInstance] {
        (roster.instances ?? []).sorted {
            ($0.localDate ?? .distantPast, $0.sortIndex) < ($1.localDate ?? .distantPast, $1.sortIndex)
        }
    }

    var body: some View {
        Group {
            if sortedInstances.isEmpty {
                ContentUnavailableView(
                    "No shifts",
                    systemImage: "calendar",
                    description: Text("This roster has no shifts yet.")
                )
            } else {
                List(sortedInstances) { instance in
                    ShiftRow(instance: instance)
                }
            }
        }
        .navigationTitle(roster.title ?? "Roster")
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Remove from Calendar & delete", systemImage: "trash", role: .destructive) {
                        isConfirmingDelete = true
                    }
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
                    let writer = ShiftCalendarWriter()
                    _ = await writer.requestAccess()
                    try? await RosterSyncEngine.delete(roster: roster, target: writer, in: context)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct ShiftRow: View {
    let instance: ShiftInstance

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(instance.title ?? instance.shiftType?.label ?? instance.shiftType?.code ?? "Shift")
                    .font(.headline)
                if let location = instance.locationName, !location.isEmpty {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let date = instance.localDate {
                    Text(date, format: .dateTime.weekday().day().month())
                        .font(.subheadline)
                }
                Text(timeRange)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// Wall-clock time range derived from the shift type's minutes-of-day.
    private var timeRange: String {
        guard let type = instance.shiftType else { return "—" }
        func fmt(_ minutes: Int) -> String {
            let m = ((minutes % 1440) + 1440) % 1440
            return String(format: "%02d:%02d", m / 60, m % 60)
        }
        if type.workKind == .off { return "Off" }
        return "\(fmt(type.startMinuteOfDay))–\(fmt(type.endMinuteOfDay))"
    }
}
