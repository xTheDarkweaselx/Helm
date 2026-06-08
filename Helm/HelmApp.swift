//
//  HelmApp.swift
//  Helm
//
//  Created by Adam Ibrahim on 08/06/2026.
//

import SwiftUI
import SwiftData
import OSLog

@main
struct HelmApp: App {
    let modelContainer: ModelContainer

    init() {
        self.modelContainer = HelmApp.makeModelContainer()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
    }
}

extension HelmApp {
    static let log = Logger(subsystem: "Fusion-Studios.Helm", category: "Persistence")

    /// The CloudKit container backing the private database. Must match an
    /// `com.apple.developer.icloud-container-identifiers` entry in Helm.entitlements
    /// and a container provisioned in the Apple Developer account.
    static let cloudKitContainerID = "iCloud.Fusion-Studios.Helm"

    static var schema: Schema {
        Schema([
            UserProfile.self,
            ShiftType.self,
            Roster.self,
            ShiftInstance.self,
            ShiftSegment.self,
            RotationPattern.self,
            RotationSlot.self,
            RotationAssignment.self,
            ImportProfile.self,
            ShiftCodeMapping.self,
            ImportRun.self,
            CalendarSyncRecord.self,
        ])
    }

    /// Build the model container with graceful degradation (ADR-10): CloudKit
    /// private store → local-only store → in-memory. The app must launch and
    /// import-to-calendar must work even with no iCloud account, a CloudKit
    /// misconfiguration, or a schema mismatch — never a launch crash.
    static func makeModelContainer() -> ModelContainer {
        let schema = schema

        // 1. Preferred: CloudKit-synced private database.
        let cloudConfig = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .private(cloudKitContainerID)
        )
        do {
            return try ModelContainer(for: schema, configurations: [cloudConfig])
        } catch {
            log.error("CloudKit ModelContainer failed, falling back to local store: \(error, privacy: .public)")
        }

        // 2. Fallback: on-device only (no sync).
        let localConfig = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(for: schema, configurations: [localConfig])
        } catch {
            log.error("Local ModelContainer failed, falling back to in-memory: \(error, privacy: .public)")
        }

        // 3. Last resort: ephemeral store so the app still launches.
        let memoryConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: [memoryConfig])
        } catch {
            fatalError("Helm could not create any ModelContainer: \(error)")
        }
    }
}
