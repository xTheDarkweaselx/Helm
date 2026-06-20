//
//  RosterSummary.swift
//  HelmDomain
//
//  v9 Roster Card: a human-readable text version of a roster you can paste into a
//  message ("here's my shifts") — the readable counterpart to the importable .ics.
//  Pure: the app supplies the per-shift lines + stats, this formats the card.
//

import Foundation

public enum RosterSummary {
    public struct ShiftLine: Sendable, Equatable {
        public let date: Date
        public let label: String
        public let detail: String?   // "07:00–15:00", "all-day", "TBC", or nil

        public init(date: Date, label: String, detail: String?) {
            self.date = date
            self.label = label
            self.detail = detail
        }
    }

    /// A readable, shareable card: a title, a stats line, then one line per shift
    /// in date order.
    public static func text(title: String, rangeText: String?, shiftCount: Int,
                            hours: Double, lines: [ShiftLine], calendar: Calendar) -> String {
        let df = DateFormatter()
        df.calendar = calendar
        df.locale = .current
        df.timeZone = calendar.timeZone
        df.dateFormat = "EEE d MMM"

        var stats = ["\(shiftCount) shift\(shiftCount == 1 ? "" : "s")"]
        if hours > 0 { stats.append("\(hours.formatted(.number.precision(.fractionLength(0...1)))) h") }
        if let rangeText, !rangeText.isEmpty { stats.append(rangeText) }

        let header = (title.trimmingCharacters(in: .whitespaces).isEmpty ? "Roster" : title)
        var out = "\(header)\n\(stats.joined(separator: " · "))\n"
        for line in lines.sorted(by: { $0.date < $1.date }) {
            let detail = line.detail.map { "  \($0)" } ?? ""
            out += "\n\(df.string(from: line.date))  \(line.label)\(detail)"
        }
        out += "\n\nShared from Helm"
        return out
    }
}
