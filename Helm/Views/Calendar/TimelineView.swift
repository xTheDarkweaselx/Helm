//
//  TimelineView.swift
//  Helm
//
//  v6: the hour-axis Week/Day timeline. Pure block math comes from
//  HelmDomain.TimelineLayoutEngine (clipping, DST-true axis, Apple-Calendar
//  column packing); this file only renders: hour gutter + gridlines, an
//  all-day lane (TBC shifts live there), a now-line, and the blocks —
//  shifts first-class, other events muted, preview diff states tinted.
//

import SwiftUI
import HelmDomain

/// One renderable item for the timeline (already display-filtered).
nonisolated struct TimelineBlock: Identifiable, Hashable, Sendable {
    let id: String
    let start: Date
    let end: Date
    let title: String
    let colorHex: String?
    let eventColor: EventItem.RGBA?
    let isEvent: Bool
    let previewStatus: PreviewItem.Status?
}

nonisolated struct TimelineAllDayChip: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let colorHex: String?
    let eventColor: EventItem.RGBA?
    let isEvent: Bool
    let previewStatus: PreviewItem.Status?
}

nonisolated struct DayBlocks {
    let timed: [TimelineBlock]
    let allDay: [TimelineAllDayChip]
}

struct TimelinePane: View {
    let days: [DayKey]                       // 1 (day mode) or 7 (week mode)
    let today: DayKey
    let selectedDay: DayKey
    let hourHeight: Double
    let blocks: (DayKey) -> DayBlocks
    let onSelectDay: (DayKey) -> Void

    private var calendar: Calendar { CalendarViewModel.displayCalendar }
    private static let gutterWidth: CGFloat = 44

