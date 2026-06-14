//
//  PayEngine.swift
//  HelmDomain
//
//  v8 Pay & timesheets: a PURE earnings engine over the same `InsightShift`
//  values the Insights dashboard uses — so hours never disagree between the two.
//  Gross pay = paid hours × rate, with optional WEEKLY overtime (each locale
//  week's hours beyond a threshold are paid at a multiplier) and a configurable
//  tax-year boundary (UK 6 April by default). No SwiftData, no SwiftUI; fully
//  unit-tested. Currency FORMATTING is the UI's job — the engine returns Doubles.
//

import Foundation

/// User pay configuration, resolved from settings.
public struct PayRules: Sendable, Equatable {
    public let hourlyRate: Double
    public let overtimeEnabled: Bool
    /// Weekly paid hours beyond which overtime applies.
    public let overtimeThresholdHours: Double
    /// Multiplier on the base rate for overtime hours (e.g. 1.5 = time-and-a-half).
    public let overtimeMultiplier: Double
    /// Tax-year start (month, day). UK default is 6 April.
    public let taxYearStartMonth: Int
    public let taxYearStartDay: Int

    public init(hourlyRate: Double,
                overtimeEnabled: Bool = false,
                overtimeThresholdHours: Double = 40,
                overtimeMultiplier: Double = 1.5,
                taxYearStartMonth: Int = 4,
                taxYearStartDay: Int = 6) {
        self.hourlyRate = max(0, hourlyRate)
        self.overtimeEnabled = overtimeEnabled
        self.overtimeThresholdHours = max(0, overtimeThresholdHours)
        self.overtimeMultiplier = max(1, overtimeMultiplier)
        self.taxYearStartMonth = min(12, max(1, taxYearStartMonth))
        self.taxYearStartDay = min(28, max(1, taxYearStartDay)) // 28 keeps every month valid
    }

    public var isActive: Bool { hourlyRate > 0 }
}

/// One period's pay totals + hours breakdown.
public struct PaySummary: Sendable, Equatable {
    public let totalHours: Double
    public let baseHours: Double
    public let overtimeHours: Double
    public let basePay: Double
    public let overtimePay: Double
    public let shiftCount: Int
    /// Shifts counted but awaiting times (no hours, no pay yet).
    public let tentativeCount: Int

    public var grossPay: Double { basePay + overtimePay }

    public static let zero = PaySummary(totalHours: 0, baseHours: 0, overtimeHours: 0,
                                        basePay: 0, overtimePay: 0, shiftCount: 0, tentativeCount: 0)
}

/// A single shift's row in a timesheet (base pay = hours × rate; overtime is a
/// weekly concept surfaced at the summary level, not split per shift).
public struct PayLineItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let day: DayKey
    public let start: Date?
    public let end: Date?
    public let hours: Double
    public let typeLabel: String?
    public let pay: Double

    public init(id: String, day: DayKey, start: Date?, end: Date?, hours: Double, typeLabel: String?, pay: Double) {
        self.id = id
        self.day = day
        self.start = start
        self.end = end
        self.hours = hours
        self.typeLabel = typeLabel
        self.pay = pay
    }
}

public enum PayEngine {
    /// Gross pay + hours breakdown for a day range. Overtime is a WHOLE-WEEK
    /// concept: each locale week's FULL hours (across all shifts, in-range or not)
    /// are split into base/overtime at the threshold, then attributed to this
    /// period in proportion to the week's in-range hours. So a week straddling a
    /// month or tax-year boundary keeps its overtime premium — shared across the
    /// two periods rather than vanishing from both. Shifts on types the user marked
    /// unpaid (`isPaid == false`) earn nothing and don't appear on the report.
    public static func summary(shifts: [InsightShift], in range: ClosedRange<DayKey>, rules: PayRules, calendar: Calendar) -> PaySummary {
        var weekHoursAll: [DayKey: Double] = [:]      // whole week, for the OT threshold
        var weekHoursInRange: [DayKey: Double] = [:]  // this period's share of each week
        var totalHours = 0.0
        var shiftCount = 0
        var tentativeCount = 0
        for shift in shifts {
            guard shift.isPaid else { continue }      // explicitly-unpaid types never earn
            let week = InsightsMath.weekStart(of: shift.day, calendar: calendar)
            if let h = InsightsMath.hours(for: shift) {
                weekHoursAll[week, default: 0] += h
                if range.contains(shift.day) {
                    weekHoursInRange[week, default: 0] += h
                    totalHours += h
                    shiftCount += 1
                }
            } else if shift.isAllDay, range.contains(shift.day) {
                shiftCount += 1
                tentativeCount += 1
            }
        }

        var baseHours = 0.0
        var overtimeHours = 0.0
        if rules.overtimeEnabled, rules.overtimeThresholdHours > 0 {
            for (week, inRange) in weekHoursInRange {
                let full = weekHoursAll[week] ?? inRange
                guard full > 0 else { continue }
                let fraction = inRange / full         // this period's slice of the week
                baseHours += min(full, rules.overtimeThresholdHours) * fraction
                overtimeHours += max(0, full - rules.overtimeThresholdHours) * fraction
            }
        } else {
            baseHours = totalHours
        }

        return PaySummary(
            totalHours: totalHours,
            baseHours: baseHours,
            overtimeHours: overtimeHours,
            basePay: baseHours * rules.hourlyRate,
            overtimePay: overtimeHours * rules.hourlyRate * rules.overtimeMultiplier,
            shiftCount: shiftCount,
            tentativeCount: tentativeCount
        )
    }

    /// Per-shift earnings for a timesheet detail, chronological. Base pay only
    /// (hours × rate); the overtime premium lives in `summary().overtimePay`.
    public static func lineItems(shifts: [InsightShift], in range: ClosedRange<DayKey>, rules: PayRules, calendar: Calendar) -> [PayLineItem] {
        shifts
            .filter { range.contains($0.day) && $0.isPaid }
            .compactMap { shift -> (InsightShift, Double)? in
                guard let h = InsightsMath.hours(for: shift) else { return nil }
                return (shift, h)
            }
            .sorted { lhs, rhs in
                if lhs.0.day != rhs.0.day { return lhs.0.day < rhs.0.day }
                return (lhs.0.start ?? .distantPast) < (rhs.0.start ?? .distantPast)
            }
            .enumerated()
            .map { index, pair in
                let (shift, hours) = pair
                return PayLineItem(
                    id: "\(index)",
                    day: shift.day,
                    start: shift.start,
                    end: shift.end,
                    hours: hours,
                    typeLabel: shift.typeLabel,
                    pay: hours * rules.hourlyRate
                )
            }
    }

    /// The tax-year range containing `day`: [start … day-before-next-start].
    public static func taxYearRange(containing day: DayKey, rules: PayRules, calendar: Calendar) -> ClosedRange<DayKey> {
        let startThisYear = DayKey(year: day.year, month: rules.taxYearStartMonth, day: rules.taxYearStartDay)
        let start = (day < startThisYear)
            ? DayKey(year: day.year - 1, month: rules.taxYearStartMonth, day: rules.taxYearStartDay)
            : startThisYear
        let nextStart = DayKey(year: start.year + 1, month: rules.taxYearStartMonth, day: rules.taxYearStartDay)
        return start...nextStart.advanced(by: -1, in: calendar)
    }
}
