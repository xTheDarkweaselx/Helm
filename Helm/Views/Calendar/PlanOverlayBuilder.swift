//
//  PlanOverlayBuilder.swift
//  Helm
//
//  Turns a pending RosterSyncEngine.Plan into the calendar's PreviewOverlay,
//  rendering exactly what apply() WILL do:
//  - added/updated from the plan's writable drafts (last-wins by dedupKey,
//    mirroring apply()'s incomingByKey),
//  - removed from the EXISTING roster's instances (they're what disappears),
//  - unchanged shifts keep rendering live (suppression covers only keys the
//    overlay replaces: updated ∪ removed).
//

import Foundation
import SwiftData
import HelmDomain

@MainActor
enum PlanOverlayBuilder {
    static func build(from plan: RosterSyncEngine.Plan, in context: ModelContext) -> PreviewOverlay {
        // Last-wins on duplicate keys, mirroring RosterSyncEngine.apply().
        let draftsByKey = Dictionary(
            plan.result.drafts.filter(\.isWritable).map { ($0.dedupKey, $0) },
            uniquingKeysWith: { _, last in last }
        )

        var typeColorCache: [String: String?] = [:]
        var items: [PreviewItem] = []

        for key in plan.diff.added {
            if let draft = draftsByKey[key] {
                items.append(item(for: draft, status: .added, colorCache: &typeColorCache, context: context))
            }
        }
        for key in plan.diff.updated {
            if let draft = draftsByKey[key] {
                items.append(item(for: draft, status: .updated, colorCache: &typeColorCache, context: context))
            }
        }

        // Removed: resolve from the matched roster's existing instances.
        let removedKeys = Set(plan.diff.removed)
        if !removedKeys.isEmpty, let profileID = plan.existingProfileID {
            let descriptor = FetchDescriptor<Roster>(predicate: #Predicate { $0.sourceImportProfileID == profileID })
            if let roster = try? context.fetch(descriptor).first {
                for instance in roster.instances ?? [] {
                    guard let key = instance.dedupKey, removedKeys.contains(key) else { continue }
                    let tz = TimeZone(identifier: instance.timeZoneIdentifier) ?? .current
                    let (_, endsLater) = DayBucketer.shiftDay(
                        localDate: instance.localDate ?? .now,
                        start: instance.startUTC,
                        end: instance.endUTC,
                        timeZone: tz
                    )
                    items.append(PreviewItem(
                        id: key + "#preview",
                        dedupKey: key,
                        title: instance.title ?? instance.shiftType?.label ?? instance.shiftType?.code ?? "Shift",
                        start: instance.startUTC,
                        end: instance.endUTC,
                        colorHex: instance.shiftType?.colorHex,
                        endsOnLaterDay: endsLater,
                        status: .removed
                    ))
                }
            }
        }

        var byDay: [DayKey: [PreviewItem]] = [:]
        var firstChanged: DayKey?
        for item in items {
            let day = day(for: item)
            byDay[day, default: []].append(item)
            if firstChanged == nil || day < firstChanged! { firstChanged = day }
        }

        return PreviewOverlay(
            itemsByDay: byDay,
            suppressedShiftKeys: Set(plan.diff.updated).union(removedKeys),
            firstChangedDay: firstChanged
        )
    }

    // MARK: - Helpers

    private static func item(
        for draft: DraftShift,
        status: PreviewItem.Status,
        colorCache: inout [String: String?],
        context: ModelContext
    ) -> PreviewItem {
        let tz = TimeZone(identifier: draft.timeZoneIdentifier) ?? .current
        let (_, endsLater) = DayBucketer.shiftDay(
            localDate: draft.localDate, start: draft.start, end: draft.end, timeZone: tz
        )
        return PreviewItem(
            id: draft.dedupKey + "#preview",
            dedupKey: draft.dedupKey,
            title: resolvedTitle(for: draft),
            start: draft.start,
            end: draft.end,
            colorHex: colorHex(for: draft, cache: &colorCache, context: context),
            endsOnLaterDay: endsLater,
            status: status
        )
    }

    /// The day an overlay item lands on — same rule as live shifts.
    private static func day(for item: PreviewItem) -> DayKey {
        // start is the resolved instant; derive its civil day in current tz is
        // WRONG for foreign-tz rotas — but PreviewItems carry no tz, so reuse
        // the dedupKey's day, which IS the civil day by construction
        // ("yyyy-MM-dd|tz|code" / "yyyy-MM-dd|tz|g:…").
        let dayPart = item.dedupKey.prefix(10) // "yyyy-MM-dd"
        let parts = dayPart.split(separator: "-").compactMap { Int($0) }
        if parts.count == 3 {
            return DayKey(year: parts[0], month: parts[1], day: parts[2])
        }
        // Fallback: bucket the start instant in the current zone.
        return DayKey(containing: item.start ?? .now, in: Calendar.current)
    }

    /// Mirrors RosterSyncEngine.resolvedTitle so the preview shows the title
    /// that will actually be persisted.
    private static func resolvedTitle(for draft: DraftShift) -> String {
        if let t = draft.title { return t }
        if let l = draft.label { return l }
        if let s = draft.startMinuteOfDay {
            return hhmm(s) + (draft.endMinuteOfDay.map { "–" + hhmm($0) } ?? "")
        }
        return draft.code.isEmpty ? "Shift" : draft.code
    }

    /// The chip color the shift WILL have: the builder's exact ShiftType, else
    /// an existing type matched by code (as apply() reuses), else none (a new
    /// code's type doesn't exist until commit).
    private static func colorHex(
        for draft: DraftShift,
        cache: inout [String: String?],
        context: ModelContext
    ) -> String? {
        let cacheKey = draft.shiftTypeID ?? "code:\(draft.code)"
        if let cached = cache[cacheKey] { return cached }

        var hex: String?
        if let id = draft.shiftTypeID {
            let d = FetchDescriptor<ShiftType>(predicate: #Predicate { $0.id == id })
            hex = (try? context.fetch(d).first)?.colorHex
        } else if !draft.code.isEmpty {
            let code = draft.code
            let d = FetchDescriptor<ShiftType>(predicate: #Predicate { $0.code == code })
            hex = (try? context.fetch(d).first)?.colorHex
        }
        cache[cacheKey] = hex
        return hex
    }

    private static func hhmm(_ minute: Int) -> String {
        let m = ((minute % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }
}
