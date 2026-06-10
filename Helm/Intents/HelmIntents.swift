//
//  HelmIntents.swift
//  Helm
//
//  v6: Siri / Shortcuts — in-app App Intents (no extension target). They read
//  the SAME store (HelmApp.sharedModelContainer) and the SAME hours engine
//  (InsightsMath) as the dashboard, so Helm never gives two different answers.
//

import Foundation
import AppIntents
import SwiftData
import HelmDomain

nonisolated extension Notification.Name {
    static let helmOpenCalendar = Notification.Name("helmOpenCalendarTab")
}

struct NextShiftIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Shift"
    static let description = IntentDescription("Tells you when your next shift starts.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = HelmApp.sharedModelContainer.mainContext
        let instances = (try? context.fetch(FetchDescriptor<ShiftInstance>())) ?? []
        let now = Date.now
        let todayStart = Calendar.current.startOfDay(for: now)

        // Next timed shift (by start instant) vs next all-day TBC day — the
        // earlier one wins. Never speak a midnight "time" for a TBC day.
        let nextTimed = instances
            .filter { ($0.isAllDay ?? false) == false }
            .compactMap { instance in instance.startUTC.map { (instance, $0) } }
            .filter { $0.1 > now }
            .min { $0.1 < $1.1 }
        let nextAllDay = instances
            .filter { ($0.isAllDay ?? false) && ($0.localDate ?? .distantPast) >= todayStart }
            .min { ($0.localDate ?? .distantFuture) < ($1.localDate ?? .distantFuture) }

        func title(_ instance: ShiftInstance) -> String {
            instance.title ?? instance.shiftType?.label ?? instance.shiftType?.code ?? "a shift"
        }

        switch (nextTimed, nextAllDay) {
        case (nil, nil):
            return .result(dialog: "You have no upcoming shifts in Helm.")
        case let (timed?, allDay):
            if let allDay, let allDayDate = allDay.localDate,
               allDayDate < Calendar.current.startOfDay(for: timed.1) {
                return .result(dialog: allDayDialog(allDay, title: title(allDay)))
            }
            let when = timed.1.formatted(.dateTime.weekday(.wide).day().month().hour().minute())
            return .result(dialog: "Your next shift is \(title(timed.0)) on \(when).")
        case let (nil, allDay?):
            return .result(dialog: allDayDialog(allDay, title: title(allDay)))
        }
    }

    @MainActor
    private func allDayDialog(_ instance: ShiftInstance, title: String) -> IntentDialog {
        let day = (instance.localDate ?? .now).formatted(.dateTime.weekday(.wide).day().month())
        return IntentDialog("Your next shift is \(title) on \(day) — times to be confirmed.")
    }
}

enum HoursPeriod: String, AppEnum {
    case week, month

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Period"
    static let caseDisplayRepresentations: [HoursPeriod: DisplayRepresentation] = [
        .week: "this week",
        .month: "this month",
    ]
}

struct HoursIntent: AppIntent {
    static let title: LocalizedStringResource = "Shift Hours"
    static let description = IntentDescription("Totals your shift hours for the week or month.")

    @Parameter(title: "Period", default: .week)
    var period: HoursPeriod

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = HelmApp.sharedModelContainer.mainContext
        let instances = (try? context.fetch(FetchDescriptor<ShiftInstance>())) ?? []
        let shifts = InsightsSnapshot.shifts(from: instances)
        let calendar = CalendarViewModel.displayCalendar
        let today = DayKey(containing: .now, in: calendar)

        let range: ClosedRange<DayKey>
        let label: String
        switch period {
        case .week:
            let start = InsightsMath.weekStart(of: today, calendar: calendar)
            range = start...start.advanced(by: 6, in: calendar)
            label = "this week"
        case .month:
            range = InsightsMath.monthRange(MonthKey(of: today), calendar: calendar)
            label = "this month"
        }

        let summary = InsightsMath.periodSummary(shifts: shifts, in: range)
        let hours = summary.hours.formatted(.number.precision(.fractionLength(0...1)))
        var dialog = "You have \(hours) hours across \(summary.shiftCount) shift\(summary.shiftCount == 1 ? "" : "s") \(label)."
        if summary.tentativeCount > 0 {
            dialog += " \(summary.tentativeCount) day\(summary.tentativeCount == 1 ? " is" : "s are") still awaiting times."
        }
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

struct OpenCalendarIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Helm Calendar"
    static let description = IntentDescription("Opens Helm on the calendar.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .helmOpenCalendar, object: nil)
        return .result()
    }
}

struct HelmShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NextShiftIntent(),
            phrases: [
                "When's my next shift in \(.applicationName)?",
                "Next shift in \(.applicationName)",
            ],
            shortTitle: "Next Shift",
            systemImageName: "clock.badge.questionmark"
        )
        AppShortcut(
            intent: HoursIntent(),
            phrases: [
                "How many hours in \(.applicationName)?",
                "\(.applicationName) hours this week",
            ],
            shortTitle: "Shift Hours",
            systemImageName: "sum"
        )
        AppShortcut(
            intent: OpenCalendarIntent(),
            phrases: [
                "Show my \(.applicationName) calendar",
            ],
            shortTitle: "Calendar",
            systemImageName: "calendar"
        )
    }
}
