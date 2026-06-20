//
//  RotaTemplates.swift
//  Helm
//
//  v9 Rota Templates Gallery: ready-made shift patterns (Mon–Fri, 4-on-4-off,
//  days/nights rotations, rotating weeks…) you can start a schedule from instead
//  of building the cycle slot-by-slot. A template materialises into the SAME
//  graph the builder makes by hand — a Schedule + a cyclic ScheduleSegment + a
//  RotationPattern of slots + the ShiftTypes it needs — so it's fully editable
//  afterwards and writes through the normal preview/apply path.
//

import Foundation
import SwiftData
import HelmDomain

/// A pure description of a repeating rota the user can adopt.
struct RotaTemplate: Identifiable {
    let id: String
    let name: String
    let summary: String
    let symbol: String
    let cycleLengthDays: Int
    /// One entry per cycle day: a shift type code, or nil for an OFF day.
    let slots: [String?]
    /// The shift types this template uses (created if the user doesn't have them).
    let types: [TypeSpec]

    struct TypeSpec {
        let code: String
        let label: String
        let startMinute: Int
        let endMinute: Int
        let overnight: Bool
        let colorHex: String
    }
}

extension RotaTemplate {
    // Reusable shift-type specs (minutes of day).
    private static let day = TypeSpec(code: "D", label: "Day", startMinute: 7 * 60, endMinute: 19 * 60, overnight: false, colorHex: "3B82F6")
    private static let night = TypeSpec(code: "N", label: "Night", startMinute: 19 * 60, endMinute: 7 * 60, overnight: true, colorHex: "6366F1")
    private static let early = TypeSpec(code: "E", label: "Early", startMinute: 7 * 60, endMinute: 15 * 60, overnight: false, colorHex: "14B8A6")
    private static let late = TypeSpec(code: "L", label: "Late", startMinute: 14 * 60, endMinute: 22 * 60, overnight: false, colorHex: "F59E0B")
    private static let office = TypeSpec(code: "D", label: "Day", startMinute: 9 * 60, endMinute: 17 * 60, overnight: false, colorHex: "3B82F6")

    /// The gallery.
    static let all: [RotaTemplate] = [
        RotaTemplate(
            id: "mon-fri", name: "Monday–Friday", summary: "Office hours, weekends off",
            symbol: "briefcase", cycleLengthDays: 7,
            slots: ["D", "D", "D", "D", "D", nil, nil], types: [office]
        ),
        RotaTemplate(
            id: "four-four-days", name: "4 on, 4 off", summary: "Four 12-hour days, then four off",
            symbol: "sun.max", cycleLengthDays: 8,
            slots: ["D", "D", "D", "D", nil, nil, nil, nil], types: [day]
        ),
        RotaTemplate(
            id: "four-four-dn", name: "4 on, 4 off · days & nights", summary: "Two days, two nights, then four off",
            symbol: "moon.stars", cycleLengthDays: 8,
            slots: ["D", "D", "N", "N", nil, nil, nil, nil], types: [day, night]
        ),
        RotaTemplate(
            id: "three-three-dn", name: "3 on, 3 off · days & nights", summary: "Three days, three off, three nights, three off",
            symbol: "arrow.triangle.2.circlepath", cycleLengthDays: 12,
            slots: ["D", "D", "D", nil, nil, nil, "N", "N", "N", nil, nil, nil], types: [day, night]
        ),
        RotaTemplate(
            id: "rotating-eln", name: "Rotating weeks", summary: "A week of earlies, a week of lates, a week of nights",
            symbol: "calendar.badge.clock", cycleLengthDays: 21,
            slots: Array(repeating: "E", count: 7) + Array(repeating: "L", count: 7) + Array(repeating: "N", count: 7),
            types: [early, late, night]
        ),
    ]
}

@MainActor
enum RotaTemplateMaterializer {
    /// Build a fully-editable Schedule from a template and return it (for selection).
    static func makeSchedule(from template: RotaTemplate, in context: ModelContext) -> Schedule {
        let today = Calendar.current.startOfDay(for: .now)
        let horizonEnd = Calendar.current.date(byAdding: .month, value: 6, to: today) ?? today

        // Reuse a ShiftType with the same code if the user already has one, else
        // create it — so adopting a template doesn't spawn duplicate "Day" types.
        let existing = (try? context.fetch(FetchDescriptor<ShiftType>())) ?? []
        var typesByCode: [String: ShiftType] = [:]
        for spec in template.types {
            let code = spec.code.uppercased()
            // Reuse an existing type ONLY if its code AND times match — reusing a
            // same-code type with different hours would give the rota wrong times
            // (and wrong pay). Otherwise create the template's own type.
            if let match = existing.first(where: { t in
                (t.code ?? "").uppercased() == code
                    && t.startMinuteOfDay == spec.startMinute
                    && t.endMinuteOfDay == spec.endMinute
                    && (t.endDayOffset > 0) == spec.overnight
            }) {
                typesByCode[spec.code] = match
            } else {
                let type = ShiftType(
                    code: spec.code, label: spec.label,
                    startMinuteOfDay: spec.startMinute, endMinuteOfDay: spec.endMinute,
                    endDayOffset: spec.overnight ? 1 : 0, workKind: .worked, colorHex: spec.colorHex
                )
                context.insert(type)
                typesByCode[spec.code] = type
            }
        }

        let schedule = Schedule(title: template.name)
        schedule.horizonStart = today
        schedule.horizonEnd = horizonEnd
        context.insert(schedule)

        let segment = ScheduleSegment(kind: .cyclic, sortIndex: 0)
        segment.effectiveFrom = today
        segment.effectiveTo = horizonEnd
        segment.anchorDate = today
        segment.schedule = schedule
        context.insert(segment)

        let pattern = RotationPattern(name: template.name, cycleLengthDays: template.cycleLengthDays)
        context.insert(pattern)
        segment.pattern = pattern

        for (i, code) in template.slots.enumerated() {
            let slot = RotationSlot(sortIndex: i, shiftType: code.flatMap { typesByCode[$0] }, isOff: code == nil)
            slot.pattern = pattern
            context.insert(slot)
        }

        try? context.save()
        return schedule
    }
}
