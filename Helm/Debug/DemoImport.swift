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

enum DemoImport {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["HELM_DEMO_IMPORT"] == "1"
    }

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
        guard let result = try? RosterImporter.importCSV(text: sampleCSV, sourceName: "Sample (June)") else { return }
        let coordinator = ImportCoordinator()
        coordinator.result = result
        await coordinator.commit(modelContext: modelContext)
    }
}
#endif
