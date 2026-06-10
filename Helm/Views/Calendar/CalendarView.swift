//
//  CalendarView.swift
//  Helm
//
//  The v3 calendar: a native month grid + day agenda merging Helm's shifts
//  (first-class, shift-type colored) with the user's other events from any
//  system calendar account (iCloud/Google/…). One view, two modes: .live in
//  the sidebar, .preview(overlay) inside import/schedule sheets — the overlay
//  renders the pending diff (added/updated/removed) against real life.
//

import SwiftUI
import SwiftData
import HelmDomain

struct CalendarView: View {
    let mode: CalendarMode

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ShiftInstance.localDate) private var instances: [ShiftInstance]
    @State private var model: CalendarViewModel
    @State private var shiftToRemove: ShiftItem?
    @State private var removalError: String?

    /// Pager pages: fixed window around the month at first appearance (stable ids).
    private let pagedMonths: [MonthKey]

    init(mode: CalendarMode) {
        self.mode = mode
        let initialDay = mode.overlay?.firstChangedDay
        let model = CalendarViewModel(initialDay: initialDay)
        _model = State(initialValue: model)
        let base = model.visibleMonth
        self.pagedMonths = (-120...120).map { base.advanced(by: $0) }
    }

    private var isLive: Bool {
        if case .live = mode { return true }
        return false
    }

    /// Side-by-side needs real room: grid ≥ ~360 + agenda 300. Below this the
    /// stacked layout is used EVEN on macOS — sheets there open ~500pt wide,
    /// and platform-based branching crushed the grid into ~170pt.
    private static let sideBySideMinWidth: CGFloat = 680

    var body: some View {
        // ONE bucketing pass per body evaluation, shared by all 42 cells and
        // the agenda (a per-cell computed property would re-walk every
        // ShiftInstance 42× per render).
        let shiftBuckets = computeShiftsByDay()
        let dayDetail = DayDetailView(
            day: model.selectedDay,
            items: items(for: model.selectedDay, shiftBuckets: shiftBuckets),
            conflicts: conflictTitles(for: model.selectedDay, shiftBuckets: shiftBuckets),
            onRemoveShift: isLive ? { shiftToRemove = $0 } : nil
        )
        GeometryReader { geo in
            // Layout by ACTUAL width, never by platform.
            let isWide = geo.size.width >= Self.sideBySideMinWidth
            if isWide {
                HStack(spacing: 0) {
                    monthPane(shiftBuckets: shiftBuckets, isWide: true)
                    Divider()
                    dayDetail.frame(width: 300)
                }
            } else {
                VStack(spacing: 0) {
                    monthPane(shiftBuckets: shiftBuckets, isWide: false)
                    Divider()
                    dayDetail.frame(minHeight: 160, maxHeight: 280)
                }
            }
        }
        .task(id: LoadKey(month: model.visibleMonth, token: model.reloadToken)) {
            await model.loadEvents()
        }
        .confirmationDialog(
            "Remove this shift from your calendar and from Helm?",
            isPresented: Binding(get: { shiftToRemove != nil }, set: { if !$0 { shiftToRemove = nil } }),
            titleVisibility: .visible,
            presenting: shiftToRemove
        ) { shift in
            Button("Remove shift", role: .destructive) { remove(shift) }
            Button("Cancel", role: .cancel) {}
        } message: { shift in
            Text("“\(shift.title)” will be deleted from the calendar and from its roster. Re-importing the file or re-applying its schedule would add it back.")
        }
        .alert("Couldn't remove shift", isPresented: .constant(removalError != nil)) {
            Button("OK") { removalError = nil }
        } message: {
            Text(removalError ?? "")
        }
    }

    private func remove(_ shift: ShiftItem) {
        let context = modelContext
        Task {
            do {
                let id = shift.id
                let descriptor = FetchDescriptor<ShiftInstance>(predicate: #Predicate { $0.id == id })
                guard let instance = try context.fetch(descriptor).first else { return }
                let destination = instance.roster.map { RosterSyncEngine.destination(for: $0, in: context) } ?? .eventkit
                let target = try await CalendarTargetProvider.authorizedTarget(for: destination)
                try await RosterSyncEngine.removeInstance(instance, target: target, in: context)
            } catch {
                removalError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private struct LoadKey: Equatable {
        let month: MonthKey
        let token: Int
    }

    // MARK: - Month pane

    private func monthPane(shiftBuckets: [DayKey: [ShiftItem]], isWide: Bool) -> some View {
        VStack(spacing: 8) {
            // No hours caption in preview mode: suppressed/incoming shifts make
            // the figure misleading there, and that header is about the diff.
            header(monthHours: mode.overlay == nil ? monthHours(shiftBuckets: shiftBuckets) : 0)
            if mode.overlay != nil { legend }
            weekdayHeader
            // Size cells AND pages from the actual pane geometry: page width
            // must equal the scroll viewport exactly (containerRelativeFrame
            // resolved against the SHEET in modal presentations, overlapping
            // adjacent month pages into doubled numerals).
            GeometryReader { geo in
                pager(
                    pageWidth: geo.size.width,
                    cellHeight: max(40, min(isWide ? 96 : 64, (geo.size.height / 6).rounded(.down))),
                    isWide: isWide,
                    shiftBuckets: shiftBuckets
                )
            }
            .frame(minHeight: 6 * 40)
            if case .unavailable = model.accessState {
                Label("Calendar access is off — only your shifts are shown.", systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private func header(monthHours: Double) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.visibleMonth.start(in: CalendarViewModel.displayCalendar),
                     format: .dateTime.month(.wide).year())
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                    .accessibilityAddTraits(.isHeader)
                if monthHours > 0 {
                    Text("\(monthHours.formatted(.number.precision(.fractionLength(0...1)))) h of shifts this month")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            calendarFilterMenu
            Button {
                model.step(months: -1)
            } label: {
                Label("Previous month", systemImage: "chevron.left").labelStyle(.iconOnly)
            }
            // Shortcuts only on the LIVE instance: the sidebar calendar and a
            // preview sheet can be alive simultaneously — duplicate shortcuts
            // resolve unpredictably.
            .keyboardShortcut(isLive ? KeyboardShortcut(.leftArrow, modifiers: .command) : nil)
            Button("Today") { model.jumpToToday() }
                .keyboardShortcut(isLive ? KeyboardShortcut("t", modifiers: .command) : nil)
            Button {
                model.step(months: 1)
            } label: {
                Label("Next month", systemImage: "chevron.right").labelStyle(.iconOnly)
            }
            .keyboardShortcut(isLive ? KeyboardShortcut(.rightArrow, modifiers: .command) : nil)
        }
        .buttonStyle(.borderless)
    }

    /// v4: choose which system calendars' events appear (Apple/iCloud, Google
    /// accounts added to the system, …) — grouped by account, Apple-style.
    @ViewBuilder
    private var calendarFilterMenu: some View {
        if !model.availableCalendars.isEmpty {
            Menu {
                let grouped = Dictionary(grouping: model.availableCalendars, by: \.sourceTitle)
                ForEach(grouped.keys.sorted(), id: \.self) { source in
                    Section(source) {
                        ForEach(grouped[source] ?? []) { choice in
                            Toggle(isOn: Binding(
                                get: { !model.hiddenCalendarIDs.contains(choice.id) },
                                set: { model.setCalendar(id: choice.id, hidden: !$0) }
                            )) {
                                Text(choice.title)
                            }
                        }
                    }
                }
            } label: {
                Label("Calendars",
                      systemImage: model.hiddenCalendarIDs.isEmpty
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                    .labelStyle(.iconOnly)
            }
            .menuIndicator(.hidden)
        }
    }

    private func monthHours(shiftBuckets: [DayKey: [ShiftItem]]) -> Double {
        let month = model.visibleMonth
        var total: Double = 0
        for (day, shifts) in shiftBuckets where day.year == month.year && day.month == month.month {
            for shift in shifts {
                if let paid = shift.paidHours {
                    total += paid
                } else if let start = shift.start, let end = shift.end, end > start {
                    total += end.timeIntervalSince(start) / 3600
                }
            }
        }
        return total
    }

    /// Timed events from EVERY display day a span touches — an overnight
    /// shift's post-midnight tail must see the NEXT day's events too (shifts
    /// bucket to their start day; events bucket to every day they span).
    private func timedEvents(spanning start: Date, _ end: Date) -> [EventItem] {
        let cal = CalendarViewModel.displayCalendar
        var seen = Set<String>()
        var out: [EventItem] = []
        for day in DayBucketer.dayKeys(start: start, end: end, in: cal) {
            for event in model.eventsByDay[day] ?? [] where !event.isAllDay && seen.insert(event.id).inserted {
                out.append(event)
            }
        }
        return out
    }

    /// Day-level conflict: any shift (or pending non-removed preview) bucketed
    /// on this day whose FULL interval intersects a timed event (next-day tail
    /// included). Half-open — back-to-back is fine.
    private func dayHasConflict(_ day: DayKey, shiftBuckets: [DayKey: [ShiftItem]]) -> Bool {
        for shift in shiftBuckets[day] ?? [] {
            guard let s = shift.start, let e = shift.end else { continue }
            if timedEvents(spanning: s, e).contains(where: { IntervalOverlap.intersects(s, e, $0.start, $0.end) }) {
                return true
            }
        }
        for preview in mode.overlay?.itemsByDay[day] ?? [] where preview.status != .removed {
            guard let s = preview.start, let e = preview.end else { continue }
            if timedEvents(spanning: s, e).contains(where: { IntervalOverlap.intersects(s, e, $0.start, $0.end) }) {
                return true
            }
        }
        return false
    }

    /// For the agenda: item id → titles of the events it overlaps.
    private func conflictTitles(for day: DayKey, shiftBuckets: [DayKey: [ShiftItem]]) -> [String: [String]] {
        var map: [String: [String]] = [:]
        for shift in shiftBuckets[day] ?? [] {
            guard let s = shift.start, let e = shift.end else { continue }
            let overlapping = timedEvents(spanning: s, e)
                .filter { IntervalOverlap.intersects(s, e, $0.start, $0.end) }.map(\.title)
            if !overlapping.isEmpty { map["s:\(shift.id)"] = overlapping }
        }
        for preview in mode.overlay?.itemsByDay[day] ?? [] where preview.status != .removed {
            guard let s = preview.start, let e = preview.end else { continue }
            let overlapping = timedEvents(spanning: s, e)
                .filter { IntervalOverlap.intersects(s, e, $0.start, $0.end) }.map(\.title)
            if !overlapping.isEmpty { map["p:\(preview.id)"] = overlapping }
        }
        return map
    }

    private var legend: some View {
        HStack(spacing: 12) {
            LegendTag(symbol: "plus", text: "Added", color: .green)
            LegendTag(symbol: "pencil", text: "Changed", color: .orange)
            LegendTag(symbol: "minus", text: "Removed", color: .red)
            Spacer()
        }
        .font(.caption)
    }

    private var weekdayHeader: some View {
        let symbols = CalendarGridMath.orderedWeekdaySymbols(CalendarViewModel.displayCalendar)
        return HStack(spacing: 0) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private func pager(pageWidth: CGFloat, cellHeight: CGFloat, isWide: Bool, shiftBuckets: [DayKey: [ShiftItem]]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(pagedMonths, id: \.self) { month in
                    MonthGridView(
                        grid: MonthGrid.make(month: month, calendar: CalendarViewModel.displayCalendar),
                        selectedDay: $model.selectedDay,
                        today: DayKey(containing: .now, in: CalendarViewModel.displayCalendar),
                        compact: !isWide,
                        cellHeight: cellHeight,
                        dayContent: { cellSummary(for: $0, shiftBuckets: shiftBuckets) }
                    )
                    .frame(width: max(pageWidth, 1)) // exact viewport width: no page bleed
                    .id(month)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: pagerBinding)
        .scrollIndicators(.hidden)
        #if os(macOS)
        .focusable()
        .onMoveCommand { direction in
            let cal = CalendarViewModel.displayCalendar
            let step: Int
            switch direction {
            case .left: step = -1
            case .right: step = 1
            case .up: step = -7
            case .down: step = 7
            default: step = 0
            }
            guard step != 0 else { return }
            model.selectedDay = model.selectedDay.advanced(by: step, in: cal)
            let month = MonthKey(of: model.selectedDay)
            if month != model.visibleMonth {
                withAnimation { model.visibleMonth = month }
            }
        }
        #endif
    }

    private var pagerBinding: Binding<MonthKey?> {
        Binding(
            get: { model.visibleMonth },
            set: { if let month = $0 { model.visibleMonth = month } }
        )
    }

    // MARK: - Merging

    /// Live shifts bucketed by their own-timezone civil day, with preview
    /// suppression applied (updated/removed keys render via the overlay).
    /// Called exactly once per body pass.
    private func computeShiftsByDay() -> [DayKey: [ShiftItem]] {
        let suppressed = mode.overlay?.suppressedShiftKeys ?? []
        var calendarByZone: [String: Calendar] = [:]
        var byDay: [DayKey: [ShiftItem]] = [:]
        for instance in instances {
            if let key = instance.dedupKey, suppressed.contains(key) { continue }
            guard let localDate = instance.localDate else { continue }
            let zoneID = instance.timeZoneIdentifier
            let cal = calendarByZone[zoneID] ?? {
                var c = Calendar(identifier: .gregorian)
                c.timeZone = TimeZone(identifier: zoneID) ?? .current
                calendarByZone[zoneID] = c
                return c
            }()
            let (day, endsLater) = DayBucketer.shiftDay(
                localDate: localDate, start: instance.startUTC, end: instance.endUTC, calendar: cal
            )
            byDay[day, default: []].append(ShiftItem(
                id: instance.id,
                dedupKey: instance.dedupKey,
                title: instance.title ?? instance.shiftType?.label ?? instance.shiftType?.code ?? "Shift",
                start: instance.startUTC,
                end: instance.endUTC,
                colorHex: instance.shiftType?.colorHex,
                location: instance.locationName,
                endsOnLaterDay: endsLater,
                paidHours: instance.computedPaidHours
            ))
        }
        return byDay
    }

    private func items(for day: DayKey, shiftBuckets: [DayKey: [ShiftItem]]) -> [CalendarDayItem] {
        var items: [CalendarDayItem] = []
        items.append(contentsOf: (shiftBuckets[day] ?? []).map(CalendarDayItem.shift))
        items.append(contentsOf: (model.eventsByDay[day] ?? []).map(CalendarDayItem.event))
        items.append(contentsOf: (mode.overlay?.itemsByDay[day] ?? []).map(CalendarDayItem.preview))
        return items.sorted { $0.sortKey < $1.sortKey }
    }

    private func cellSummary(for day: DayKey, shiftBuckets: [DayKey: [ShiftItem]]) -> DayCellSummary {
        DayCellSummary(
            shifts: shiftBuckets[day] ?? [],
            previews: mode.overlay?.itemsByDay[day] ?? [],
            eventCount: model.eventsByDay[day]?.count ?? 0,
            eventColors: (model.eventsByDay[day] ?? []).prefix(4).map(\.color),
            hasConflict: dayHasConflict(day, shiftBuckets: shiftBuckets)
        )
    }
}

private struct LegendTag: View {
    let symbol: String
    let text: String
    let color: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .fixedSize() // never stretch into giant pills in tight layouts
    }
}
