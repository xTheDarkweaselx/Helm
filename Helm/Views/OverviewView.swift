//
//  OverviewView.swift
//  Helm
//
//  v6: Overview grows into an insights dashboard — next-shift hero, weekly
//  hours chart, shift-type mix, month comparison, streak — all computed by
//  the ONE hours engine (HelmDomain.InsightsMath) that also answers Siri.
//  Still doubles as first-launch onboarding when nothing exists yet.
//

import SwiftUI
import SwiftData
import Charts
import HelmDomain

/// THE next-shift rule, shared by the Overview hero and Siri's NextShiftIntent
/// so the screen and the spoken answer can never disagree. Tie-break: an
/// all-day (TBC) day wins only when its civil day is STRICTLY earlier than
/// the next timed shift's civil day.
enum NextShiftSelector {
    static func next(in instances: [ShiftInstance]) -> ShiftInstance? {
        let now = Date.now
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let nextTimed = instances
            .filter { ($0.isAllDay ?? false) == false }
            .compactMap { instance in instance.startUTC.map { (instance, $0) } }
            .filter { $0.1 > now }
            .min { $0.1 < $1.1 }
        let nextAllDay = instances
            .filter { ($0.isAllDay ?? false) && ($0.localDate ?? .distantPast) >= todayStart }
            .min { ($0.localDate ?? .distantFuture) < ($1.localDate ?? .distantFuture) }
        switch (nextTimed, nextAllDay) {
        case (nil, nil): return nil
        case let (timed?, nil): return timed.0
        case let (nil, allDay?): return allDay
        case let (timed?, allDay?):
            let allDayDay = allDay.localDate.map { calendar.startOfDay(for: $0) } ?? .distantFuture
            return allDayDay < calendar.startOfDay(for: timed.1) ? allDay : timed.0
        }
    }
}

/// MainActor snapshot: SwiftData models → pure InsightShift values.
/// Shared by this dashboard and the App Intents (same numbers, everywhere).
@MainActor
enum InsightsSnapshot {
    static func shifts(from instances: [ShiftInstance]) -> [InsightShift] {
        var zoneCals: [String: Calendar] = [:]
        return instances.compactMap { instance in
            guard let localDate = instance.localDate else { return nil }
            let zoneID = instance.timeZoneIdentifier
            let cal = zoneCals[zoneID] ?? {
                var c = Calendar(identifier: .gregorian)
                c.timeZone = TimeZone(identifier: zoneID) ?? .current
                zoneCals[zoneID] = c
                return c
            }()
            return InsightShift(
                day: DayKey(containing: localDate, in: cal),
                start: instance.startUTC,
                end: instance.endUTC,
                paidHours: instance.computedPaidHours,
                typeKey: instance.shiftType?.id ?? instance.shiftType?.code,
                typeLabel: instance.shiftType?.label ?? instance.shiftType?.code ?? "Other",
                colorHex: instance.shiftType?.colorHex,
                isAllDay: instance.isAllDay ?? false
            )
        }
    }
}

struct OverviewView: View {
    @Query(sort: \Roster.createdAt, order: .reverse) private var rosters: [Roster]
    @Query(sort: \Schedule.createdAt, order: .reverse) private var schedules: [Schedule]
    @Query private var instances: [ShiftInstance]
    @Query private var timeOffs: [TimeOff]
    @AppStorage("hourlyRate") private var hourlyRate: Double = 0
    @Environment(\.helmAccent) private var accent

    /// Open the import flow / create a schedule (owned by ContentView).
    let importRoster: () -> Void
    let newSchedule: () -> Void

    private var calendar: Calendar { CalendarViewModel.displayCalendar }
    private var today: DayKey { DayKey(containing: .now, in: calendar) }

    var body: some View {
        Group {
            if rosters.isEmpty && schedules.isEmpty {
                onboarding
            } else {
                dashboard
            }
        }
        .navigationTitle("Overview")
    }

    // MARK: - First launch

