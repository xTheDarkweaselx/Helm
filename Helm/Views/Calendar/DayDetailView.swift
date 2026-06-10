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
    /// Present in .live mode: offer "Remove shift" on shift rows (v4).
    var onRemoveShift: ((ShiftItem) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(day.startOfDay(in: Calendar.current), format: .dateTime.weekday(.wide).day().month(.wide))
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .accessibilityAddTraits(.isHeader)
            Divider()
            if items.isEmpty {
                ContentUnavailableView {
                    Label("Nothing on this day", systemImage: "calendar")
                } description: {
                    Text("No shifts or events.")
                }
            } else {
                List(items) { item in
                    switch item {
                    case let .shift(shift):
                        ShiftAgendaRow(shift: shift, conflictTitles: conflicts[item.id] ?? [])
                            .contextMenu {
                                if let onRemoveShift {
                                    Button("Remove shift…", systemImage: "trash", role: .destructive) {
                                        onRemoveShift(shift)
                                    }
                                }
                            }
                    case let .event(event):
                        EventAgendaRow(event: event)
                    case let .preview(preview):
                        PreviewAgendaRow(preview: preview, conflictTitles: conflicts[item.id] ?? [])
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

private struct ShiftAgendaRow: View {
    let shift: ShiftItem
    var conflictTitles: [String] = []

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: shift.colorHex) ?? .accentColor)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(shift.title).font(.subheadline.weight(.semibold))
                if let location = shift.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ConflictNote(titles: conflictTitles)
            }
            Spacer()
            if shift.isAllDay {
                Text("all-day")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                timeColumn(start: shift.start, end: shift.end, plusOne: shift.endsOnLaterDay)
            }
        }
        .padding(.vertical, 2)
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
                .fill(Color(hex: preview.colorHex) ?? .accentColor)
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
