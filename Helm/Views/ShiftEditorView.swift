//
//  ShiftEditorView.swift
//  Helm
//
//  v7.3: edit one shift in-window — title, date, times, location, note. The
//  headline use: giving a TBC (all-day) import real times once they're
//  confirmed. Saving marks the instance user-edited (.modified) so a later
//  re-import of the source file NEVER clobbers the edit, and upserts the same
//  calendar event (the dedup key is stable, so the event moves — no duplicate).
//

import SwiftUI
import SwiftData
import HelmDomain
import HelmCalendar

struct ShiftEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Bindable var instance: ShiftInstance

    @State private var title = ""
    @State private var location = ""
    @State private var note = ""
    @State private var date = Date.now
    /// false = all-day / times-to-be-confirmed.
    @State private var hasTimes = true
    @State private var startMinute = 9 * 60
    @State private var endMinute = 17 * 60
    @State private var overnight = false
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var seeded = false

    private var wasTBC: Bool { instance.isAllDay == true }

    var body: some View {
        Form {
            Section("Shift") {
                TextField("Title", text: $title)
                DatePicker("Date", selection: $date, displayedComponents: .date)
            }

            Section {
                Toggle("Times confirmed", isOn: $hasTimes)
                if hasTimes {
                    DatePicker("Start", selection: timeOfDayBinding($startMinute), displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: timeOfDayBinding($endMinute), displayedComponents: .hourAndMinute)
                    Toggle("Ends next day (overnight)", isOn: $overnight)
                }
            } header: {
                Text("Times")
            } footer: {
                if wasTBC && !hasTimes {
                    Text("This shift was imported without times (TBC) — it shows as an all-day event. Turn on “Times confirmed” once you know them.")
                } else if !hasTimes {
                    Text("Without times the shift stays an all-day calendar event.")
                }
            }

            Section("Details") {
                TextField("Location (optional)", text: $location)
                TextField("Notes (optional)", text: $note, axis: .vertical)
                    .lineLimit(1...4)
            }

            if let errorMessage {
                Section { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            }

            Section {
                Button {
                    save()
                } label: {
                    if saving { ProgressView() } else { Text("Save & update calendar") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(saving)
            } footer: {
                Text("Your edit is kept even if you re-import the roster file.")
            }
        }
        .formStyle(.grouped)
        .themedPane() // v7.1 wash (iOS; passthrough on macOS)
        .navigationTitle("Edit Shift")
        .onAppear(perform: seed)
    }

    // MARK: Seeding (wall-clock derived in the SHIFT's own zone)

    private func seed() {
        guard !seeded else { return }
        seeded = true
        title = instance.title ?? instance.shiftType?.label ?? ""
        location = instance.locationName ?? ""
        note = instance.note ?? ""
        date = instance.localDate ?? .now

        let cal = instanceCalendar()
        if wasTBC || instance.startUTC == nil || instance.endUTC == nil {
            hasTimes = false
            // Sensible defaults for "confirm the times": the type's wall-clock.
            if let type = instance.shiftType, type.workKind != .off {
                startMinute = type.startMinuteOfDay
                endMinute = ((type.endMinuteOfDay % 1440) + 1440) % 1440
                overnight = type.endDayOffset > 0 || type.endMinuteOfDay >= 1440
            }
        } else if let start = instance.startUTC, let end = instance.endUTC {
            hasTimes = true
            let s = cal.dateComponents([.hour, .minute], from: start)
            let e = cal.dateComponents([.hour, .minute], from: end)
            startMinute = (s.hour ?? 9) * 60 + (s.minute ?? 0)
            endMinute = (e.hour ?? 17) * 60 + (e.minute ?? 0)
            overnight = !cal.isDate(start, inSameDayAs: end)
        }
    }

    private func instanceCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: instance.timeZoneIdentifier) ?? .current
        return cal
    }

    // MARK: Save (data + calendar, rollback on calendar failure)

    private func save() {
        saving = true
        errorMessage = nil
        Task {
            defer { saving = false }
            let cal = instanceCalendar()
            let tz = cal.timeZone
            let dayStart = cal.startOfDay(for: date)

            instance.title = title.trimmingCharacters(in: .whitespaces).isEmpty ? nil : title
            instance.locationName = location.isEmpty ? nil : location
            instance.note = note.isEmpty ? nil : note
            instance.localDate = dayStart

            if hasTimes {
                guard let resolved = ShiftTimeResolver.resolve(
                    localDay: dayStart,
                    startMinuteOfDay: startMinute,
                    endMinuteOfDay: endMinute,
                    endDayOffset: overnight ? 1 : 0,
                    timeZone: tz
                ), resolved.end > resolved.start else {
                    context.rollback()
                    errorMessage = "Those times don't make a valid shift — check start and end."
                    return
                }
                instance.startUTC = resolved.start
                instance.endUTC = resolved.end
                instance.computedPaidHours = resolved.paidHours(breakMinutes: instance.shiftType?.breakMinutes ?? 0)
                instance.isAllDay = nil
            } else {
                // The all-day convention: start = end = local midnight.
                instance.startUTC = dayStart
                instance.endUTC = dayStart
                instance.computedPaidHours = nil
                instance.isAllDay = true
            }

            // User-authored from now on: re-imports preserve it (.added stays .added).
            if instance.overrideKind == .none { instance.overrideKind = .modified }

            do {
                let destinations = instance.roster.map { RosterSyncEngine.destinations(for: $0, in: context) } ?? [.eventkit]
                let targets = try await CalendarTargetProvider.authorizedTargets(for: destinations)
                if let draft = RosterSyncEngine.calendarDraft(for: instance) {
                    SyncProgress.shared.begin("Updating calendar…", total: nil)
                    defer { SyncProgress.shared.end() }
                    // Same dedup key → the existing event is replaced in place.
                    for target in targets { _ = try await target.write([draft]) }
                }
                try context.save()
                SnapshotWriter.refresh(context: context)
                dismiss()
            } catch {
                context.rollback()
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
