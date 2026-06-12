//
//  WeekOverviewWidget.swift
//  HelmWidget
//
//  v7.5: the week at a glance — 7 day columns with shift colour dots (medium)
//  or one row per day with the first shift's title + times (large). Reads the
//  same shared snapshot as Next Shift (weekDays is optional: an old snapshot
//  from a pre-v7.5 app shows the refresh hint instead of lying).
//

import WidgetKit
import SwiftUI
import HelmDomain

struct WeekOverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HelmWeekOverview", provider: HelmProvider()) { entry in
            WeekOverviewView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Week Overview")
        .description("Your whole week's shifts at a glance.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct WeekOverviewView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HelmEntry

    private var week: [SnapshotDay] { entry.snapshot.weekDays ?? [] }
    private var tbcCount: Int { entry.snapshot.weekTBCCount ?? 0 }

    var body: some View {
        if week.isEmpty {
            VStack(spacing: 4) {
                Image(systemName: "calendar").foregroundStyle(.secondary)
                Text("Open Helm to refresh").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                header
                if family == .systemLarge {
                    largeRows
                } else {
                    mediumColumns
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("THIS WEEK").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            Spacer()
            if tbcCount > 0 {
                Text("\(tbcCount) TBC")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.orange.opacity(0.18), in: Capsule())
                    .foregroundStyle(.orange)
            }
            Text("\(hoursText(entry.snapshot.weekHours)) h")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
    }

    // MARK: Medium — 7 columns of dots

    private var mediumColumns: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(week) { day in
                VStack(spacing: 3) {
                    Text(day.date, format: .dateTime.weekday(.narrow))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(day.date, format: .dateTime.day())
                        .font(.caption2.weight(isToday(day) ? .bold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(isToday(day) ? Color.white : .primary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(isToday(day) ? Color.accentColor : .clear))
                    if day.shifts.isEmpty {
                        Text("–").font(.caption2).foregroundStyle(.tertiary)
                    } else {
                        VStack(spacing: 2) {
                            ForEach(day.shifts.prefix(3)) { shift in
                                Circle()
                                    .fill(shift.isTentative == true ? Color.orange : (Color(helmHex: shift.colorHex) ?? .accentColor))
                                    .frame(width: 6, height: 6)
                            }
                            if day.shifts.count > 3 {
                                Text("+\(day.shifts.count - 3)")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Large — a row per day

    private var largeRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(week) { day in
                HStack(spacing: 8) {
                    Text(day.date, format: .dateTime.weekday(.abbreviated).day())
                        .font(.caption.weight(isToday(day) ? .bold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(isToday(day) ? Color.accentColor : .primary)
                        .frame(width: 56, alignment: .leading)
                    if let first = day.shifts.first {
                        Circle()
                            .fill(first.isTentative == true ? Color.orange : (Color(helmHex: first.colorHex) ?? .accentColor))
                            .frame(width: 7, height: 7)
                        Text(first.title).font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        if first.isAllDay {
                            Text(first.isTentative == true ? "TBC" : "All-day")
                                .font(.caption2)
                                .foregroundStyle(first.isTentative == true ? .orange : .secondary)
                        } else if let s = first.start, let e = first.end {
                            Text("\(s.formatted(date: .omitted, time: .shortened))–\(e.formatted(date: .omitted, time: .shortened))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if day.shifts.count > 1 {
                            Text("+\(day.shifts.count - 1)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Off").font(.caption2).foregroundStyle(.tertiary)
                        Spacer(minLength: 4)
                    }
                }
            }
        }
    }

    private func isToday(_ day: SnapshotDay) -> Bool {
        Calendar.current.isDate(entry.date, inSameDayAs: day.date)
    }

    private func hoursText(_ hours: Double) -> String {
        hours.formatted(.number.precision(.fractionLength(0...1)))
    }
}
