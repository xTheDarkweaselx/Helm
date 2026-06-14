//
//  SearchView.swift
//  Helm
//
//  v8 global search overhaul: one prominent field across shifts (title, note,
//  location, type label/code, tags), rosters and schedules. Scope chips with live
//  counts; a useful empty state (recent searches + browse-by-tag); rich results
//  grouped Upcoming/Earlier with the matched terms highlighted. Tapping a shift
//  jumps the calendar to its day; rosters/schedules open their pages.
//
//  Matching is computed ONCE per query change into `results` (@State) — never in
//  the per-render computed-property reads — so typing stays smooth even over a
//  large store. Matching uses HelmDomain.SearchMatch (token-AND, diacritic-fold).
//

import SwiftUI
import SwiftData
import HelmDomain

struct SearchView: View {
    let onOpenDay: (DayKey) -> Void
    let onOpenRoster: (String) -> Void
    let onOpenSchedule: (String) -> Void

    @Query(sort: \ShiftInstance.localDate, order: .reverse) private var instances: [ShiftInstance]
    @Query(sort: \Roster.createdAt, order: .reverse) private var rosters: [Roster]
    @Query(sort: \Schedule.createdAt, order: .reverse) private var schedules: [Schedule]
    @Query(sort: \ShiftType.sortIndex) private var allTypes: [ShiftType]
    @Environment(\.helmAccent) private var accent

    @State private var query = ""
    @State private var scope: Scope = .all
    @State private var results = Results()
    @FocusState private var fieldFocused: Bool
    @AppStorage("searchRecentQueries") private var recentsRaw = ""

    private var calendar: Calendar { CalendarViewModel.displayCalendar }

