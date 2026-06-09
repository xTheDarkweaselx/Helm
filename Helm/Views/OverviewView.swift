//
//  OverviewView.swift
//  Helm
//
//  The sidebar's home item: next shift, a glanceable summary, and quick
//  actions. Doubles as first-launch onboarding when nothing exists yet (the
//  empty state used to live in the sidebar column, where it clipped on macOS).
//

import SwiftUI
import SwiftData

struct OverviewView: View {
    @Query(sort: \Roster.createdAt, order: .reverse) private var rosters: [Roster]
    @Query(sort: \Schedule.createdAt, order: .reverse) private var schedules: [Schedule]
    @Query private var instances: [ShiftInstance]

    /// Open the import sheet / create a schedule (owned by ContentView).
    let importRoster: () -> Void
    let newSchedule: () -> Void

    private var now: Date { .now }

    private var upcoming: [ShiftInstance] {
        instances
            .filter { ($0.startUTC ?? .distantPast) >= now }
            .sorted { ($0.startUTC ?? .distantFuture) < ($1.startUTC ?? .distantFuture) }
    }

    private var thisWeekCount: Int {
        let weekFromNow = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
        return upcoming.prefix(while: { ($0.startUTC ?? .distantFuture) < weekFromNow }).count
    }

    var body: some View {
        Group {
            if rosters.isEmpty && schedules.isEmpty {
                onboarding
            } else {
                summary
            }
        }
        .navigationTitle("Overview")
    }

    // MARK: - First launch

    private var onboarding: some View {
        ContentUnavailableView {
            Label("Welcome to Helm", systemImage: "calendar.badge.plus")
        } description: {
            Text("Import a spreadsheet roster, or build a custom rota, and Helm keeps your calendar in step with it.")
        } actions: {
            Button("Import roster", systemImage: "square.and.arrow.down", action: importRoster)
                .buttonStyle(.borderedProminent)
            Button("New schedule", systemImage: "slider.horizontal.3", action: newSchedule)
        }
    }

    // MARK: - Dashboard

    private var summary: some View {
        Form {
            if let next = upcoming.first {
                Section("Next shift") {
                    nextShiftRow(next)
                }
            } else {
                Section("Next shift") {
                    Text("No upcoming shifts.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("At a glance") {
                LabeledContent("In the next 7 days", value: "\(thisWeekCount) shift\(thisWeekCount == 1 ? "" : "s")")
                LabeledContent("Upcoming in total", value: "\(upcoming.count)")
                LabeledContent("Rosters", value: "\(rosters.count)")
                LabeledContent("Schedules", value: "\(schedules.count)")
            }

            Section {
                Button("Import roster…", systemImage: "square.and.arrow.down", action: importRoster)
                Button("New schedule", systemImage: "slider.horizontal.3", action: newSchedule)
            }
        }
        .formStyle(.grouped)
    }

    private func nextShiftRow(_ instance: ShiftInstance) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(instance.title ?? instance.shiftType?.label ?? instance.shiftType?.code ?? "Shift")
                .font(.headline)
            if let start = instance.startUTC {
                Text(start, format: .dateTime.weekday(.wide).day().month().hour().minute())
                    .foregroundStyle(.secondary)
                Text(start, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let location = instance.locationName, !location.isEmpty {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
