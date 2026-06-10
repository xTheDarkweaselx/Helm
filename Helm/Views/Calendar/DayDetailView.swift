//
//  DayDetailView.swift
//  Helm
//
//  The selected day's agenda: shifts first-class (color bar, times, location),
//  other events secondary, preview items tagged with their pending status —
//  symbol + text, never color alone.
//

import SwiftUI
import HelmDomain

struct DayDetailView: View {
    let day: DayKey
    let items: [CalendarDayItem]
    /// CalendarDayItem.id → titles of timed events the item overlaps (v4).
    var conflicts: [String: [String]] = [:]
    /// v7: time-off labels covering this day (shown as a banner).
    var leave: [String] = []
    /// Present in .live mode: offer "Remove shift" on shift rows (v4).
    var onRemoveShift: ((ShiftItem) -> Void)?
    /// Present in .live mode: persist an edited note (shiftID, newNote). v7.
    var onEditNote: ((String, String?) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(day.startOfDay(in: Calendar.current), format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .accessibilityAddTraits(.isHeader)
            Divider()
            if !leave.isEmpty {
                ForEach(leave, id: \.self) { label in
                    Label(label, systemImage: "airplane")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.teal)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
            }
            if items.isEmpty {
                if leave.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing on this day", systemImage: "calendar")
                    } description: {
                        Text("No shifts or events.")
                    }
                } else {
                    Spacer()
                }
            } else {
                List(items) { item in
                    switch item {
                    case let .shift(shift):
                        ShiftAgendaRow(
                            shift: shift,
                            conflictTitles: conflicts[item.id] ?? [],
                            onRemoveShift: onRemoveShift,
                            onEditNote: onEditNote
                        )
                    case let .event(event):
                        EventAgendaRow(event: event)
                    case let .preview(preview):
                        PreviewAgendaRow(preview: preview, conflictTitles: conflicts[item.id] ?? [])
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

private struct ShiftAgendaRow: View {
    @Environment(\.helmAccent) private var accent
    let shift: ShiftItem
    var conflictTitles: [String] = []
    var onRemoveShift: ((ShiftItem) -> Void)?
    var onEditNote: ((String, String?) -> Void)?

    @State private var editingNote = false
    @State private var draftNote = ""

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: shift.colorHex) ?? accent)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(shift.title).font(.subheadline.weight(.semibold))
                if let location = shift.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !shift.tags.isEmpty {
                    TagPillRow(tags: shift.tags, colorFor: { ShiftTags.colorHex(for: $0, customColors: [:]) })
                }
                ConflictNote(titles: conflictTitles)
                noteArea
            }
            Spacer()
            if shift.isAllDay {
                Text("all-day").font(.caption).foregroundStyle(.secondary)
            } else {
                timeColumn(start: shift.start, end: shift.end, plusOne: shift.endsOnLaterDay)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            if onEditNote != nil {
                Button(shift.note?.isEmpty == false ? "Edit note…" : "Add note…", systemImage: "note.text") {
                    draftNote = shift.note ?? ""
                    editingNote = true
                }
            }
            if let onRemoveShift {
                Button("Remove shift…", systemImage: "trash", role: .destructive) { onRemoveShift(shift) }
            }
        }
    }

    @ViewBuilder
    private var noteArea: some View {
        if editingNote {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Note", text: $draftNote, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                HStack {
                    Button("Save") {
                        onEditNote?(shift.id, draftNote.isEmpty ? nil : draftNote)
                        editingNote = false
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Cancel") { editingNote = false }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            .font(.caption)
        } else if let note = shift.note, !note.isEmpty {
            Label(note, systemImage: "note.text")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }
}

/// "Overlaps: Dentist" — symbol + text, never color alone.
private struct ConflictNote: View {
    let titles: [String]

    var body: some View {
        if !titles.isEmpty {
            Label("Overlaps: \(titles.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }
}

private struct EventAgendaRow: View {
    let event: EventItem

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(event.color.map { Color(.sRGB, red: $0.r, green: $0.g, blue: $0.b, opacity: $0.a) } ?? .secondary)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.subheadline)
                Text(event.calendarTitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if event.isAllDay {
                Text("all-day")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                timeColumn(start: event.start, end: event.end, plusOne: false)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct PreviewAgendaRow: View {
    @Environment(\.helmAccent) private var accent
    let preview: PreviewItem
    var conflictTitles: [String] = []

    private var tag: (symbol: String, text: String, color: Color) {
        switch preview.status {
        case .added: ("plus.circle.fill", "Added", .green)
        case .updated: ("pencil.circle.fill", "Changed", .orange)
        case .removed: ("minus.circle.fill", "Removed", .red)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: preview.colorHex) ?? accent)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(preview.title)
                    .font(.subheadline.weight(.semibold))
                    .strikethrough(preview.status == .removed)
                Label(tag.text, systemImage: tag.symbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(tag.color)
                ConflictNote(titles: conflictTitles)
            }
            Spacer()
            if preview.isAllDay {
                Text("all-day")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                timeColumn(start: preview.start, end: preview.end, plusOne: preview.endsOnLaterDay)
            }
        }
        .padding(.vertical, 2)
        .opacity(preview.status == .removed ? 0.65 : 1)
    }
}

@ViewBuilder
private func timeColumn(start: Date?, end: Date?, plusOne: Bool) -> some View {
    VStack(alignment: .trailing, spacing: 1) {
        if let start {
            Text(start, format: .dateTime.hour().minute())
        }
        if let end {
            HStack(spacing: 1) {
                Text(end, format: .dateTime.hour().minute())
                if plusOne {
                    Text("+1")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                }
            }
        }
    }
    .font(.caption.monospacedDigit())
    .foregroundStyle(.secondary)
}
