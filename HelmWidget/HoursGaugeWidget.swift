//
//  HoursGaugeWidget.swift
//  HelmWidget
//
//  v7.5: hours worked vs scheduled this week as a gauge — a lock-screen
//  circular (iOS) and a small home-screen card. Numerator = shifts that have
//  already ended (weekHoursCompleted, v7.5 snapshot field); denominator =
//  the week's scheduled hours.
//

import WidgetKit
import SwiftUI
import HelmDomain

struct HoursGaugeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HelmHoursGauge", provider: HelmProvider()) { entry in
            HoursGaugeView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Week Hours")
        .description("Hours worked vs scheduled this week.")
        // Accessory (lock-screen) families exist only on iOS.
        #if os(iOS)
        .supportedFamilies([.systemSmall, .accessoryCircular])
        #else
        .supportedFamilies([.systemSmall])
        #endif
    }
}

struct HoursGaugeView: View {
    @Environment(\.widgetFamily) private var family
    let entry: HelmEntry

    private var total: Double { entry.snapshot.weekHours }
    /// Live at render time (SnapshotMath walks the week grid; a v1 blob falls
    /// back to the build-time scalar). Zero after a week rollover — honest.
    private var completed: Double {
        guard SnapshotMath.isWeekCurrent(entry.snapshot, at: entry.date, calendar: Calendar.current) else { return 0 }
        return min(SnapshotMath.completedHours(in: entry.snapshot, at: entry.date) ?? 0, total)
    }
    private var shiftCount: Int { entry.snapshot.weekShiftCount }
    private var tbcCount: Int { entry.snapshot.weekTBCCount ?? 0 }

    var body: some View {
        switch family {
        #if os(iOS)
        case .accessoryCircular:
            circular
        #endif
        default:
            small
        }
    }

    private var gaugeValue: Double { total > 0 ? completed / total : 0 }

    #if os(iOS)
    private var circular: some View {
        Gauge(value: gaugeValue) {
            Text("h")
        } currentValueLabel: {
            Text(total > 0 ? short(completed) : "–")
                .font(.system(.body, design: .rounded).weight(.semibold))
                .monospacedDigit()
        }
        .gaugeStyle(.accessoryCircularCapacity)
    }
    #endif

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("WEEK HOURS").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            if total > 0 {
                Gauge(value: gaugeValue) { EmptyView() }
                    .gaugeStyle(.linearCapacity)
                    .tint(.accentColor)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(short(completed))
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                    Text("of \(short(total)) h")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(shiftCount) shift\(shiftCount == 1 ? "" : "s") this week")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if shiftCount > 0 {
                // A week of TBC/all-day shifts has no timed hours — that is
                // NOT "no shifts".
                Spacer(minLength: 0)
                Text(tbcCount > 0
                     ? "\(shiftCount) shift\(shiftCount == 1 ? "" : "s") — times TBC"
                     : "\(shiftCount) all-day shift\(shiftCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(tbcCount > 0 ? .orange : .secondary)
            } else {
                Spacer(minLength: 0)
                Text("No shifts this week")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func short(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }
}
