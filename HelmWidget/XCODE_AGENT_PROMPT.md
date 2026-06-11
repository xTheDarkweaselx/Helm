# Xcode-agent task: wire up the Helm widget extension

Paste everything below the line into the Xcode coding agent (Claude in Xcode),
with the Helm project open. It can build to verify — please make it build green
before finishing.

---

You are working in the **Helm** Xcode project (an iOS/iPadOS/macOS SwiftUI +
SwiftData app; bundle id `Fusion-Studios.Helm`, team `8RUSX2C6R9`, Automatic
signing, deployment target 26.x). The app code is complete and builds. Your job
is to add a **Widget Extension** (WidgetKit widgets + an ActivityKit Live
Activity) using SOURCE FILES THAT ALREADY EXIST in the repo, then make the whole
thing build and run. Do **not** rewrite the widget logic — only create/​configure
the target and wire the existing files in.

## Context you must know

- The app already writes a shared snapshot to an **App Group** via
  `Helm/Widgets/SnapshotWriter.swift`. It no-ops until the App Group is
  configured. The widget reads that snapshot back.
- The shared data types live in the **HelmDomain** module (part of the local
  Swift package `HelmCore`, already added to the project): `HelmSnapshot`,
  `SnapshotShift`, `HelmAppGroup`, `ShiftActivityAttributes`. The app target
  already links HelmDomain.
- The staged widget source files are in the repo-root **`HelmWidget/`** folder
  (a sibling of `Helm/` and `HelmCore/` — deliberately OUTSIDE the app's
  file-system-synchronized group so they are NOT in the app target):
  - `HelmWidgetBundle.swift` — `@main` WidgetBundle (entry point)
  - `NextShiftWidget.swift` — TimelineProvider + widget views (small/medium/lock)
  - `ShiftLiveActivity.swift` — Live Activity UI (gated `#if os(iOS)`; contains
    `extension ShiftActivityAttributes: @retroactive ActivityAttributes {}`)
  - `SnapshotStore.swift` — reads the App Group snapshot
  - `WidgetSupport.swift` — a local `Color(helmHex:)` helper
  - `HelmWidget.entitlements` — app-sandbox + the App Group
  - `Info.plist` — the widget's NSExtension dict
  - (`README.md` / this file — ignore)

## Identifiers to use (exact)

- Widget target name: **HelmWidget**
- Widget bundle id: **`Fusion-Studios.Helm.HelmWidget`** (must be a sub-bundle of the app)
- App Group container: **`group.Fusion-Studios.Helm`** (must be identical on app + widget)
- Development team: **`8RUSX2C6R9`**, Automatic signing on both targets.

## Steps

1. **Fix the app's App Group.** Open `Helm/Helm.entitlements`. The key
   `com.apple.security.application-groups` is currently an **empty array** —
   add the string `group.Fusion-Studios.Helm` to it. (Equivalently: Helm target
   → Signing & Capabilities → App Groups → ensure `group.Fusion-Studios.Helm` is
   checked/added; let Xcode register it on the developer portal.)

2. **Create the widget target.** File ▸ New ▸ Target ▸ **Widget Extension**.
   Name it **HelmWidget**, **check "Include Live Activity"**, embed it in the
   Helm app. Set its bundle id to `Fusion-Studios.Helm.HelmWidget`, team
   `8RUSX2C6R9`, Automatic signing.

3. **Replace the generated sources with the staged ones.** Xcode generates stub
   files (a `*Bundle.swift`, a widget, a Live Activity, an `*Attributes.swift`,
   an Info.plist, maybe an Assets catalog). **Delete the generated `.swift`
   stubs** (especially any generated `ActivityAttributes` type — ours lives in
   HelmDomain; do not create a second one), then **add the staged files** from
   the repo-root `HelmWidget/` folder to the HelmWidget target with **Target
   Membership = HelmWidget only**:
   `HelmWidgetBundle.swift`, `NextShiftWidget.swift`, `ShiftLiveActivity.swift`,
   `SnapshotStore.swift`, `WidgetSupport.swift`.
   Keep an Assets catalog if the template added one (for the widget's
   `containerBackground`); it's optional.

4. **Link HelmDomain to the widget.** HelmWidget target ▸ General ▸ Frameworks
   and Libraries ▸ **+** ▸ add **HelmDomain** (only that product). Do NOT add
   HelmCalendar/HelmParsing/CoreXLSX — the widget needs only HelmDomain.

5. **Widget entitlements + App Group.** Point the HelmWidget target's
   `CODE_SIGN_ENTITLEMENTS` build setting at the staged
   `HelmWidget/HelmWidget.entitlements` (or, via Signing & Capabilities, add
   App Groups → `group.Fusion-Studios.Helm` to the widget). The widget MUST be
   in the SAME App Group as the app.

6. **Live Activities plist.** The app's `Helm/Info.plist` already has
   `NSSupportsLiveActivities = YES`. Ensure the widget's Info.plist has its
   `NSExtension` → `NSExtensionPointIdentifier = com.apple.widgetkit-extension`
   (the staged `HelmWidget/Info.plist` already does). Adding
   `NSSupportsLiveActivities = YES` to the widget Info.plist too is fine.

7. **Build and verify (this is the part I, the other agent, could not do).**
   - Select an **iOS Simulator** (e.g. iPhone) and build the Helm scheme +
     the HelmWidget scheme. Resolve any code-sign / provisioning errors
     (usually: App Group not registered on the portal, or a bundle-id mismatch).
   - Confirm there are **no duplicate `ActivityAttributes` conformance** errors
     (the conformance is intentionally declared once in the app target and once
     in the widget target, both behind `#if os(iOS)`, on the shared HelmDomain
     `ShiftActivityAttributes` — that is correct; a THIRD generated copy is not).
   - Run the app, add a roster/shift, then add the **Helm "Next Shift" widget**
     to the Home Screen and confirm it shows the next shift / weekly hours.
   - (Optional) Trigger a current shift to see the Live Activity / Dynamic
     Island. macOS shows no widgets by design — verify on iOS.

8. **Report** exactly which build settings / files you changed, and paste the
   final successful build result. If anything in the staged Swift files doesn't
   compile against the current SDK, fix it minimally and note what you changed
   (the files target iOS 26 WidgetKit/ActivityKit APIs).

### Notes / gotchas
- The whole widget is iOS-only; macOS doesn't render it. All ActivityKit code is
  gated `#if os(iOS)` (ActivityKit *imports* on macOS but its APIs are
  macOS-unavailable — do not switch this to `#if canImport(ActivityKit)`).
- `Color(hex:)` lives in the app target, so the widget carries its own
  `Color(helmHex:)` in `WidgetSupport.swift` — keep it.
- Do not modify anything under `Helm/` or `HelmCore/` except
  `Helm/Helm.entitlements` (step 1). The app target auto-includes files under
  `Helm/` via a synchronized group, so never put widget files there.
