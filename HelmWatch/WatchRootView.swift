//
//  WatchRootView.swift
//  HelmWatch (STAGED — add to the watch APP target in Xcode; see README.md)
//
//  Three vertically-paged tabs: Next Shift (or On Now with a live countdown),
//  Today's shifts, and the week gauge. Renders the pushed HelmSnapshot.
//

import SwiftUI
import HelmDomain

struct WatchRootView: View {
    @Environment(PhoneLink.self) private var link

    var body: some View {
        if link.snapshot == .empty {
            VStack(spacing: 6) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Open Helm on your iPhone to sync your shifts.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding()
        } else {
            TabView {
                NextShiftTab(snapshot: link.snapshot)
                TodayTab(snapshot: link.snapshot)
                WeekTab(snapshot: link.snapshot)
            }
            .tabViewStyle(.verticalPage)
        }
    }
}

// MARK: - Next / On Now

struct NextShiftTab: View {
    let snapshot: HelmSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let current = snapshot.current, let end = current.end {
                Text("ON NOW")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.green)
                Text(current.title)
                    .font(.headline)
                    .lineLimit(2)
                if let location = current.location, !location.isEmpty {
                    Text(location).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 4) {
                    Text("ends in")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(end, style: .timer)
                        .font(.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(tint(of: current))
                }
            } else if let next = freshNext {
                Text("NEXT SHIFT")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(next.title)
                    .font(.headline)
                    .lineLimit(2)
                if next.isAllDay {
                    Text(next.isTentative == true ? "Times TBC" : "All-day")
                        .font(.caption)
                        .foregroundStyle(next.isTentative == true ? .orange : .secondary)
                } else if let start = next.start {
                    Text(start, format: .dateTime.weekday(.wide).day().month())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(start, format: .dateTime.hour().minute())
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(tint(of: next))
                    Text(start, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Nothing scheduled")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 4)
    }

    /// Drop a "next" whose start already passed (the snapshot can be stale
    /// between pushes — same guard the iOS widget applies).
    private var freshNext: SnapshotShift? {
        guard let n = snapshot.next else { return nil }
        if let start = n.start, start <= .now { return nil }
        return n
    }

    private func tint(of shift: SnapshotShift) -> Color {
        Color(helmHex: shift.colorHex) ?? .accentColor
    }
}

// MARK: - Today

struct TodayTab: View {
    let snapshot: HelmSnapshot

    var body: some View {
        List {
            Section("Today") {
                if snapshot.today.isEmpty {
                    Text("No shifts today")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.today) { shift in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(shift.isTentative == true ? Color.orange : (Color(helmHex: shift.colorHex) ?? .accentColor))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(shift.title).font(.footnote).lineLimit(1)
                                if shift.isAllDay {
                                    Text(shift.isTentative == true ? "Times TBC" : "All-day")
                                        .font(.caption2)
                                        .foregroundStyle(shift.isTentative == true ? .orange : .secondary)
                                } else if let s = shift.start, let e = shift.end {
                                    Text("\(s.formatted(date: .omitted, time: .shortened))–\(e.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Week

struct WeekTab: View {
    let snapshot: HelmSnapshot

    private var total: Double { snapshot.weekHours }
    private var completed: Double { min(snapshot.weekHoursCompleted ?? 0, total) }

    var body: some View {
        VStack(spacing: 6) {
            Gauge(value: total > 0 ? completed / total : 0) {
                Text("h")
            } currentValueLabel: {
                Text(completed.formatted(.number.precision(.fractionLength(0...1))))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            }
            .gaugeStyle(.circular)
            Text("\(completed.formatted(.number.precision(.fractionLength(0...1)))) of \(total.formatted(.number.precision(.fractionLength(0...1)))) h")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(snapshot.weekShiftCount) shift\(snapshot.weekShiftCount == 1 ? "" : "s") this week")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let tbc = snapshot.weekTBCCount, tbc > 0 {
                Text("\(tbc) TBC")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Local hex helper (Color(hex:) lives in the iOS/macOS app target)

extension Color {
    init?(helmHex hex: String?) {
        guard var hex else { return nil }
        hex = hex.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard let value = UInt64(hex, radix: 16) else { return nil }
        let r, g, b, a: Double
        switch hex.count {
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        case 8:
            a = Double((value >> 24) & 0xFF) / 255
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        default:
            return nil
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
