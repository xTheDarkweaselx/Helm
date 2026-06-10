//
//  ShiftListView.swift
//  Helm
//
//  Detail pane: the shifts of a selected roster. Re-import to update in place
//  (idempotent); the overflow menu removes the roster and its calendar events.
//

import SwiftUI
import SwiftData
import HelmCalendar
import HelmDomain

struct ShiftListView: View {
    let roster: Roster
    @Environment(\.modelContext) private var modelContext
    @State private var isConfirmingDelete = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?
    @State private var applyingReminders = false
    @State private var icsURL: URL?
    @State private var isEditingReminders = false
    @State private var instanceToRemove: ShiftInstance?

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
                        .swipeActions {
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                instanceToRemove = instance
                            }
                        }
                        .contextMenu { // right-click parity on macOS
                            Button("Remove shift…", systemImage: "trash", role: .destructive) {
                                instanceToRemove = instance
                            }
                        }
                }
            }
        }
        .navigationTitle(roster.title ?? "Roster")
        .toolbar {
            ToolbarItem {
                Menu {
                    if let icsURL {
                        ShareLink("Export .ics", item: icsURL)
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
                    .disabled(applyingReminders)
                    Divider()
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
                    do {
                        let destinations = RosterSyncEngine.destinations(for: roster, in: context)
                        let targets = try await CalendarTargetProvider.authorizedTargets(for: destinations)
                        try await RosterSyncEngine.delete(roster: roster, targets: targets, in: context)
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
        // In-window (push), not a sheet — consistent with the rest of the app.
        .navigationDestination(isPresented: $isEditingReminders) {
            RosterRemindersView(roster: roster) {
                applyReminders() // push the new offsets onto existing events
            }
        }
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

    /// Changes when any shift's identity/title/time or the reminder default changes.
    private var rosterSignature: String {
        let parts: [String] = (roster.instances ?? []).map { inst in
            let key = inst.dedupKey ?? inst.id
            let title = inst.title ?? ""
            let start = Int(inst.startUTC?.timeIntervalSince1970 ?? 0)
            return "\(key)|\(title)|\(start)"
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
        if instance.isAllDay == true { return "All-day" }
        guard let type = instance.shiftType else { return "—" }
        func fmt(_ minutes: Int) -> String {
            let m = ((minutes % 1440) + 1440) % 1440
            return String(format: "%02d:%02d", m / 60, m % 60)
        }
        if type.workKind == .off { return "Off" }
        return "\(fmt(type.startMinuteOfDay))–\(fmt(type.endMinuteOfDay))"
    }
}
