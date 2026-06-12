//
//  NextShiftWidget.swift
//  HelmWidget (STAGED — add to the widget target in Xcode; see README.md)
//
//  Home/lock-screen widget: the next shift + this week's hours, read from the
//  shared snapshot. Refreshes at the next shift boundary (or hourly).
//

import WidgetKit
import SwiftUI
import HelmDomain

struct HelmEntry: TimelineEntry {
    let date: Date
    let snapshot: HelmSnapshot
}

struct HelmProvider: TimelineProvider {
    func placeholder(in context: Context) -> HelmEntry {
        HelmEntry(date: .now, snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (HelmEntry) -> Void) {
        completion(HelmEntry(date: .now, snapshot: SnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HelmEntry>) -> Void) {
        let snapshot = SnapshotStore.load()
        let entry = HelmEntry(date: .now, snapshot: snapshot)
        // Refresh at the next meaningful boundary: the next shift's start/end,
        // else in an hour.
        let cal = Calendar.current
        let nextMidnight = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: .now) ?? .now.addingTimeInterval(86400))
        let candidates = ([snapshot.next?.start, snapshot.next?.end, snapshot.current?.end].compactMap { $0 } + [nextMidnight])
            .filter { $0 > .now }
        let refreshDate = candidates.min() ?? Date.now.addingTimeInterval(3600)
        // TWO entries: the boundary entry is PRE-RENDERED, so the view flips
        // (on-now promotion, today ring, gauge step) exactly at the boundary
        // even if WidgetKit defers the actual reload (.after is best-effort).
        let boundary = HelmEntry(date: refreshDate, snapshot: snapshot)
        completion(Timeline(entries: [entry, boundary], policy: .after(refreshDate)))
    }
}

struct NextShiftWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HelmNextShift", provider: HelmProvider()) { entry in
            NextShiftWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Next Shift")
        .description("Your next shift and this week's hours.")
        // Accessory (lock-screen) families exist only on iOS — the target
        // also builds for macOS/visionOS, where those symbols are unavailable.
        #if os(iOS)
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
        #else
        .supportedFamilies([.systemSmall, .systemMedium])
        #endif
    }
}

struct NextShiftWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HelmEntry

    var body: some View {
        switch family {
        #if os(iOS)
        case .accessoryInline:
            Label(inlineText, systemImage: "briefcase")
        case .accessoryRectangular:
            rectangular
        #endif
        case .systemMedium:
            medium
        default:
            small
        }
    }

    // The ONE set of stale-blob rules (shared with the watch): a started
    // "next" is promoted to ON NOW; a finished "current" disappears.
    private var next: SnapshotShift? { SnapshotMath.upcoming(in: entry.snapshot, at: entry.date) }
    private var current: SnapshotShift? { SnapshotMath.onNow(in: entry.snapshot, at: entry.date) }

    private var inlineText: String {
        if let current { return "On now: \(current.title)" }
        guard let next else { return "No upcoming shift" }
        if next.isAllDay { return next.title }
        if let start = next.start {
            return "\(next.title) \(start.formatted(date: .omitted, time: .shortened))"
        }
        return next.title
    }

    private var accent: Color { Color(helmHex: next?.colorHex) ?? .accentColor }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let current {
                Text("ON NOW").font(.caption2.weight(.bold)).foregroundStyle(.green)
                Text(current.title).font(.headline).lineLimit(2)
                if let end = current.end {
                    Text("until \(end.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let next {
                Text("NEXT SHIFT").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                Text(next.title).font(.headline).lineLimit(2)
                if next.isAllDay {
                    Text("Times TBC").font(.caption).foregroundStyle(.orange)
                } else if let start = next.start {
                    Text(start, format: .dateTime.weekday().day().month()).font(.caption).foregroundStyle(.secondary)
                    Text(start, format: .dateTime.hour().minute()).font(.title3.weight(.semibold)).foregroundStyle(accent)
                }
            } else {
                Text("NEXT SHIFT").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                Text("Nothing scheduled").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(hours) h this week").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            small
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("TODAY").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                // Recomputed at render time — the stored array names the BUILD
                // day, which midnight outruns.
                let todays = SnapshotMath.todayShifts(in: entry.snapshot, at: entry.date, calendar: Calendar.current)
                if todays.isEmpty {
                    Text("No shifts today").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(todays.prefix(3)) { shift in
                        HStack(spacing: 5) {
                            Circle().fill(Color(helmHex: shift.colorHex) ?? .accentColor).frame(width: 7, height: 7)
                            Text(shift.title).font(.caption).lineLimit(1)
                            Spacer()
                            if !shift.isAllDay, let s = shift.start {
                                Text(s, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let current {
                Text(current.title).font(.headline).lineLimit(1)
                if let end = current.end {
                    Text("On now · ends \(end.formatted(date: .omitted, time: .shortened))").font(.caption)
                }
            } else {
                Text(next?.title ?? "No upcoming shift").font(.headline).lineLimit(1)
                if let next, !next.isAllDay, let start = next.start {
                    Text(start, format: .dateTime.weekday().hour().minute()).font(.caption)
                } else if next?.isAllDay == true {
                    Text("Times TBC").font(.caption)
                }
            }
            Text("\(hours) h this week").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var hours: String {
        entry.snapshot.weekHours.formatted(.number.precision(.fractionLength(0...1)))
    }
}
