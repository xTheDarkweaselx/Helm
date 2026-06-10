//
//  HelmApp.swift
//  Helm
//
//  Created by Adam Ibrahim on 08/06/2026.
//

import SwiftUI
import SwiftData
import OSLog
#if os(macOS)
import Security
#endif

@main
struct HelmApp: App {
    let modelContainer: ModelContainer

    init() {
        self.modelContainer = HelmApp.makeModelContainer()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
            #if os(macOS)
                // Liquid Glass: a light, translucent main window.
                .containerBackground(.ultraThinMaterial, for: .window)
            #endif
        }
        .modelContainer(modelContainer)
        #if os(macOS)
        .defaultSize(width: 1040, height: 680)
        #endif

        #if os(macOS)
        // Standard Mac Settings window (⌘,) — same form as the sidebar's
        // Settings destination, minus the navigation chrome.
        Settings {
            SettingsForm()
                .frame(minWidth: 520, idealWidth: 560, minHeight: 480)
        }
        .modelContainer(modelContainer)
        #endif
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
            Schedule.self,
            ScheduleSegment.self,
            ExplicitDay.self,
            ScheduleException.self,
            ImportProfile.self,
            ShiftCodeMapping.self,
            ImportRun.self,
            CalendarSyncRecord.self,
        ])
    }

    /// Whether this PROCESS is actually signed with the CloudKit entitlement.
    /// The ubiquityIdentityToken gate alone is not enough on macOS: with iCloud
    /// signed in but the build signed WITHOUT the iCloud capability (e.g. "Sign
    /// to Run Locally" / missing provisioning), CKContainer initialization
    /// raises an uncatchable NSException on a background thread —
    /// "In order to use CloudKit, your process must have a
    /// com.apple.developer.icloud-services entitlement" → EXC_BREAKPOINT.
    /// Field-hit on the first properly-validating Mac launch.
    static var processHasCloudKitEntitlement: Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil)
        else { return false }
        if let services = value as? [String] { return services.contains("CloudKit") }
        return false
        #else
        // iOS/visionOS: installation enforces provisioning, and the SecTask API
        // isn't available — the account gate suffices there.
        true
        #endif
    }

    /// Build the model container with graceful degradation (ADR-10): CloudKit
    /// private store → local-only store → in-memory. The app must launch and
    /// import-to-calendar must work even with no iCloud account, a CloudKit
    /// misconfiguration, or a schema mismatch — never a launch crash.
    static func makeModelContainer() -> ModelContainer {
        let schema = schema

        // 1. Preferred: CloudKit-synced private database — but only engage CloudKit
        // when an iCloud account is actually available. Without an account (or the
        // entitlement, e.g. an unsigned build) CloudKit's mirroring delegate traps
        // ASYNCHRONOUSLY during setup, which a do/catch here cannot rescue — so we
        // must decide up front. Account-less devices fall through to a local store;
        // import-to-calendar still works (ADR-10).
        if FileManager.default.ubiquityIdentityToken != nil, processHasCloudKitEntitlement {
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
        } else {
            log.notice("CloudKit unavailable (no iCloud account, or the build lacks the iCloud entitlement); using a local store (no sync).")
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
