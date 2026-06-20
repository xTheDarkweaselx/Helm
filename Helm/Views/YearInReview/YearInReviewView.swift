//
//  YearInReviewView.swift
//  Helm
//
//  v9 Shift Year in Review: a paged, Wrapped-style recap of the year's shifts,
//  rendered from the pure HelmDomain.YearInReview aggregate. Presented from the
//  Overview; shareable as a text recap.
//

import SwiftUI
import HelmDomain

struct YearInReviewView: View {
    let review: YearInReview
    @Environment(\.helmAccent) private var accent
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private struct Highlight: Identifiable {
        let id = UUID()
        let icon: String
        let value: String
        let title: String
        let subtitle: String?
    }

    private var highlights: [Highlight] {
        var h: [Highlight] = [
            Highlight(icon: "calendar", value: "\(review.totalShifts)",
                      title: "shifts in \(review.year)", subtitle: "across \(review.daysWorked) day\(review.daysWorked == 1 ? "" : "s")"),
            Highlight(icon: "clock.fill", value: hoursText(review.totalHours),
                      title: "hours worked", subtitle: "about \(hoursText(review.totalHours / 52)) per week"),
        ]
        if let m = review.busiestMonth {
            h.append(Highlight(icon: "chart.bar.fill", value: monthName(m),
                               title: "your busiest month", subtitle: "\(hoursText(review.busiestMonthHours)) hours"))
        }
        if let type = review.topTypeLabel {
            h.append(Highlight(icon: "star.fill", value: type,
                               title: "your go-to shift", subtitle: "worked \(review.topTypeCount) time\(review.topTypeCount == 1 ? "" : "s")"))
        }
        if review.longestStreakDays > 1 {
            h.append(Highlight(icon: "flame.fill", value: "\(review.longestStreakDays) days",
                               title: "longest run", subtitle: "back-to-back shifts"))
        }
        if review.nightShifts > 0 {
            h.append(Highlight(icon: "moon.stars.fill", value: "\(review.nightShifts)",
                               title: "night shifts", subtitle: review.weekendShifts > 0 ? "and \(review.weekendShifts) at the weekend" : nil))
        }
        if let start = review.earliestStartMinute {
            h.append(Highlight(icon: "sunrise.fill", value: hhmm(start),
                               title: "your earliest start", subtitle: "rise and shine"))
        }
        return h
    }

    var body: some View {
        NavigationStack {
            Group {
                if review.hasData {
                    content
                } else {
                    ContentUnavailableView("No shifts in \(String(review.year)) yet",
                                           systemImage: "calendar",
                                           description: Text("Import or build a roster and your year in review will appear here."))
                }
            }
            .themedPane(.plain)
            .navigationTitle(Text(verbatim: "\(review.year) in Review"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if review.hasData {
                    ToolbarItem(placement: .cancellationAction) {
                        ShareLink(item: textRecap) { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
        }
    }

    private var content: some View {
        #if os(iOS)
        TabView(selection: $page) {
            ForEach(Array(highlights.enumerated()), id: \.offset) { i, h in
                card(h).tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        #else
        ScrollView {
            VStack(spacing: 16) {
                ForEach(highlights) { card($0).frame(minHeight: 220) }
            }
            .padding()
        }
        #endif
    }

    private func card(_ h: Highlight) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: h.icon)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 96, height: 96)
                .background(
                    LinearGradient(colors: [accent, accent.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )
            Text(h.value)
                .font(.system(size: 44, design: .rounded).weight(.bold))
                .foregroundStyle(accent)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)
                .lineLimit(2)
            Text(h.title)
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.center)
            if let sub = h.subtitle {
                Text(sub).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
    }

    private var textRecap: String {
        var lines = ["My \(review.year) in shifts ⚓️",
                     "• \(review.totalShifts) shifts, \(hoursText(review.totalHours)) hours across \(review.daysWorked) days"]
        if let m = review.busiestMonth { lines.append("• Busiest month: \(monthName(m)) (\(hoursText(review.busiestMonthHours)) h)") }
        if let t = review.topTypeLabel { lines.append("• Go-to shift: \(t) ×\(review.topTypeCount)") }
        if review.longestStreakDays > 1 { lines.append("• Longest run: \(review.longestStreakDays) days") }
        if review.nightShifts > 0 { lines.append("• \(review.nightShifts) night shifts") }
        lines.append("— via Helm")
        return lines.joined(separator: "\n")
    }

    // MARK: formatting
    private func hoursText(_ h: Double) -> String { h.formatted(.number.precision(.fractionLength(0...0))) }
    private func hhmm(_ minute: Int) -> String { String(format: "%02d:%02d", (minute / 60) % 24, minute % 60) }
    private func monthName(_ m: Int) -> String {
        DateComponents(calendar: .current, month: m).date.map { $0.formatted(.dateTime.month(.wide)) } ?? "\(m)"
    }
}
