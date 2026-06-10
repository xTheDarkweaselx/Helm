//
//  CalendarViewModel.swift
//  Helm
//
//  State for the calendar: visible month, selected day, and the other-events
//  cache for the visible window (±1 month), reloaded on month changes and on
//  EKEventStoreChanged. Shifts are NOT here — they come live from @Query in
//  CalendarView and are bucketed per body pass (CloudKit-reactive for free).
//

import Foundation
import SwiftUI
import EventKit
import HelmDomain

@MainActor
@Observable
final class CalendarViewModel {
    var visibleMonth: MonthKey
    var selectedDay: DayKey
    private(set) var eventsByDay: [DayKey: [EventItem]] = [:]
    private(set) var accessState: EventAccessState = .notDetermined
    /// Toggleable calendar sources for the filter menu (v4).
    private(set) var availableCalendars: [CalendarChoice] = []
    var hiddenCalendarIDs: Set<String> = CalendarSourceFilter.hiddenIDs
    /// Bumped by EKEventStoreChanged so .task(id:) reloads the same month.
    private(set) var reloadToken = 0

    private let reader = OtherEventsReader()
    /// nonisolated(unsafe): written once in init (main), read only in the
    /// nonisolated deinit; NotificationCenter.removeObserver is thread-safe.
    private nonisolated(unsafe) var storeObserver: NSObjectProtocol?
    private nonisolated(unsafe) var filterObserver: NSObjectProtocol?

    /// The display calendar: GREGORIAN pinned (DayKey/ShiftKey civil days are
    /// Gregorian; a Japanese/Buddhist system calendar would mis-bucket every
    /// chip), carrying the user's locale, zone and week start.
    nonisolated static var displayCalendar: Calendar {
        let system = Calendar.current
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale.current
        cal.timeZone = system.timeZone
        cal.firstWeekday = system.firstWeekday
        return cal
    }

    init(initialDay: DayKey? = nil) {
        let cal = Self.displayCalendar
        let today = DayKey(containing: .now, in: cal)
        let day = initialDay ?? today
        self.selectedDay = day
        self.visibleMonth = MonthKey(of: day)
        self.storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reader.noteStoreChanged()
                self.reloadToken += 1
            }
        }
        // Filter toggles propagate to EVERY live instance (sidebar + sheet).
        self.filterObserver = NotificationCenter.default.addObserver(
            forName: CalendarSourceFilter.changed, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hiddenCalendarIDs = CalendarSourceFilter.hiddenIDs
                self.reloadToken += 1
            }
        }
    }

    deinit {
        if let storeObserver {
            NotificationCenter.default.removeObserver(storeObserver)
        }
        if let filterObserver {
            NotificationCenter.default.removeObserver(filterObserver)
        }
    }

    /// Show/hide a calendar source. Persisting posts the change notification,
    /// which updates this AND every other live instance uniformly.
    func setCalendar(id: String, hidden: Bool) {
        CalendarSourceFilter.setHidden(hidden, id: id)
    }

    func jumpToToday() {
        let today = DayKey(containing: .now, in: Self.displayCalendar)
        selectedDay = today
        withAnimation { visibleMonth = MonthKey(of: today) }
    }

    func step(months: Int) {
        withAnimation { visibleMonth = visibleMonth.advanced(by: months) }
    }

    /// Load other-events for visibleMonth ±1 (the grid shows edge days).
    func loadEvents() async {
        accessState = await reader.ensureAccess()
        guard case .fullAccess = accessState else {
            eventsByDay = [:]
            availableCalendars = []
            return
        }
        availableCalendars = reader.availableCalendars()
        let cal = Self.displayCalendar
        let from = visibleMonth.advanced(by: -1).start(in: cal)
        let to = visibleMonth.advanced(by: 2).start(in: cal)
        let window = DayKey(containing: from, in: cal)...DayKey(containing: to, in: cal)

        let events = reader.load(from: from, to: to)
        var byDay: [DayKey: [EventItem]] = [:]
        for event in events {
            for day in DayBucketer.dayKeys(start: event.start, end: event.end, in: cal, clampedTo: window) {
                byDay[day, default: []].append(event)
            }
        }
        for key in byDay.keys {
            byDay[key]?.sort {
                CalendarItemSort.SortKey(isAllDay: $0.isAllDay, start: $0.start, title: $0.title)
                    < CalendarItemSort.SortKey(isAllDay: $1.isAllDay, start: $1.start, title: $1.title)
            }
        }
        eventsByDay = byDay
    }
}
