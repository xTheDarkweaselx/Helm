//
//  TimelineLayoutEngine.swift
//  HelmDomain
//
//  v6 hour-axis timeline (week/day views): pure span → positioned-block math.
//  Clips spans to a single display day (with continues-before/after flags so
//  overnight shifts render with open ends), positions them in REAL minutes
//  from the day's start (DST-correct: a 23/25-hour day has a 1380/1500-minute
//  axis), and packs overlapping blocks into columns Apple-Calendar style —
//  half-open, so back-to-back M/A shifts stay full width.
//

import Foundation

public enum TimelineLayoutEngine {
    public struct Span: Sendable, Equatable {
        public let id: String
        public let start: Date
        public let end: Date

        public init(id: String, start: Date, end: Date) {
            self.id = id
            self.start = start
            self.end = end
        }
    }

    public struct Placed: Sendable, Equatable, Identifiable {
        public let id: String
        /// Minutes from the day's startOfDay (real elapsed minutes — DST-aware).
        public let startMinute: Double
        public let endMinute: Double
        /// Column index within its overlap cluster, and the cluster's width divisor.
        public let column: Int
        public let columnCount: Int
        /// True when the span continues from the previous / into the next day.
        public let continuesBefore: Bool
        public let continuesAfter: Bool
    }

    /// The day's real length in minutes (1380 / 1440 / 1500 across DST).
    public static func dayLengthMinutes(day: DayKey, calendar: Calendar) -> Double {
        let start = day.startOfDay(in: calendar)
        let next = day.advanced(by: 1, in: calendar).startOfDay(in: calendar)
        return next.timeIntervalSince(start) / 60
    }

    /// Lay out the timed spans intersecting `day`. All-day items are the
    /// caller's lane; spans that don't intersect the day are dropped.
    public static func layout(spans: [Span], day: DayKey, calendar: Calendar) -> [Placed] {
        let dayStart = day.startOfDay(in: calendar)
        let dayEnd = day.advanced(by: 1, in: calendar).startOfDay(in: calendar)

        // Clip to the day, half-open [start, end).
        struct Clipped {
            let id: String
            let start: Double
            let end: Double
            let before: Bool
            let after: Bool
        }
        var clipped: [Clipped] = []
        for span in spans {
            guard span.end > dayStart, span.start < dayEnd, span.end > span.start else { continue }
            let s = max(span.start, dayStart)
            let e = min(span.end, dayEnd)
            guard e > s else { continue }
            clipped.append(Clipped(
                id: span.id,
                start: s.timeIntervalSince(dayStart) / 60,
                end: e.timeIntervalSince(dayStart) / 60,
                before: span.start < dayStart,
                after: span.end > dayEnd
            ))
        }
        // Stable order: by start, longer first, then id.
        clipped.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end > $1.end }
            return $0.id < $1.id
        }

        // Greedy column packing within maximal overlap clusters.
        var placed: [Placed] = []
        var clusterStart = 0
        var clusterMaxEnd = -Double.infinity
        var columnEnds: [Double] = [] // per-column current end within the cluster
        var assignments: [(index: Int, column: Int)] = []

        func flushCluster(upTo endIndex: Int) {
            let count = max(columnEnds.count, 1)
            for (index, column) in assignments {
                let c = clipped[index]
                placed.append(Placed(
                    id: c.id,
                    startMinute: c.start,
                    endMinute: c.end,
                    column: column,
                    columnCount: count,
                    continuesBefore: c.before,
                    continuesAfter: c.after
                ))
            }
            assignments.removeAll()
            columnEnds.removeAll()
            clusterStart = endIndex
            clusterMaxEnd = -.infinity
        }

        for (index, item) in clipped.enumerated() {
            if item.start >= clusterMaxEnd, !assignments.isEmpty {
                flushCluster(upTo: index)
            }
            // Lowest column whose last block ended at-or-before this start
            // (half-open: equal boundary does NOT overlap).
            var column = columnEnds.firstIndex { $0 <= item.start } ?? columnEnds.count
            if column == columnEnds.count { columnEnds.append(item.end) } else { columnEnds[column] = item.end }
            assignments.append((index, column))
            clusterMaxEnd = max(clusterMaxEnd, item.end)
            _ = clusterStart
        }
        flushCluster(upTo: clipped.count)

        return placed
    }
}
