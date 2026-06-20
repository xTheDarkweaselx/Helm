//
//  Reconcile.swift
//  Helm
//
//  v9 Payslip Reconcile. Compares Helm's expected pay for a period against what
//  the user was actually paid, and lets them tick individual shifts Paid / Not
//  paid / Wrong to find where a discrepancy is. Expected figures come from the
//  same JobPay/PayEngine as the rest of pay, so they never disagree.
//

import SwiftUI
import SwiftData
import HelmDomain

/// Whether a shift was actually paid, per the user's reconciliation.
enum ShiftPaidStatus: String, CaseIterable, Identifiable {
    case unknown, paid, notPaid, wrong
    var id: String { rawValue }

    var label: String {
        switch self {
        case .unknown: "Not checked"
        case .paid: "Paid"
        case .notPaid: "Not paid"
        case .wrong: "Wrong amount"
        }
    }
    var icon: String {
        switch self {
        case .unknown: "circle.dotted"
        case .paid: "checkmark.circle.fill"
        case .notPaid: "xmark.circle.fill"
        case .wrong: "exclamationmark.triangle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .unknown: .secondary
        case .paid: .green
        case .notPaid: .red
        case .wrong: .orange
        }
    }
}

extension ShiftInstance {
    var paidStatus: ShiftPaidStatus {
        get { ShiftPaidStatus(rawValue: paidStatusRaw ?? "") ?? .unknown }
        set {
            paidStatusRaw = newValue == .unknown ? nil : newValue.rawValue
            if newValue != .wrong { actualPay = nil } // amount only meaningful for "wrong"
        }
    }
}

struct ReconcileResult {
    let expected: Double          // Helm's estimate for the period (scoped to employer)
    let actual: Double?           // user-entered payslip gross
    let flaggedShortfall: Double  // not-paid expected + wrong shortfalls (a diagnostic)
    let shiftCount: Int
    let checkedCount: Int         // shifts with a non-unknown status

    var delta: Double? { actual.map { $0 - expected } }
}

enum Reconcile {
    /// The shifts a payslip covers — in its period, scoped to its employer if set.
    static func shifts(for slip: Payslip, from instances: [ShiftInstance], calendar: Calendar) -> [ShiftInstance] {
        guard let s = slip.periodStart, let e = slip.periodEnd else { return [] }
        let lo = DayKey(containing: s, in: calendar)
        let hi = DayKey(containing: e, in: calendar)
        return instances.filter { inst in
            guard let d = inst.localDate else { return false }
            let k = DayKey(containing: d, in: calendar)
            guard k >= lo, k <= hi else { return false }
            if let rid = slip.rosterID { return inst.roster?.id == rid }
            return true
        }
        .sorted { ($0.localDate ?? .distantPast) < ($1.localDate ?? .distantPast) }
    }

    /// One shift's expected pay (base + premium under its job's rules). Overtime is
    /// a weekly add-on surfaced at the period level, not attributed per shift.
    static func expectedPay(for instance: ShiftInstance, calendar: Calendar) -> Double {
        let rules = JobPay.rules(for: instance.roster, global: PaySettings.rules)
        guard rules.hourlyRate > 0,
              let shift = InsightsSnapshot.shifts(from: [instance]).first,
              shift.isPaid, let h = InsightsMath.hours(for: shift) else { return 0 }
        return h * rules.hourlyRate + PayEngine.premiumPay(for: shift, rate: rules.hourlyRate, rules: rules, calendar: calendar)
    }

    static func result(for slip: Payslip, allInstances: [ShiftInstance], calendar: Calendar) -> ReconcileResult {
        let periodShifts = shifts(for: slip, from: allInstances, calendar: calendar)
        guard let s = slip.periodStart, let e = slip.periodEnd else {
            return ReconcileResult(expected: 0, actual: slip.actualGross, flaggedShortfall: 0, shiftCount: 0, checkedCount: 0)
        }
        let range = DayKey(containing: s, in: calendar)...DayKey(containing: e, in: calendar)
        let expected = JobPay.breakdown(instances: periodShifts, in: range, global: PaySettings.rules, calendar: calendar).combined.grossPay

        var shortfall = 0.0
        var checked = 0
        for inst in periodShifts {
            switch inst.paidStatus {
            case .notPaid: shortfall += expectedPay(for: inst, calendar: calendar); checked += 1
            case .wrong: shortfall += max(0, expectedPay(for: inst, calendar: calendar) - (inst.actualPay ?? 0)); checked += 1
            case .paid: checked += 1
            case .unknown: break
            }
        }
        return ReconcileResult(expected: expected, actual: slip.actualGross,
                               flaggedShortfall: shortfall, shiftCount: periodShifts.count, checkedCount: checked)
    }
}
