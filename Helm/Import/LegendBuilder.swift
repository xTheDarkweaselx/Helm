//
//  LegendBuilder.swift
//  Helm
//
//  v6 Import Intelligence, app side: snapshots SwiftData into HelmDomain's
//  pure three-tier MergedLegend (built-ins < global ShiftTypes < per-source
//  learned ShiftCodeMappings), and persists learning EAGERLY — "Helm now
//  knows L = 12:00–20:00" becomes true the moment the user says so, surviving
//  even a cancelled import.
//

import Foundation
import SwiftData
import HelmDomain

@MainActor
enum LegendBuilder {
    /// Build the merged legend for a source (nil source → globals only).
    /// Always rebuilt FROM THE STORE — never patched in place — so panel-save
    /// re-resolution is byte-identical to what the next real import would do.
    static func legend(forSourceName sourceName: String?, in context: ModelContext) -> MergedLegend {
        let types = (try? context.fetch(FetchDescriptor<ShiftType>())) ?? []
        let globals: [LegendMerger.GlobalType] = types.compactMap { type in
            guard let code = type.code, !code.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return LegendMerger.GlobalType(
                code: code,
                label: type.label,
                startMinuteOfDay: type.startMinuteOfDay,
                endMinuteOfDay: type.endMinuteOfDay,
                endDayOffset: type.endDayOffset,
                breakMinutes: type.breakMinutes,
                shiftTypeID: type.id
            )
        }

        var learned: [LegendMerger.Learned] = []
        if let sourceName {
            let fingerprint = RosterSyncEngine.fingerprint(for: sourceName)
            let descriptor = FetchDescriptor<ImportProfile>(predicate: #Predicate { $0.sourceFingerprint == fingerprint })
            if let profile = try? context.fetch(descriptor).first {
                for mapping in profile.codeMappings ?? [] {
                    guard let code = mapping.rawCode else { continue }
                    let action = LegendMerger.Learned.Action(rawValue: mapping.actionRaw ?? "timed") ?? .timed
                    let type = mapping.shiftType
                    learned.append(LegendMerger.Learned(
                        code: code,
                        action: action,
                        label: type?.label ?? (action == .allDay ? code.capitalized : nil),
                        startMinute: type?.startMinuteOfDay,
                        endMinute: type.map { $0.endMinuteOfDay + 1440 * max(0, $0.endDayOffset) },
                        breakMinutes: type?.breakMinutes ?? 0,
                        shiftTypeID: type?.id,
                        lastUsedAt: mapping.lastUsedAt,
                        id: mapping.id
                    ))
                }
            }
        }
        return LegendMerger.merge(globalTypes: globals, learned: learned)
    }

    /// What the user decided an unknown code means.
    enum LearnAction {
        case useExisting(typeID: String)
        case newTimed(label: String?, startMinute: Int, endMinute: Int, overnight: Bool, colorHex: String?)
        case allDay
        case ignore
    }

    /// Persist one decision: find-or-create the ImportProfile (same
    /// fingerprint apply() uses, so no duplicates), upsert the mapping
    /// (fetch-then-mutate — CloudKit forbids unique constraints), save.
    static func learn(code: String, action: LearnAction, sourceName: String, in context: ModelContext) {
        let fingerprint = RosterSyncEngine.fingerprint(for: sourceName)
        let descriptor = FetchDescriptor<ImportProfile>(predicate: #Predicate { $0.sourceFingerprint == fingerprint })
        let profile = (try? context.fetch(descriptor).first) ?? {
            let p = ImportProfile(name: sourceName)
            p.sourceFingerprint = fingerprint
            p.layoutKindRaw = LayoutKind.list.rawValue
            context.insert(p)
            return p
        }()

        let mapping = (profile.codeMappings ?? []).first { $0.rawCode == code } ?? {
            let m = ShiftCodeMapping(rawCode: code, importProfile: profile)
            context.insert(m)
            return m
        }()
        mapping.lastUsedAt = .now

        switch action {
        case let .useExisting(typeID):
            let typeDescriptor = FetchDescriptor<ShiftType>(predicate: #Predicate { $0.id == typeID })
            mapping.shiftType = try? context.fetch(typeDescriptor).first
            mapping.actionRaw = "timed"
        case let .newTimed(label, startMinute, endMinute, overnight, colorHex):
            // Overnight stored exactly like the type editor: endDayOffset = 1.
            let type = ShiftType(
                code: code,
                label: label?.isEmpty == false ? label : code.capitalized,
                startMinuteOfDay: startMinute,
                endMinuteOfDay: endMinute,
                endDayOffset: overnight ? 1 : 0,
                workKind: .worked,
                colorHex: colorHex
            )
            context.insert(type)
            mapping.shiftType = type
            mapping.actionRaw = "timed"
        case .allDay:
            mapping.shiftType = nil
            mapping.actionRaw = "allDay"
        case .ignore:
            mapping.shiftType = nil
            mapping.actionRaw = "ignore"
        }
        try? context.save()
    }

    /// Forget a learned mapping (the Learned-codes list on the Shift Types
    /// page). If the mapping created its own ShiftType (same code) and nothing
    /// else references it, the type goes too — otherwise the code would keep
    /// auto-resolving through the global tier with the very times the user
    /// just disowned, and "the next import will ask again" would be a lie.
    static func forget(_ mapping: ShiftCodeMapping, in context: ModelContext) {
        if (mapping.actionRaw ?? "timed") == "timed",
           let type = mapping.shiftType,
           type.code == mapping.rawCode {
            let otherMappings = (type.codeMappings ?? []).filter { $0.id != mapping.id }
            let unreferenced = (type.instances ?? []).isEmpty
                && (type.rotationSlots ?? []).isEmpty
                && (type.explicitDays ?? []).isEmpty
                && (type.exceptions ?? []).isEmpty
                && otherMappings.isEmpty
            if unreferenced {
                context.delete(type)
            }
        }
        context.delete(mapping)
        try? context.save()
    }
}
