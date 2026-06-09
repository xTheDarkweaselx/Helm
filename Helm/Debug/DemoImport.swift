//
//  DemoImport.swift
//  Helm
//
//  DEBUG-only test harness: auto-imports a bundled sample roster on launch when
//  the HELM_DEMO_IMPORT=1 environment variable is set, so the full
//  CSV → SwiftData → EventKit flow can be exercised on a simulator without
//  tapping the file picker / permission dialog. Not compiled into release builds.
//

#if DEBUG
import Foundation
import SwiftData
import OSLog

enum DemoImport {
    private static let log = Logger(subsystem: "Fusion-Studios.Helm", category: "DemoImport")
    private static var mode: String? { ProcessInfo.processInfo.environment["HELM_DEMO_IMPORT"] }
    static var isRequested: Bool { mode != nil }
    /// Optional absolute path to a real .xlsx to import (set via env, never hardcoded).
    private static var xlsxPath: String? { ProcessInfo.processInfo.environment["HELM_DEMO_XLSX_PATH"] }

    /// Synthetic sample mirroring the first real roster's format (also in
    /// Fixtures/Rosters/sample-roster.csv). Embedded so no bundling is required.
    static let sampleCSV = """
    DATE,Day of the Week,Course Title,Location,Day #,SHIFT
    14/06/2026,Sunday,HMI Day 1,D2,1,M
    15/06/2026,Monday,HMI Day 2,D2,2,M
    17/06/2026,Wednesday,HMI Day 4,D2,4,A
    20/06/2026,Saturday,OFF,-,7,OFF
    26/06/2026,Friday,"Medway Intro Day, PTT",PTT,13,0930-1500
    28/06/2026,Sunday,Medway Day 1,D2,15,A
    02/07/2026,Thursday,Medway Day 2,D2,19,M
    15/12/2026,Tuesday,UEC ART Classroom Day,-,185,TBC
    """

    @MainActor
    static func runIfRequested(modelContext: ModelContext) async {
        guard isRequested else { return }
        if mode == "build" { await runDemoBuild(modelContext: modelContext); return }
        let result: RosterImportResult
        do {
            if mode == "xlsx", let path = xlsxPath {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                result = try RosterImporter.importXLSX(data: data, sourceName: name)
            } else {
                result = try RosterImporter.importCSV(text: sampleCSV, sourceName: "Sample (June)")
            }
        } catch {
            print("DemoImport failed: \(error)")
            return
        }
        let coordinator = ImportCoordinator()
        coordinator.result = result
        coordinator.preparePlan(modelContext: modelContext)
        await coordinator.commit(modelContext: modelContext)
        if case let .finished(summary) = coordinator.phase {
            log.notice("summary: added=\(summary.added) updated=\(summary.updated) removed=\(summary.removed) unchanged=\(summary.unchanged) reimport=\(summary.isReimport)")
        } else if case let .failed(message) = coordinator.phase {
            log.error("failed: \(message, privacy: .public)")
        }
    }

    /// Build (or reuse) a sample rota — an 8-day M,M,M,A,A,A,OFF,OFF cycle over two
    /// months — then materialise + sync it, to exercise the builder end-to-end.
    @MainActor
    static func runDemoBuild(modelContext: ModelContext) async {
        let schedule: Schedule
        if let existing = try? modelContext.fetch(FetchDescriptor<Schedule>()).first {
            schedule = existing // re-materialise to prove idempotency
        } else {
            let m = ShiftType(code: "M", label: "Morning", startMinuteOfDay: 390, endMinuteOfDay: 810, workKind: .worked, locationName: "D2")
            let a = ShiftType(code: "A", label: "Afternoon", startMinuteOfDay: 810, endMinuteOfDay: 1320, workKind: .worked, locationName: "D2")
            modelContext.insert(m); modelContext.insert(a)
            let pattern = RotationPattern(name: "HMI 8-day", cycleLengthDays: 8)
            modelContext.insert(pattern)
            let slotTypes: [ShiftType?] = [m, m, m, a, a, a, nil, nil]
            for (i, type) in slotTypes.enumerated() {
                let slot = RotationSlot(sortIndex: i, shiftType: type, isOff: type == nil)
                slot.pattern = pattern
                modelContext.insert(slot)
            }
            let cal = Calendar.current
            let start = cal.date(from: DateComponents(year: 2026, month: 6, day: 1))!
            let end = cal.date(byAdding: .month, value: 2, to: start)!
            let s = Schedule(title: "Demo rota")
            s.horizonStart = start; s.horizonEnd = end
            modelContext.insert(s)
            let seg = ScheduleSegment(kind: .cyclic, sortIndex: 0)
            seg.effectiveFrom = start; seg.effectiveTo = end; seg.anchorDate = start
            seg.pattern = pattern; seg.schedule = s
            modelContext.insert(seg)
            try? modelContext.save()
            schedule = s
        }

        let result = ScheduleMaterializer.makeResult(for: schedule)
        let plan = RosterSyncEngine.plan(for: result, in: modelContext)
        let writer = ShiftCalendarWriter()
        guard await writer.requestAccess() else { log.error("build: no calendar access"); return }
        do {
            let summary = try await RosterSyncEngine.apply(plan, target: writer, in: modelContext)
            log.notice("build summary: added=\(summary.added) updated=\(summary.updated) removed=\(summary.removed) unchanged=\(summary.unchanged) reimport=\(summary.isReimport)")
        } catch {
            log.error("build failed: \(error, privacy: .public)")
        }
    }
}
#endif
