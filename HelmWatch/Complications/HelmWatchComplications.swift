//
//  HelmWatchComplications.swift
//  HelmWatchComplications (STAGED — this file is the @main of the WATCH widget
//  extension target; see ../README.md)
//
//  Watch-face complications: Next Shift (rectangular / inline) and the week
//  hours gauge (circular / corner). Self-contained: reads the snapshot the
//  watch APP persisted (PhoneLink writes both the shared suite and standard
//  defaults under the same key).
//

import WidgetKit
import SwiftUI
import HelmDomain

@main
struct HelmWatchComplicationsBundle: WidgetBundle {
    var body: some Widget {
        WatchNextShiftComplication()
        WatchHoursGaugeComplication()
    }
}

// MARK: - Shared provider

struct WatchSnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: HelmSnapshot
}

struct WatchSnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchSnapshotEntry {
        WatchSnapshotEntry(date: .now, snapshot: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchSnapshotEntry) -> Void) {
        completion(WatchSnapshotEntry(date: .now, snapshot: load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchSnapshotEntry>) -> Void) {
        let snapshot = load()
        let entry = WatchSnapshotEntry(date: .now, snapshot: snapshot)
        let cal = Calendar.current
        let nextMidnight = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: .now) ?? .now.addingTimeInterval(86400))
        let candidates = ([snapshot.next?.start, snapshot.next?.end, snapshot.current?.end].compactMap { $0 } + [nextMidnight])
            .filter { $0 > .now }
        completion(Timeline(entries: [entry], policy: .after(candidates.min() ?? Date.now.addingTimeInterval(3600))))
    }

    /// PhoneLink stores the blob under the SAME key in both the shared suite
    /// (when the watch targets carry the App Group) and standard defaults.
    private func load() -> HelmSnapshot {
        let data = UserDefaults(suiteName: HelmAppGroup.defaultsSuite)?.data(forKey: HelmAppGroup.snapshotDefaultsKey)
            ?? UserDefaults.standard.data(forKey: HelmAppGroup.snapshotDefaultsKey)
        guard let data, let snap = try? JSONDecoder().decode(HelmSnapshot.self, from: data) else { return .empty }
        return snap
    }
}

// MARK: - Next Shift complication

struct WatchNextShiftComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HelmWatchNextShift", provider: WatchSnapshotProvider()) { entry in
            WatchNextShiftView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Next Shift")
        .description("Your next shift on the watch face.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}

struct WatchNextShiftView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchSnapshotEntry

    private var next: SnapshotShift? {
        if entry.snapshot.current != nil { return nil } // inline/rect show "on now" instead
        guard let n = entry.snapshot.next else { return nil }
        if let start = n.start, start <= entry.date { return nil }
        return n
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            if let current = entry.snapshot.current {
                Text("On now: \(current.title)")
            } else if let next {
                if let start = next.start {
                    Text("\(next.title) \(start.formatted(date: .omitted, time: .shortened))")
                } else {
                    Text(next.title)
                }
            } else {
                Text("No upcoming shift")
            }
        default:
            rectangular
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let current = entry.snapshot.current, let end = current.end {
                Text("ON NOW").font(.caption2.weight(.bold)).foregroundStyle(.green)
                Text(current.title).font(.headline).lineLimit(1)
                Text("ends \(end.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if let next {
                Text(next.title).font(.headline).lineLimit(1)
                if next.isAllDay {
                    Text(next.isTentative == true ? "Times TBC" : "All-day")
                        .font(.caption2)
                        .foregroundStyle(next.isTentative == true ? .orange : .secondary)
                } else if let start = next.start {
                    Text(start, format: .dateTime.weekday(.abbreviated).hour().minute())
                        .font(.caption)
                }
                Text("\(entry.snapshot.weekHours.formatted(.number.precision(.fractionLength(0...1)))) h this week")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("No upcoming shift").font(.headline)
                Text("\(entry.snapshot.weekHours.formatted(.number.precision(.fractionLength(0...1)))) h this week")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Hours gauge complication

struct WatchHoursGaugeComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HelmWatchHoursGauge", provider: WatchSnapshotProvider()) { entry in
            WatchHoursGaugeView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Week Hours")
        .description("Hours worked vs scheduled this week.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner])
    }
}

struct WatchHoursGaugeView: View {
    let entry: WatchSnapshotEntry

    private var total: Double { entry.snapshot.weekHours }
    private var completed: Double { min(entry.snapshot.weekHoursCompleted ?? 0, total) }

    var body: some View {
        Gauge(value: total > 0 ? completed / total : 0) {
            Text("h")
        } currentValueLabel: {
            Text(total > 0 ? completed.formatted(.number.precision(.fractionLength(0...1))) : "–")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
        .gaugeStyle(.accessoryCircularCapacity)
    }
}