    var body: some View {
        VStack(spacing: 0) {
            if days.count > 1 { weekdayHeader }
            allDayLane
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        hourGutter
                        ForEach(days, id: \.self) { day in
                            TimelineDayColumn(
                                day: day,
                                isToday: day == today,
                                hourHeight: hourHeight,
                                blocks: blocks(day).timed
                            )
                            .onTapGesture { onSelectDay(day) }
                            if day != days.last { Divider() }
                        }
                    }
                }
                .onAppear {
                    // Land at the working morning (gutter rows carry hour ids;
                    // a negative-anchor scrollTo on the whole content no-ops).
                    proxy.scrollTo("hour-7", anchor: .top)
                }
            }
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.gutterWidth, height: 1)
            ForEach(days, id: \.self) { day in
                Button {
                    onSelectDay(day)
                } label: {
                    VStack(spacing: 1) {
                        Text(day.startOfDay(in: calendar), format: .dateTime.weekday(.narrow))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(day.day)")
                            .font(.callout.weight(day == today ? .bold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(day == today ? Color.white : .primary)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(day == today ? Color.accentColor : .clear))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(day == selectedDay ? Color.accentColor.opacity(0.1) : .clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 2)
    }

    /// All-day shifts (TBC), events and previews — pinned above the hour grid.
    @ViewBuilder
    private var allDayLane: some View {
        let chips = days.flatMap { day in blocks(day).allDay.map { (day, $0) } }
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("all-day")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, pair in
                        let (day, chip) = pair
                        HStack(spacing: 3) {
                            if days.count > 1 {
                                Text(day.startOfDay(in: calendar), format: .dateTime.weekday(.abbreviated))
                                    .font(.caption2.weight(.semibold))
                            }
                            if let status = chip.previewStatus {
                                Image(systemName: status == .added ? "plus" : status == .updated ? "pencil" : "minus")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            Text(chip.title)
                                .strikethrough(chip.previewStatus == .removed)
                        }
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            (Color(hex: chip.colorHex)
                                ?? chip.eventColor.map { Color(.sRGB, red: $0.r, green: $0.g, blue: $0.b, opacity: $0.a) }
                                ?? (chip.isEvent ? Color.secondary : .accentColor)).opacity(0.2),
                            in: Capsule()
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
    }

    private var hourGutter: some View {
        // Sized by the LONGEST visible day; labels are true wall-clock at each
        // y-position (on a DST day, elapsed-hour 2 may be 03:00 on the wall).
        let referenceDay = days.max { day1, day2 in
            TimelineLayoutEngine.dayLengthMinutes(day: day1, calendar: calendar)
                < TimelineLayoutEngine.dayLengthMinutes(day: day2, calendar: calendar)
        } ?? today
        let length = TimelineLayoutEngine.dayLengthMinutes(day: referenceDay, calendar: calendar)
        let dayStart = referenceDay.startOfDay(in: calendar)
        var formatter: DateFormatter {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX") // stable 24h labels
            f.dateFormat = "HH:mm"
            f.timeZone = calendar.timeZone
            return f
        }
        let hourFormatter = formatter
        return VStack(alignment: .trailing, spacing: 0) {
            ForEach(0..<Int(ceil(length / 60)), id: \.self) { hour in
                Text(hourFormatter.string(from: dayStart.addingTimeInterval(Double(hour) * 3600)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(height: hourHeight, alignment: .top)
                    .id("hour-\(hour)")
            }
        }
        .frame(width: Self.gutterWidth - 4, alignment: .trailing)
        .padding(.trailing, 4)
        .accessibilityHidden(true)
    }
}

struct TimelineDayColumn: View {
    let day: DayKey
    let isToday: Bool
    let hourHeight: Double
    let blocks: [TimelineBlock]

    private var calendar: Calendar { CalendarViewModel.displayCalendar }

    var body: some View {
        let dayLength = TimelineLayoutEngine.dayLengthMinutes(day: day, calendar: calendar)
        let height = dayLength / 60 * hourHeight
        let placed = TimelineLayoutEngine.layout(
            spans: blocks.map { TimelineLayoutEngine.Span(id: $0.id, start: $0.start, end: $0.end) },
            day: day,
            calendar: calendar
        )
        let blocksByID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })

        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Hour gridlines (one Canvas — cheap).
                Canvas { context, size in
                    var hour = 0.0
                    while hour * 60 <= dayLength {
                        let y = hour * hourHeight
                        context.stroke(
                            Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                            with: .color(.secondary.opacity(0.15)),
                            lineWidth: 0.5
                        )
                        hour += 1
                    }
                }

                ForEach(placed) { item in
                    if let block = blocksByID[item.id] {
                        let width = (geo.size.width - 2) / Double(item.columnCount)
                        TimelineBlockView(block: block, placed: item)
                            .frame(
                                width: max(width - 2, 8),
                                height: max((item.endMinute - item.startMinute) / 60 * hourHeight - 1, 10)
                            )
                            .offset(
                                x: 1 + width * Double(item.column),
                                y: item.startMinute / 60 * hourHeight
                            )
                    }
                }

                if isToday {
                    SwiftUI.TimelineView(.everyMinute) { context in
                        nowLine(dayLength: dayLength, at: context.date)
                    }
                }
            }
        }
        .frame(height: height)
        .background(isToday ? Color.accentColor.opacity(0.04) : .clear)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func nowLine(dayLength: Double, at now: Date) -> some View {
        let dayStart = day.startOfDay(in: calendar)
        let minutes = now.timeIntervalSince(dayStart) / 60
        if minutes >= 0 && minutes <= dayLength {
            HStack(spacing: 0) {
                Circle().fill(Color.red).frame(width: 6, height: 6)
                Rectangle().fill(Color.red).frame(height: 1)
            }
            .offset(y: minutes / 60 * hourHeight - 3)
            .accessibilityHidden(true)
        }
    }
}

private struct TimelineBlockView: View {
    let block: TimelineBlock
    let placed: TimelineLayoutEngine.Placed

    private var tint: Color {
        if let status = block.previewStatus {
            switch status {
            case .added: return .green
            case .updated: return .orange
            case .removed: return .red
            }
        }
        if let hex = Color(hex: block.colorHex) { return hex }
        if let rgba = block.eventColor {
            return Color(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
        }
        return block.isEvent ? .secondary : .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if placed.continuesBefore {
                Image(systemName: "arrow.up").font(.system(size: 7)).foregroundStyle(.secondary)
            }
            Text(block.title)
                .font(.caption2.weight(block.isEvent ? .regular : .semibold))
                .strikethrough(block.previewStatus == .removed)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            if placed.continuesAfter {
                Image(systemName: "arrow.down").font(.system(size: 7)).foregroundStyle(.secondary)
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(tint.opacity(block.isEvent ? 0.14 : 0.22), in: RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1).fill(tint).frame(width: 2.5)
        }
        .opacity(block.previewStatus == .removed ? 0.55 : 1)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [block.title]
        parts.append("\(block.start.formatted(date: .omitted, time: .shortened)) to \(block.end.formatted(date: .omitted, time: .shortened))")
        if let status = block.previewStatus {
            parts.append(status == .added ? "will be added" : status == .updated ? "will change" : "will be removed")
        }
        return parts.joined(separator: ", ")
    }
}
