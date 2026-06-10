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
    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

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

    private var isRegularWidth: Bool {
        #if os(macOS)
        true
        #else
        horizontalSizeClass == .regular
        #endif
    }

    private var isLive: Bool {
        if case .live = mode { return true }
        return false
    }

    var body: some View {
        // ONE bucketing pass per body evaluation, shared by all 42 cells and
        // the agenda (a per-cell computed property would re-walk every
        // ShiftInstance 42× per render).
        let shiftBuckets = computeShiftsByDay()
        Group {
            if isRegularWidth {
                HStack(spacing: 0) {
                    monthPane(shiftBuckets: shiftBuckets)
                    Divider()
                    DayDetailView(day: model.selectedDay, items: items(for: model.selectedDay, shiftBuckets: shiftBuckets))
                        .frame(width: 320)
                }
            } else {
                VStack(spacing: 0) {
                    monthPane(shiftBuckets: shiftBuckets)
                    Divider()
                    DayDetailView(day: model.selectedDay, items: items(for: model.selectedDay, shiftBuckets: shiftBuckets))
                        .frame(minHeight: 160, maxHeight: 280)
                }
            }
        }
        .task(id: LoadKey(month: model.visibleMonth, token: model.reloadToken)) {
            await model.loadEvents()
        }
    }

    private struct LoadKey: Equatable {
        let month: MonthKey
        let token: Int
    }

    // MARK: - Month pane

    private func monthPane(shiftBuckets: [DayKey: [ShiftItem]]) -> some View {
        VStack(spacing: 8) {
            header
            if mode.overlay != nil { legend }
            weekdayHeader
            // Adapt cell height to the actual space (small windows/sheets must
            // not clip the fixed 6-row grid).
            GeometryReader { geo in
                pager(
                    cellHeight: max(44, min(isRegularWidth ? 96 : 64, (geo.size.height / 6).rounded(.down))),
                    shiftBuckets: shiftBuckets
                )
            }
            .frame(minHeight: 6 * 44)
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

    private var header: some View {
        HStack {
            Text(model.visibleMonth.start(in: CalendarViewModel.displayCalendar),
                 format: .dateTime.month(.wide).year())
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .accessibilityAddTraits(.isHeader)
            Spacer()
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

    private func pager(cellHeight: CGFloat, shiftBuckets: [DayKey: [ShiftItem]]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(pagedMonths, id: \.self) { month in
                    MonthGridView(
                        grid: MonthGrid.make(month: month, calendar: CalendarViewModel.displayCalendar),
                        selectedDay: $model.selectedDay,
                        today: DayKey(containing: .now, in: CalendarViewModel.displayCalendar),
                        compact: !isRegularWidth,
                        cellHeight: cellHeight,
                        dayContent: { cellSummary(for: $0, shiftBuckets: shiftBuckets) }
                    )
                    .containerRelativeFrame(.horizontal)
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
                endsOnLaterDay: endsLater
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
            eventColors: (model.eventsByDay[day] ?? []).prefix(4).map(\.color)
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
    }
}
