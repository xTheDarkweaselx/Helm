//
//  MonthGridView.swift
//  Helm
//
//  One month page: a fixed 6×7 grid of DayCellViews. Fixed row count keeps
//  every page the same height so horizontal paging never jumps.
//

import SwiftUI
import HelmDomain

/// What a day cell needs to render its summary.
nonisolated struct DayCellSummary {
    let shifts: [ShiftItem]
    let previews: [PreviewItem]
    let eventCount: Int
    let eventColors: [EventItem.RGBA?]
}

struct MonthGridView: View {
    let grid: MonthGrid
    @Binding var selectedDay: DayKey
    let today: DayKey
    let compact: Bool
    let dayContent: (DayKey) -> DayCellSummary

    var body: some View {
        SwiftUI.Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(grid.weeks.enumerated()), id: \.offset) { _, week in
                GridRow {
                    ForEach(week) { cell in
                        DayCellView(
                            cell: cell,
                            summary: dayContent(cell.day),
                            isSelected: cell.day == selectedDay,
                            isToday: cell.day == today,
                            compact: compact
                        )
                        .onTapGesture { selectedDay = cell.day }
                    }
                }
            }
        }
    }
}

struct DayCellView: View {
    let cell: MonthGrid.Cell
    let summary: DayCellSummary
    let isSelected: Bool
    let isToday: Bool
    let compact: Bool

    private var maxChips: Int { compact ? 1 : 2 }

    var body: some View {
        VStack(spacing: 3) {
            numeral
            chips
            if summary.eventCount > 0 { eventDots }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity)
        .frame(height: compact ? 64 : 96)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .opacity(cell.isInMonth ? 1 : 0.35)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var numeral: some View {
        Text("\(cell.day.day)")
            .font(.callout.weight(isToday ? .bold : .regular))
            .monospacedDigit()
            .foregroundStyle(isToday ? Color.white : .primary)
            .frame(width: 26, height: 26)
            .background(Circle().fill(isToday ? Color.accentColor : .clear))
    }

    @ViewBuilder
    private var chips: some View {
        let shiftChips = summary.shifts.prefix(maxChips)
        let remainingSlots = maxChips - shiftChips.count
        let previewChips = summary.previews.prefix(max(0, remainingSlots + (summary.previews.isEmpty ? 0 : 1)))
        let overflow = (summary.shifts.count - shiftChips.count)
            + (summary.previews.count - previewChips.count)

        VStack(spacing: 2) {
            ForEach(shiftChips) { shift in
                chip(text: shift.title, color: Color(hex: shift.colorHex) ?? .accentColor, status: nil)
            }
            ForEach(previewChips) { preview in
                chip(text: preview.title,
                     color: Color(hex: preview.colorHex) ?? .accentColor,
                     status: preview.status)
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chip(text: String, color: Color, status: PreviewItem.Status?) -> some View {
        HStack(spacing: 2) {
            if let status {
                Image(systemName: statusSymbol(status))
                    .font(.system(size: 7, weight: .bold))
            }
            Text(text)
                .strikethrough(status == .removed)
        }
        .font(.caption2.weight(.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 4)
        .padding(.vertical, 1.5)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(chipBackground(color: color, status: status))
        )
        .foregroundStyle(status.map(statusColor) ?? .primary)
        .opacity(status == .removed ? 0.6 : 1)
    }

    private func chipBackground(color: Color, status: PreviewItem.Status?) -> Color {
        switch status {
        case .added: Color.green.opacity(0.18)
        case .updated: Color.orange.opacity(0.18)
        case .removed: Color.red.opacity(0.12)
        case nil: color.opacity(0.22)
        }
    }

    private func statusSymbol(_ status: PreviewItem.Status) -> String {
        switch status {
        case .added: "plus"
        case .updated: "pencil"
        case .removed: "minus"
        }
    }

    private func statusColor(_ status: PreviewItem.Status) -> Color {
        switch status {
        case .added: .green
        case .updated: .orange
        case .removed: .red
        }
    }

    private var eventDots: some View {
        HStack(spacing: 3) {
            ForEach(Array(summary.eventColors.prefix(4).enumerated()), id: \.offset) { _, rgba in
                Circle()
                    .fill(rgba.map { Color(.sRGB, red: $0.r, green: $0.g, blue: $0.b, opacity: $0.a) } ?? Color.secondary)
                    .frame(width: 5, height: 5)
            }
            if summary.eventCount > 4 {
                Text("\(summary.eventCount)")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        let cal = Calendar.current
        let date = cell.day.startOfDay(in: cal)
        parts.append(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
        for shift in summary.shifts {
            var s = shift.title
            if let start = shift.start, let end = shift.end {
                s += ", \(start.formatted(date: .omitted, time: .shortened)) to \(end.formatted(date: .omitted, time: .shortened))"
            }
            parts.append(s)
        }
        for preview in summary.previews {
            let verb = switch preview.status {
            case .added: "will be added"
            case .updated: "will change"
            case .removed: "will be removed"
            }
            parts.append("\(preview.title) \(verb)")
        }
        if summary.eventCount > 0 {
            parts.append("\(summary.eventCount) event\(summary.eventCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ")
    }
}
