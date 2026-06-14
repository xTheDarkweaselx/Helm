//
//  DataExporter.swift
//  Helm
//
//  v8.2 ship-ready: collects everything in the SwiftData store + the user's
//  preferences into a pure HelmDataExport (HelmDomain), which serialises to a
//  portable JSON file. The data-portability ("export my data") half of GDPR.
//  Read-only — never mutates the store.
//

import Foundation
import SwiftData
import HelmDomain

// Named `HelmDataExporter` (not `DataExporter`) to avoid a clash with a macOS
// SDK symbol of that name — the bare name resolved on iOS but not macOS.
enum HelmDataExporter {
    static func export(from context: ModelContext, now: Date = .now) -> HelmDataExport {
        HelmDataExport(
            exportedAt: now,
            app: appVersionString,
            shiftTypes: fetch(context, ShiftType.self)
                .sorted { ($0.code ?? "") < ($1.code ?? "") }
                .map(exportedType),
            rosters: fetch(context, Roster.self)
                .sorted { $0.createdAt < $1.createdAt }
                .map(exportedRoster),
            schedules: fetch(context, Schedule.self)
                .sorted { $0.createdAt < $1.createdAt }
                .map(exportedSchedule),
            timeOff: fetch(context, TimeOff.self)
                .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
                .map(exportedTimeOff),
            availabilityRules: fetch(context, AvailabilityRule.self).map(exportedRule),
            availabilityWindows: fetch(context, AvailabilityWindow.self)
                .sorted { ($0.localDate ?? .distantPast) < ($1.localDate ?? .distantPast) }
                .map(exportedWindow),
            settings: exportedSettings()
        )
    }

    private static func fetch<T: PersistentModel>(_ context: ModelContext, _ type: T.Type) -> [T] {
        (try? context.fetch(FetchDescriptor<T>())) ?? []
    }

    private static var appVersionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "Helm \(v)"
    }

    // MARK: - Mappers (SwiftData → pure DTOs)

    private static func exportedType(_ t: ShiftType) -> ExportedShiftType {
        ExportedShiftType(code: t.code, label: t.label, startMinuteOfDay: t.startMinuteOfDay,
                          endMinuteOfDay: t.endMinuteOfDay, endDayOffset: t.endDayOffset,
                          breakMinutes: t.breakMinutes, paid: t.paid, paidHoursOverride: t.paidHoursOverride,
                          workKind: t.workKind.rawValue,
                          colorHex: t.colorHex, location: t.locationName, tags: t.tags)
    }

    private static func exportedRoster(_ r: Roster) -> ExportedRoster {
        let shifts = (r.instances ?? [])
            .sorted { ($0.localDate ?? .distantPast) < ($1.localDate ?? .distantPast) }
            .map(exportedShift)
        return ExportedRoster(title: r.title, createdAt: r.createdAt,
                              reminderOffsetsMinutes: r.reminderOffsetsRaw.map(ReminderOffsets.parse),
                              shifts: shifts)
    }

    private static func exportedShift(_ i: ShiftInstance) -> ExportedShift {
        ExportedShift(date: i.localDate, start: i.startUTC, end: i.endUTC,
                      isAllDay: i.isAllDay ?? false, timeZone: i.timeZoneIdentifier,
                      paidHours: i.computedPaidHours, shiftCode: i.shiftType?.code,
                      title: i.title, location: i.locationName, note: i.note)
    }

    private static func exportedSchedule(_ s: Schedule) -> ExportedSchedule {
        let segments = (s.segments ?? []).sorted { $0.sortIndex < $1.sortIndex }.map(exportedSegment)
        let exceptions = (s.exceptions ?? [])
            .sorted { ($0.localDate ?? .distantPast) < ($1.localDate ?? .distantPast) }
            .map(exportedException)
        return ExportedSchedule(title: s.title, createdAt: s.createdAt, notes: s.notes,
                                horizonStart: s.horizonStart, horizonEnd: s.horizonEnd,
                                segments: segments, exceptions: exceptions)
    }

    private static func exportedSegment(_ seg: ScheduleSegment) -> ExportedScheduleSegment {
        let slots = (seg.pattern?.slots ?? []).sorted { $0.sortIndex < $1.sortIndex }.map {
            ExportedSlot(position: $0.sortIndex, isOff: $0.isOff, shiftCode: $0.shiftType?.code, location: $0.locationName)
        }
        let days = (seg.explicitDays ?? [])
            .sorted { ($0.localDate ?? .distantPast) < ($1.localDate ?? .distantPast) }.map {
            ExportedExplicitDay(date: $0.localDate, isOff: $0.isOff, shiftCode: $0.shiftType?.code, title: $0.title, location: $0.locationName)
        }
        return ExportedScheduleSegment(title: seg.title, kind: seg.kind.rawValue,
                                       effectiveFrom: seg.effectiveFrom, effectiveTo: seg.effectiveTo,
                                       anchorDate: seg.anchorDate, patternName: seg.pattern?.name,
                                       cycleLengthDays: seg.pattern?.cycleLengthDays, slots: slots, explicitDays: days)
    }

    private static func exportedException(_ e: ScheduleException) -> ExportedScheduleException {
        ExportedScheduleException(date: e.localDate, kind: e.kind.rawValue, shiftCode: e.shiftType?.code, title: e.title)
    }

    private static func exportedTimeOff(_ t: TimeOff) -> ExportedTimeOff {
        ExportedTimeOff(startDate: t.startDate, endDate: t.endDate, kind: t.kind.rawValue,
                        paid: t.paid, hoursPerDay: t.hoursPerDay, title: t.title, note: t.note)
    }

    private static func exportedRule(_ r: AvailabilityRule) -> ExportedAvailabilityRule {
        ExportedAvailabilityRule(kind: r.kind.rawValue, weekdays: r.weekdays.sorted(),
                                 startMinuteOfDay: r.startMinuteOfDay, endMinuteOfDay: r.endMinuteOfDay,
                                 effectiveFrom: r.effectiveFrom, effectiveTo: r.effectiveTo, note: r.note)
    }

    private static func exportedWindow(_ w: AvailabilityWindow) -> ExportedAvailabilityWindow {
        ExportedAvailabilityWindow(date: w.localDate, kind: w.kind.rawValue,
                                   startMinuteOfDay: w.startMinuteOfDay, endMinuteOfDay: w.endMinuteOfDay,
                                   allDay: w.allDay, note: w.note)
    }

    private static func exportedSettings() -> ExportedSettings {
        let d = UserDefaults.standard
        // Export the EFFECTIVE settings (the values the app actually applies), not
        // the raw stored keys — @AppStorage defaults aren't persisted until changed,
        // so reading raw keys would emit null for a user who never touched them.
        let rules = PaySettings.rules
        let destinations = CalendarDestinationSetting.parse(d.string(forKey: CalendarDestinationSetting.key) ?? "")
        return ExportedSettings(
            hourlyRate: rules.hourlyRate > 0 ? rules.hourlyRate : nil,
            overtimeEnabled: rules.overtimeEnabled,
            overtimeThresholdHours: rules.overtimeThresholdHours,
            overtimeMultiplier: rules.overtimeMultiplier,
            taxYearPreset: d.string(forKey: PaySettings.taxYearPresetKey) ?? "uk",
            themeID: d.string(forKey: ThemeManager.storageKey),
            reminderOffsetsMinutes: ReminderSetting.offsets,
            calendarDestinations: (destinations.isEmpty ? [.eventkit] : destinations).map(\.rawValue).sorted()
        )
    }
}
