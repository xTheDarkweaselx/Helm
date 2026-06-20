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

/// Cold-launch route holder: OpenCalendarIntent can fire BEFORE ContentView
/// subscribes to the notification — it sets this too, and ContentView drains
/// it on appear, so "Show my Helm calendar" works from a cold start.
@MainActor
enum PendingRoute {
    static var openCalendar = false
}

struct NextShiftIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Shift"
    static let description = IntentDescription("Tells you when your next shift starts.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = HelmApp.sharedModelContainer.mainContext
        let instances = (try? context.fetch(FetchDescriptor<ShiftInstance>())) ?? []
        // ONE selector shared with the Overview hero (NextShiftSelector) —
        // Siri and the dashboard can never disagree about what "next" means.
        guard let next = NextShiftSelector.next(in: instances) else {
            return .result(dialog: "You have no upcoming shifts in Helm.")
        }
        let title = next.title ?? next.shiftType?.label ?? next.shiftType?.code ?? "a shift"
        if next.isAllDay == true {
            return .result(dialog: allDayDialog(next, title: title))
        }
        let when = (next.startUTC ?? .now).formatted(.dateTime.weekday(.wide).day().month().hour().minute())
        return .result(dialog: "Your next shift is \(title) on \(when).")
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
        // Pluralize against the SPOKEN string, so "1 hour" but "1.5 hours".
        let hourUnit = hours == "1" ? "hour" : "hours"
        var dialog = "You have \(hours) \(hourUnit) across \(summary.shiftCount) shift\(summary.shiftCount == 1 ? "" : "s") \(label)."
        if summary.tentativeCount > 0 {
            dialog += " \(summary.tentativeCount) day\(summary.tentativeCount == 1 ? " is" : "s are") still awaiting times."
        }
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

struct WorkingOnDateIntent: AppIntent {
    static let title: LocalizedStringResource = "Working On A Day"
    static let description = IntentDescription("Tells you whether you're working on a given day, and which shift.")

    @Parameter(title: "Date", requestValueDialog: "Which day shall I check?")
    var date: Date

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let context = HelmApp.sharedModelContainer.mainContext
        let instances = (try? context.fetch(FetchDescriptor<ShiftInstance>())) ?? []
        let calendar = CalendarViewModel.displayCalendar
        let day = DayKey(containing: date, in: calendar)
        let dayLabel = date.formatted(.dateTime.weekday(.wide).day().month())

        // Use the SAME civil-day bucketing as the dashboard (InsightsSnapshot buckets
        // each shift in its own time zone), so Siri and the calendar always agree.
        let onDay = InsightsSnapshot.shifts(from: instances)
            .filter { $0.day == day }
            .sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }

        guard !onDay.isEmpty else {
            return .result(dialog: "You're not working on \(dayLabel).")
        }
        let phrases = onDay.map(shiftPhrase)
        let list = phrases.count == 1 ? phrases[0]
            : phrases.dropLast().joined(separator: ", ") + " and " + (phrases.last ?? "")
        return .result(dialog: IntentDialog(stringLiteral: "Yes — you're working \(dayLabel): \(list)."))
    }

    private func shiftPhrase(_ shift: InsightShift) -> String {
        let label = shift.typeLabel ?? "a shift"
        guard !shift.isAllDay, let start = shift.start, let end = shift.end else {
            return "\(label) (times to be confirmed)"
        }
        let from = start.formatted(.dateTime.hour().minute())
        let to = end.formatted(.dateTime.hour().minute())
        return "\(label) from \(from) to \(to)"
    }
}

struct OpenCalendarIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Helm Calendar"
    static let description = IntentDescription("Opens Helm on the calendar.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingRoute.openCalendar = true
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
            intent: WorkingOnDateIntent(),
            phrases: [
                "Am I working in \(.applicationName)?",
                "Do I work a shift in \(.applicationName)?",
                "Check if I'm working in \(.applicationName)",
            ],
            shortTitle: "Working on a day",
            systemImageName: "calendar.badge.checkmark"
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