    enum Scope: String, CaseIterable, Identifiable {
        case all, shifts, rosters, schedules
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "All"; case .shifts: "Shifts"; case .rosters: "Rosters"; case .schedules: "Schedules"
            }
        }
    }

    private struct ShiftHit: Identifiable {
        let id: String
        let day: DayKey
        let title: String
        let date: Date?
        let timeText: String?
        let location: String?
        let colorHex: String?
        let tags: [String]
    }

    /// The matched sets — recomputed once per query change, cached here.
    private struct Results {
        var upcoming: [ShiftHit] = []
        var earlier: [ShiftHit] = []
        var rosters: [Roster] = []
        var schedules: [Schedule] = []
        var shiftCount: Int { upcoming.count + earlier.count }
        var total: Int { shiftCount + rosters.count + schedules.count }
    }

    // MARK: - Derived (cheap)

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }
    private var hasQuery: Bool { !trimmed.isEmpty }
    private var queryTokens: [String] { SearchMatch.normalize(query).split(separator: " ").map(String.init) }
    private var recents: [String] { recentsRaw.split(separator: "\n").map(String.init).filter { !$0.isEmpty } }

    /// Distinct tags across the user's shift types (case-insensitive), in order.
    private var allTags: [String] {
        var seen = Set<String>(), result: [String] = []
        for type in allTypes {
            for tag in type.tags where seen.insert(tag.lowercased()).inserted { result.append(tag) }
        }
        return result
    }

    private var showShifts: Bool { scope == .all || scope == .shifts }
    private var showRosters: Bool { scope == .all || scope == .rosters }
    private var showSchedules: Bool { scope == .all || scope == .schedules }

    private var shiftGroups: [(title: String, hits: [ShiftHit])] {
        var groups: [(String, [ShiftHit])] = []
        if !results.upcoming.isEmpty { groups.append(("Upcoming", results.upcoming)) }
        if !results.earlier.isEmpty { groups.append(("Earlier", results.earlier)) }
        return groups.map { (title: $0.0, hits: $0.1) }
    }

    private func count(for scope: Scope) -> Int {
        switch scope {
        case .all: results.total
        case .shifts: results.shiftCount
        case .rosters: results.rosters.count
        case .schedules: results.schedules.count
        }
    }

    // MARK: - Body

    var body: some View {
        List {
            if hasQuery { resultSections } else { browseSections }
        }
        #if os(macOS)
        .listStyle(.inset)
        #endif
        .themedPane(.plain)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .navigationTitle("Search")
        .onAppear { fieldFocused = true }
        .onChange(of: query) { recompute() }
    }

    // MARK: - Header (field + scope)

    private var header: some View {
        VStack(spacing: 10) {
            searchField
            if hasQuery { scopeBar }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search shifts, notes, locations, tags…", text: $query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit(rememberQuery)
            if !query.isEmpty {
                Button { query = ""; fieldFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .font(.title3)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(accent.opacity(fieldFocused ? 0.55 : 0.18), lineWidth: 1))
    }

    private var scopeBar: some View {
        HStack(spacing: 8) {
            ForEach(Scope.allCases) { option in
                let count = count(for: option)
                Button { scope = option } label: {
                    HStack(spacing: 5) {
                        Text(option.label)
                        Text("\(count)").monospacedDigit().opacity(0.65)
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(scope == option ? accent : Color.secondary.opacity(0.14), in: Capsule())
                    .foregroundStyle(scope == option ? Color.white : .primary)
                }
                .buttonStyle(.plain)
                // Empty categories aren't tappable — except the one already selected
                // (so a scope that empties mid-typing isn't a disabled dead-end).
                .disabled(count == 0 && option != .all && option != scope)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Browse (no query)

    @ViewBuilder private var browseSections: some View {
        if !recents.isEmpty {
            Section("Recent") {
                chipFlow(recents, icon: "clock.arrow.circlepath") { query = $0; fieldFocused = true }
                Button("Clear recent searches", role: .destructive) { recentsRaw = "" }
                    .font(.caption)
            }
        }
        if !allTags.isEmpty {
            Section("Browse by tag") {
                chipFlow(allTags, icon: "tag") { query = $0; rememberQuery() }
            }
        }
        Section {
            Label("Search across everything in Helm", systemImage: "magnifyingglass")
                .foregroundStyle(.secondary)
        } footer: {
            Text("Matches shift titles, notes, locations, types and tags, plus roster and schedule names. Tap a shift to jump to its day on the calendar.")
        }
    }

    private func chipFlow(_ items: [String], icon: String, action: @escaping (String) -> Void) -> some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(items, id: \.self) { item in
                Button { action(item) } label: {
                    Label(item, systemImage: icon)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .listRowSeparator(.hidden)
    }

    // MARK: - Results

    @ViewBuilder private var resultSections: some View {
        if results.total == 0 {
            ContentUnavailableView.search(text: trimmed)
        } else if scope != .all, count(for: scope) == 0 {
            // Selected category is empty but others have hits — guide, don't dead-end.
            Section {
                ContentUnavailableView {
                    Label("No \(scope.label.lowercased()) match “\(trimmed)”", systemImage: "magnifyingglass")
                } description: {
                    Text("\(results.total) result\(results.total == 1 ? "" : "s") in other categories — tap All above.")
                }
            }
        }
        if showShifts {
            ForEach(shiftGroups, id: \.title) { group in
                Section("\(group.title) · \(group.hits.count)") {
                    ForEach(group.hits) { hit in
                        Button { open(); onOpenDay(hit.day) } label: { shiftRow(hit) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        if showRosters, !results.rosters.isEmpty {
            Section("Rosters · \(results.rosters.count)") {
                ForEach(results.rosters) { roster in
                    Button { open(); onOpenRoster(roster.id) } label: { rosterRow(roster) }
                        .buttonStyle(.plain)
                }
            }
        }
        if showSchedules, !results.schedules.isEmpty {
            Section("Schedules · \(results.schedules.count)") {
                ForEach(results.schedules) { schedule in
                    Button { open(); onOpenSchedule(schedule.id) } label: { scheduleRow(schedule) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private func shiftRow(_ hit: ShiftHit) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: hit.colorHex) ?? accent)
                .frame(width: 4, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(highlighted(hit.title)).font(.subheadline.weight(.semibold)).lineLimit(1)
                HStack(spacing: 8) {
                    if let date = hit.date {
                        Text(date, format: .dateTime.weekday(.abbreviated).day().month().year())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let time = hit.timeText {
                        Text(time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if let location = hit.location {
                        Label(location, systemImage: "mappin.and.ellipse")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if !hit.tags.isEmpty {
                    TagPillRow(tags: hit.tags, colorFor: { ShiftTags.colorHex(for: $0, customColors: [:]) })
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func rosterRow(_ roster: Roster) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "tablecells").foregroundStyle(accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(highlighted(roster.title ?? "Untitled roster")).font(.subheadline.weight(.medium))
                Text("\((roster.instances ?? []).count) shifts · added \(roster.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func scheduleRow(_ schedule: Schedule) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "slider.horizontal.below.square.filled.and.square").foregroundStyle(accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(highlighted(schedule.title?.isEmpty == false ? schedule.title! : "Untitled schedule"))
                    .font(.subheadline.weight(.medium))
                if let start = schedule.horizonStart, let end = schedule.horizonEnd {
                    Text("\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Matching (computed once per query change)

    private func recompute() {
        let tokens = queryTokens
        guard !tokens.isEmpty else { results = Results(); return }
        // Normalise the query ONCE (here), then only fold each haystack per item.
        func matches(_ haystack: String) -> Bool {
            let hay = SearchMatch.normalize(haystack)
            return tokens.allSatisfy { hay.contains($0) }
        }

        let today = DayKey(containing: .now, in: calendar)
        var hits: [ShiftHit] = []
        for inst in instances {
            guard let localDate = inst.localDate else { continue }
            let type = inst.shiftType
            let tags = type?.tags ?? []
            let haystack = [
                inst.title, inst.note, inst.locationName, type?.locationName,
                type?.label, type?.code, tags.joined(separator: " "),
            ].compactMap { $0 }.joined(separator: " ")
            guard matches(haystack) else { continue }
            hits.append(ShiftHit(
                id: inst.id,
                day: DayKey(containing: localDate, in: calendar),
                title: inst.title ?? type?.label ?? type?.code ?? "Shift",
                date: localDate,
                timeText: timeText(for: inst),
                location: inst.locationName ?? type?.locationName,
                colorHex: type?.colorHex,
                tags: tags
            ))
        }

        results = Results(
            upcoming: hits.filter { $0.day >= today }.sorted { $0.day < $1.day },
            earlier: hits.filter { $0.day < today }.sorted { $0.day > $1.day },
            rosters: rosters.filter { matches($0.title ?? "") },
            schedules: schedules.filter { matches(scheduleHaystack($0)) }
        )
    }

    private func timeText(for inst: ShiftInstance) -> String? {
        if inst.isAllDay == true { return "All-day" }
        guard let start = inst.startUTC, let end = inst.endUTC else { return nil }
        return "\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
    }

    private func scheduleHaystack(_ schedule: Schedule) -> String {
        [schedule.title, schedule.notes].compactMap { $0 }.joined(separator: " ")
    }

    // MARK: - Highlight + recents

    /// Bold + accent every matched query token inside `string`.
    private func highlighted(_ string: String) -> AttributedString {
        var result = AttributedString(string)
        for token in queryTokens {
            var start = result.startIndex
            while start < result.endIndex,
                  let range = result[start...].range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) {
                result[range].inlinePresentationIntent = .stronglyEmphasized
                result[range].foregroundColor = accent
                start = range.upperBound
            }
        }
        return result
    }

    private func rememberQuery() {
        let q = trimmed
        guard q.count >= 2 else { return }
        var list = recents.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        list.insert(q, at: 0)
        recentsRaw = list.prefix(6).joined(separator: "\n")
    }

    private func open() { rememberQuery() }
}
