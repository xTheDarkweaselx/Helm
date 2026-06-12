# Xcode-agent task: wire up the Helm watchOS companion

Paste everything below the line into the Xcode coding agent (Claude in Xcode)
with the Helm project open. It can build to verify — make it build green for
the watch simulator before finishing.

---

You are working in the **Helm** Xcode project (iOS/macOS SwiftUI + SwiftData
app; bundle id `Fusion-Studios.Helm`, team `8RUSX2C6R9`, Automatic signing).
Your job: add the **watchOS companion app + watch widget (complications)
extension** using SOURCE FILES THAT ALREADY EXIST in the repo-root
`HelmWatch/` folder, then make everything build. Do **not** rewrite the watch
logic — only create/configure the targets and wire the staged files in. This
mirrors exactly how the HelmWidget extension was wired earlier (that worked).

## Context

- The iPhone app already pushes a `HelmSnapshot` JSON blob to the watch via
  WatchConnectivity (`Helm/Widgets/WatchBridge.swift`,
  applicationContext key `HelmAppGroup.watchSnapshotContextKey`). The watch
  side receives it in `HelmWatch/PhoneLink.swift`.
- Shared data types live in the **HelmDomain** library of the local SwiftPM
  package `HelmCore` (already in the project).
- Staged files: `HelmWatch/HelmWatchApp.swift`, `HelmWatch/PhoneLink.swift`,
  `HelmWatch/WatchRootView.swift` (watch APP);
  `HelmWatch/Complications/HelmWatchComplications.swift` (watch WIDGET
  extension, contains its own `@main` WidgetBundle);
  `HelmWatch/HelmWatch.entitlements` (App Group shape).

## Steps

1. **Create the watch app target**: File ▸ New ▸ Target ▸ watchOS ▸ **App**,
   name **HelmWatch**, choose **"Watch App for Existing iOS App"** so it
   companions `Fusion-Studios.Helm`. Team `8RUSX2C6R9`, Automatic signing.
   If the wizard offers to include a widget extension, accept and name it
   **HelmWatchComplications**; otherwise create it after via File ▸ New ▸
   Target ▸ watchOS ▸ Widget Extension.
2. **Build settings on BOTH watch targets** (match the staged code's
   verification): `SWIFT_VERSION = 6.0`,
   `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
   `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`,
   deployment target 26.0 (or the project default).
3. **Link HelmDomain** (only that product) to BOTH watch targets via
   General ▸ Frameworks, Libraries and Embedded Content.
4. **Replace generated sources with the staged ones.**
   - HelmWatch app target: delete the template's generated Swift files; add
     the three staged app files with Target Membership = HelmWatch only.
   - HelmWatchComplications target: delete its generated Swift files
     (including any generated `@main` bundle/attributes); add
     `HelmWatch/Complications/HelmWatchComplications.swift` with membership =
     HelmWatchComplications only.
5. **App Groups** capability on BOTH watch targets:
   `group.Fusion-Studios.Helm` (same container as the iPhone app + widget —
   see `HelmWatch/HelmWatch.entitlements` for the expected shape).
6. **Build** the HelmWatch scheme for a watch simulator. Fix any
   signing/provisioning errors (usually App Group registration or bundle-id
   hierarchy: the watch app must be `Fusion-Studios.Helm.watchkitapp`, the
   complications extension a child of it).
7. **Runtime check**: run Helm (iPhone sim) + HelmWatch (paired watch sim).
   In Helm import/modify a roster → the watch app should show the next shift
   within seconds (WCSession applicationContext). Add the "Next Shift" and
   "Week Hours" complications to a watch face and confirm they render.
8. **Report** every build setting/file change you made and paste the final
   build result. If a staged file needs a minimal SDK fix, make it and note
   it explicitly (the files were typechecked against the watchOS 26 SDK with
   the flags in step 2, so divergences should be tiny).

### Gotchas (learned wiring HelmWidget)
- The repo-root `HelmWatch/` folder is deliberately OUTSIDE the `Helm/`
  synchronized group — never add these files to the iOS/macOS app target.
- Keep ONE `@main` per target (delete template stubs first).
- WCSession delegate callbacks arrive on a background queue — the staged
  code already declares those witnesses `nonisolated` and hops to MainActor;
  don't "fix" that.
- If complications show placeholders only: the watch APP must run once first
  (PhoneLink stores the snapshot the complications read), and the App Group
  must be on BOTH watch targets.
