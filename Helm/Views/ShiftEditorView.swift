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
//  ORDERING (v7.3 hardening): the calendar is written FIRST from STAGED local
//  values; the @Model is only mutated after the write succeeds, immediately
//  followed by save(). Mutating before a long await invited SwiftData's
//  autosave to commit a half-done edit that rollback() could no longer revert.
//

import SwiftUI
import SwiftData
import HelmDomain
import HelmCalendar

struct ShiftEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(SyncProgress.self) private var syncProgress
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
    @State private var seedSnapshot: FormSnapshot?

    private var wasTBC: Bool { instance.isAllDay == true }

    /// What the form currently says — compared against the seed so a no-change
    /// Save doesn't mark the shift user-edited (which would permanently opt it
    /// out of source re-import updates).
    private struct FormSnapshot: Equatable {
        var title: String
        var location: String
        var note: String
        var day: DayKey
        var hasTimes: Bool
        var startMinute: Int
        var endMinute: Int
        var overnight: Bool
    }

    private var currentSnapshot: FormSnapshot {
        FormSnapshot(
            title: title.trimmingCharacters(in: .whitespaces),
            location: location,
            note: note,
            day: DayKey(containing: date, in: instanceCalendar()),
            hasTimes: hasTimes,
            startMinute: startMinute,
            endMinute: endMinute,
            overnight: overnight
        )
    }

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
                .buttonStyle(.glassProminent)
                .disabled(saving || syncProgress.isActive)
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
        seedSnapshot = currentSnapshot
    }

    private func instanceCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: instance.timeZoneIdentifier) ?? .current
        return cal
    }

    // MARK: Save — calendar FIRST (staged values), model mutation only on success

    private func save() {
        errorMessage = nil

        // Nothing changed → don't mark the shift user-edited for nothing.
        if let seedSnapshot, currentSnapshot == seedSnapshot {
            dismiss()
            return
        }

        let cal = instanceCalendar()
        let tz = cal.timeZone
        let dayStart = cal.startOfDay(for: date)
        // Import convention: localDate is NOON-anchored in the shift's zone so
        // device-zone consumers (list labels, search, Siri, widget) derive the
        // same civil day. The all-day START/END stay midnight (exporters rely
        // on that), only localDate is noon.
        let noonAnchor = cal.date(bySettingHour: 12, minute: 0, second: 0, of: dayStart) ?? dayStart

        // Stage the resolved times WITHOUT touching the model.
        let stagedStart: Date
        let stagedEnd: Date
        let stagedPaidHours: Double?
        if hasTimes {
            if startMinute == endMinute && !overnight {
                errorMessage = "Start and end are the same — set an end time, or turn on “Ends next day” for a 24-hour shift."
                return
            }
            // end < start without the toggle = overnight by the app's standing
            // convention (matches the import panel's rule).
            guard let resolved = ShiftTimeResolver.resolve(
                localDay: dayStart,
                startMinuteOfDay: startMinute,
                endMinuteOfDay: endMinute,
                endDayOffset: overnight ? 1 : 0,
                timeZone: tz
            ), resolved.end > resolved.start else {
                errorMessage = "Those times don't make a valid shift — check start and end."
                return
            }
            stagedStart = resolved.start
            stagedEnd = resolved.end
            stagedPaidHours = resolved.paidHours(breakMinutes: instance.shiftType?.breakMinutes ?? 0)
        } else {
            // The all-day convention: start = end = local midnight.
            stagedStart = dayStart
            stagedEnd = dayStart
            stagedPaidHours = nil
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let stagedTitle: String? = trimmedTitle.isEmpty ? nil : trimmedTitle
        let stagedLocation: String? = location.isEmpty ? nil : location
        let stagedNote: String? = note.isEmpty ? nil : note
        let dedupKey = instance.dedupKey ?? instance.id
        let zoneID = instance.timeZoneIdentifier
        let isAllDay = !hasTimes
        // Mirrors RosterSyncEngine.calendarDraft, built from STAGED values.
        let draft = CalendarEventDraft(
            dedupKey: dedupKey,
            title: stagedTitle ?? instance.shiftType?.label ?? instance.shiftType?.code ?? "Shift",
            location: stagedLocation,
            start: stagedStart,
            end: stagedEnd,
            timeZoneIdentifier: zoneID,
            isAllDay: isAllDay,
            alarmOffsetsMinutes: RosterSyncEngine.effectiveReminderOffsets(for: instance.roster),
            contentHash: ShiftContentHash.make(
                title: stagedTitle, startUTC: stagedStart, endUTC: stagedEnd,
                location: stagedLocation, timeZoneIdentifier: zoneID
            )
        )

        saving = true
        Task {
            defer { saving = false }
            do {
                // 1. Calendar first — same dedup key replaces the event in place.
                let destinations = instance.roster.map { RosterSyncEngine.destinations(for: $0, in: context) } ?? [.eventkit]
                let targets = try await CalendarTargetProvider.authorizedTargets(for: destinations)
                SyncProgress.shared.begin("Updating calendar…", total: nil)
                defer { SyncProgress.shared.end() }
                for target in targets { _ = try await target.write([draft]) }

                // 2. Only now mutate the model — and save with no await between.
                instance.title = stagedTitle
                instance.locationName = stagedLocation
                instance.note = stagedNote
                instance.localDate = noonAnchor
                instance.startUTC = stagedStart
                instance.endUTC = stagedEnd
                instance.computedPaidHours = stagedPaidHours
                instance.isAllDay = isAllDay ? true : nil
                // User-authored from now on: re-imports preserve it (.added stays .added).
                if instance.overrideKind == .none { instance.overrideKind = .modified }
                try context.save()
                SnapshotWriter.refresh(context: context)
                dismiss()
            } catch {
                // Nothing was mutated — the store still matches the calendar.
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
