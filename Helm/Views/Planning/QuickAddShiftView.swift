//
//  QuickAddShiftView.swift
//  Helm
//
//  v7: add a single one-off shift in-window (no import, no schedule). Writes
//  through ManualShiftCoordinator → the same calendar draft/upsert path.
//

import SwiftUI
import SwiftData
import HelmDomain

struct QuickAddShiftView: View {
    /// ISO "yyyy-MM-dd" seed; "" = today.
    let dateISO: String
    /// v7.3: add into an EXISTING roster (nil → the "Manual Shifts" roster).
    var rosterID: String? = nil
    /// Called after a successful add with the day the shift landed on (so the
    /// caller can jump the calendar there).
    let onDone: (DayKey?) -> Void

    @Environment(\.modelContext) private var context
    @Environment(SyncProgress.self) private var syncProgress
    @Query(sort: [SortDescriptor(\ShiftType.sortIndex), SortDescriptor(\ShiftType.code)]) private var types: [ShiftType]

    @State private var date = Date.now
    @State private var isAllDay = false
    @State private var selectedTypeID: String?
    @State private var startMinute = 9 * 60
    @State private var endMinute = 17 * 60
    @State private var overnight = false
    @State private var title = ""
    @State private var location = ""
    @State private var note = ""
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var seeded = false

    private var selectedType: ShiftType? {
        selectedTypeID.flatMap { id in types.first { $0.id == id } }
    }
    private var usesCustomTimes: Bool { selectedType == nil && !isAllDay }

    var body: some View {
        Form {
            Section {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                Toggle("All-day", isOn: $isAllDay)
            }

            Section("Shift") {
                Picker("Shift type", selection: $selectedTypeID) {
                    Text("Custom").tag(String?.none)
                    ForEach(types.filter { $0.workKind != .off }) { type in
                        Text(type.label ?? type.code ?? "Shift").tag(String?.some(type.id))
                    }
                }
                if let t = selectedType, !isAllDay {
                    LabeledContent("Times", value: t.workKind == .off ? "Off" : "\(hhmmString(t.startMinuteOfDay))–\(hhmmString(t.endMinuteOfDay))")
                }
                if usesCustomTimes {
                    DatePicker("Start", selection: timeOfDayBinding($startMinute), displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: timeOfDayBinding($endMinute), displayedComponents: .hourAndMinute)
                    Toggle("Ends next day (overnight)", isOn: $overnight)
                }
            }

            Section("Details") {
                TextField("Title (optional)", text: $title)
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
                    if saving { ProgressView() } else { Text("Add shift") }
                }
                .disabled(saving || syncProgress.isActive)
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .themedPane() // v7.1 wash (iOS; passthrough on macOS)
        .navigationTitle(rosterID == nil ? "Quick Add Shift" : "Add Shift")
        .onAppear {
            guard !seeded else { return }
            seeded = true
            if let parsed = Self.parse(dateISO) { date = parsed }
        }
    }

    private func save() {
        saving = true
        errorMessage = nil
        let type = selectedType
        let custom = usesCustomTimes
        Task {
            defer { saving = false }
            do {
                try await ManualShiftCoordinator.addShift(
                    date: date,
                    timeZoneIdentifier: TimeZone.current.identifier,
                    shiftType: type,
                    title: title,
                    location: location,
                    note: note,
                    startMinute: custom ? startMinute : nil,
                    endMinute: custom ? endMinute : nil,
                    endDayOffset: overnight ? 1 : 0,
                    isAllDay: isAllDay,
                    rosterID: rosterID,
                    in: context
                )
                onDone(DayKey(containing: date, in: CalendarViewModel.displayCalendar))
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private static func parse(_ iso: String) -> Date? {
        guard !iso.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: iso)
    }
}
