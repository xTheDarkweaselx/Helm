//
//  SearchView.swift
//  Helm
//
//  v7 global search: one field across shifts (title, note, location, type
//  label/code, tags), rosters and schedules. Tapping a shift jumps the calendar
//  to its day; rosters/schedules open their pages. In-memory over @Query — fast
//  at single-user scale; matching uses the pure HelmDomain.SearchMatch rule.
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
    @State private var query = ""

    private var calendar: Calendar { CalendarViewModel.displayCalendar }
    private static let shiftCap = 60

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                Section {
                    Label("Search shifts, rosters and schedules", systemImage: "magnifyingglass")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Matches titles, notes, locations and tags. Tap a shift to jump to its day on the calendar.")
                }
            } else {
                let shiftHits = matchingShifts()
                let rosterHits = rosters.filter { SearchMatch.matches($0.title ?? "", query: query) }
                let scheduleHits = schedules.filter { SearchMatch.matches($0.title ?? "", query: query) }

                if shiftHits.isEmpty && rosterHits.isEmpty && scheduleHits.isEmpty {
                    ContentUnavailableView.search(text: query)
                }

                if !shiftHits.isEmpty {
                    Section {
                        ForEach(shiftHits.prefix(Self.shiftCap)) { hit in
                            Button { onOpenDay(hit.day) } label: { shiftRow(hit) }
                                .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Shifts")
                    } footer: {
                        if shiftHits.count > Self.shiftCap {
                            Text("Showing the first \(Self.shiftCap) of \(shiftHits.count) — refine your search to narrow it.")
                        }
                    }
                }

                if !rosterHits.isEmpty {
                    Section("Rosters") {
                        ForEach(rosterHits) { roster in
                            Button { onOpenRoster(roster.id) } label: {
                                Label(roster.title ?? "Untitled roster", systemImage: "tablecells")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !scheduleHits.isEmpty {
                    Section("Schedules") {
                        ForEach(scheduleHits) { schedule in
                            Button { onOpenSchedule(schedule.id) } label: {
                                Label(schedule.title?.isEmpty == false ? schedule.title! : "Untitled schedule",
                                      systemImage: "slider.horizontal.below.square.filled.and.square")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, placement: .toolbar, prompt: "Search shifts, rosters, notes…")
    }

    private struct ShiftHit: Identifiable {
        let id: String
        let day: DayKey
        let title: String
        let date: Date?
        let colorHex: String?
        let tags: [String]
        let isAllDay: Bool
    }

    private func matchingShifts() -> [ShiftHit] {
        instances.compactMap { inst -> ShiftHit? in
            guard let localDate = inst.localDate else { return nil }
            let type = inst.shiftType
            let haystack = [
                inst.title, inst.note, inst.locationName,
                type?.label, type?.code, type?.tags.joined(separator: " "),
            ].compactMap { $0 }.joined(separator: " ")
            guard SearchMatch.matches(haystack, query: query) else { return nil }
            return ShiftHit(
                id: inst.id,
                day: DayKey(containing: localDate, in: calendar),
                title: inst.title ?? type?.label ?? type?.code ?? "Shift",
                date: localDate,
                colorHex: type?.colorHex,
                tags: type?.tags ?? [],
                isAllDay: inst.isAllDay ?? false
            )
        }
    }

    private func shiftRow(_ hit: ShiftHit) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: hit.colorHex) ?? .accentColor)
                .frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title).font(.subheadline.weight(.semibold))
                if let date = hit.date {
                    Text(date, format: .dateTime.weekday().day().month().year())
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !hit.tags.isEmpty {
                    TagPillRow(tags: hit.tags, colorFor: { ShiftTags.colorHex(for: $0, customColors: [:]) })
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