    private var onboarding: some View {
        ContentUnavailableView {
            Label("Welcome to Helm", systemImage: "calendar.badge.plus")
        } description: {
            Text("Import a spreadsheet roster, or build a custom rota, and Helm keeps your calendar in step with it.")
        } actions: {
            Button("Import roster", systemImage: "square.and.arrow.down", action: importRoster)
                .buttonStyle(.borderedProminent)
            Button("New schedule", systemImage: "slider.horizontal.3", action: newSchedule)
        }
    }

    // MARK: - Dashboard

    private var dashboard: some View {
        let shifts = InsightsSnapshot.shifts(from: instances)
        let weekRange = currentWeekRange
        let weekSummary = InsightsMath.periodSummary(shifts: shifts, in: weekRange)
        let weekly = InsightsMath.weeklyHours(shifts: shifts, weeks: 8, endingAt: today, calendar: calendar)
        let months = InsightsMath.monthComparison(shifts: shifts, month: MonthKey(of: today), calendar: calendar)
        let mix = InsightsMath.typeMix(shifts: shifts, in: today.advanced(by: -56, in: calendar)...today.advanced(by: 56, in: calendar))
        let streak = InsightsMath.currentStreak(endingAt: today, workedDays: Set(shifts.map(\.day)), calendar: calendar)

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                nextShiftHero
                statRow(weekSummary: weekSummary, months: months, streak: streak)
                weeklyHoursCard(weekly)
                if mix.count > 1 { typeMixCard(mix) }
                if hourlyRate > 0 { payCard(monthHours: months.current) }
                leaveCard
                quickActions
            }
            .padding(16)
        }
    }

    private var currentWeekRange: ClosedRange<DayKey> {
        let start = InsightsMath.weekStart(of: today, calendar: calendar)
        return start...start.advanced(by: 6, in: calendar)
    }

    // MARK: Hero

    @ViewBuilder
    private var nextShiftHero: some View {
        if let next = NextShiftSelector.next(in: instances) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Next shift").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(next.title ?? next.shiftType?.label ?? next.shiftType?.code ?? "Shift")
                    .font(.title2.weight(.bold))
                if next.isAllDay == true, let day = next.localDate {
                    Text(day, format: .dateTime.weekday(.wide).day().month())
                        .foregroundStyle(.secondary)
                    Label("All-day — times to be confirmed", systemImage: "clock.badge.questionmark")
                        .font(.caption).foregroundStyle(.orange)
                } else if let start = next.startUTC {
                    Text(start, format: .dateTime.weekday(.wide).day().month().hour().minute())
                        .foregroundStyle(.secondary)
                    Text(start, format: .relative(presentation: .named))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let location = next.locationName, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .glassCard(cornerRadius: 14)
        }
    }

    // MARK: Stat chips

    private func statRow(weekSummary: InsightsMath.PeriodSummary, months: (current: Double, previous: Double), streak: Int) -> some View {
        HStack(spacing: 10) {
            statCard(
                title: "This week",
                value: hoursText(weekSummary.hours),
                caption: weekSummary.tentativeCount > 0 ? "+\(weekSummary.tentativeCount) day\(weekSummary.tentativeCount == 1 ? "" : "s") TBC" : "\(weekSummary.shiftCount) shift\(weekSummary.shiftCount == 1 ? "" : "s")"
            )
            statCard(
                title: "This month",
                value: hoursText(months.current),
                caption: monthDelta(months)
            )
            statCard(
                title: "Streak",
                value: streak == 0 ? "—" : "\(streak)d",
                caption: streak == 0 ? "off today" : "working days"
            )
        }
    }

    private func monthDelta(_ months: (current: Double, previous: Double)) -> String {
        let delta = months.current - months.previous
        if abs(delta) < 0.05 { return "same as last month" }
        return delta > 0 ? "▲ \(hoursText(delta)) vs last" : "▼ \(hoursText(-delta)) vs last"
    }

    private func statCard(title: String, value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.bold)).monospacedDigit()
            Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .glassCard(cornerRadius: 12)
    }

    // MARK: Weekly hours chart

    private func weeklyHoursCard(_ weekly: [InsightsMath.WeekBucket]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hours per week").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Chart(weekly, id: \.weekStart) { bucket in
                BarMark(
                    x: .value("Week", bucket.weekStart.startOfDay(in: calendar), unit: .weekOfYear),
                    y: .value("Hours", bucket.hours)
                )
                .foregroundStyle(bucket.weekStart == InsightsMath.weekStart(of: today, calendar: calendar) ? accent : accent.opacity(0.45))
                .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear)) { _ in
                    AxisValueLabel(format: .dateTime.day().month(), centered: true)
                        .font(.caption2)
                }
            }
            .frame(height: 130)
            .accessibilityLabel(weeklyAXSummary(weekly))
        }
        .padding(14)
        .glassCard(cornerRadius: 14)
    }

    private func weeklyAXSummary(_ weekly: [InsightsMath.WeekBucket]) -> String {
        let parts = weekly.suffix(4).map { bucket in
            "week of \(bucket.weekStart.startOfDay(in: calendar).formatted(.dateTime.day().month())): \(hoursText(bucket.hours))"
        }
        return "Hours per week. " + parts.joined(separator: ", ")
    }

    // MARK: Type mix

    private func typeMixCard(_ mix: [InsightsMath.TypeSlice]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shift mix (±8 weeks)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(mix.prefix(5), id: \.key) { slice in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: slice.colorHex) ?? accent)
                        .frame(width: 10, height: 10)
                    Text(slice.label).font(.caption)
                    Spacer()
                    Text("\(hoursText(slice.hours)) · \(slice.count)×")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .glassCard(cornerRadius: 14)
    }

    // MARK: Pay

    private func payCard(monthHours: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Estimated pay this month").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text((monthHours * hourlyRate), format: .currency(code: Locale.current.currency?.identifier ?? "GBP"))
                .font(.title3.weight(.bold)).monospacedDigit()
            Text("\(hoursText(monthHours)) × \(hourlyRate, format: .currency(code: Locale.current.currency?.identifier ?? "GBP"))/h — flat rate, before tax")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(cornerRadius: 14)
    }

    // MARK: Leave

    @ViewBuilder
    private var leaveCard: some View {
        let summary = leaveSummary()
        if summary.totalDays > 0 {
            VStack(alignment: .leading, spacing: 6) {
                Text("Leave this year").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    leaveStat("\(summary.totalDays)d", "booked")
                    leaveStat("\(summary.paidDays)d", "paid")
                    if summary.hours > 0 {
                        leaveStat(summary.hours.formatted(.number.precision(.fractionLength(0...1))) + "h", "credited")
                    }
                }
                if let top = summary.byKind.first {
                    Text("Mostly \(top.kind.displayName.lowercased()) (\(top.days)d)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .glassCard(cornerRadius: 14)
        }
    }

    private func leaveStat(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.title3.weight(.bold)).monospacedDigit()
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func leaveSummary() -> LeaveAccumulator.LeaveSummary {
        let year = calendar.component(.year, from: .now)
        let range = DayKey(year: year, month: 1, day: 1)...DayKey(year: year, month: 12, day: 31)
        let entries: [LeaveEntry] = timeOffs.compactMap { to in
            guard let s = to.startDate, let e = to.endDate else { return nil }
            return LeaveEntry(id: to.id,
                              start: DayKey(containing: s, in: calendar),
                              end: DayKey(containing: e, in: calendar),
                              kind: to.kind, paid: to.paid, hoursPerDay: to.hoursPerDay)
        }
        return LeaveAccumulator.summary(entries, in: range, calendar: calendar)
    }

    private var quickActions: some View {
        HStack {
            Button("Import roster…", systemImage: "square.and.arrow.down", action: importRoster)
            Button("New schedule", systemImage: "slider.horizontal.3", action: newSchedule)
        }
        .buttonStyle(.bordered)
    }

    private func hoursText(_ hours: Double) -> String {
        "\(hours.formatted(.number.precision(.fractionLength(0...1)))) h"
    }
}
