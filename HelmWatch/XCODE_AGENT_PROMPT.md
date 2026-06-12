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
mirrors exactly how the `HelmWidgetExtension` target was wired earlier (that
worked; its lessons are baked into the gotchas below).

## ⚠️ Critical don'ts (learned the hard way)

- **NEVER add `watchos` to the Helm app target's `SUPPORTED_PLATFORMS` or
  change its Base SDK.** The developer has already seen Xcode's dialog
  suggesting exactly that ("…doesn't match Helm's supported platforms — you
  can change Base SDK or Supported Platforms…") after picking a watch
  simulator as the destination for the *Helm* scheme. That dialog's advice is
  wrong for a companion app: the watch app is its OWN target and scheme. The
  iOS/macOS app's platform list must stay exactly as it is.
- **The New-Target wizard may clobber staged files.** When the
  HelmWidgetExtension target was created, the template OVERWROTE the staged
  bundle file and Info.plist and dropped in stub sources. If you name the
  target `HelmWatch` and point it at the existing repo-root folder, expect the
  same. Recovery is cheap and mandatory: after target creation run
  `git status` — if anything under `HelmWatch/` shows as modified, restore the
  staged code with `git checkout -- HelmWatch/` (or per-file), THEN delete the
  template's extra stub files from the target and disk.
- **Keep exactly ONE `@main` per target** (the staged
  `HelmWatchApp.swift` for the app; the staged
  `Complications/HelmWatchComplications.swift` for the widget extension —
  delete every generated stub, especially any generated `*Bundle.swift` or
  `*Attributes.swift`).

## Context

- The iPhone app already pushes a `HelmSnapshot` JSON blob to the watch via
  WatchConnectivity (`Helm/Widgets/WatchBridge.swift`, applicationContext key
  `HelmAppGroup.watchSnapshotContextKey`; it re-sends on activation, so the
  first sync after launch arrives without any watch-side action). The watch
  side receives it in `HelmWatch/PhoneLink.swift` (validates/decodes BEFORE
  persisting; drops out-of-order deliveries).
- Shared data types AND the render-time rules live in the **HelmDomain**
  library of the local SwiftPM package `HelmCore` (already in the project).
  As of v7.5 the staged watch code calls `SnapshotMath` / `DayKey` /
  `HelmSnapshot` from HelmDomain — **linking HelmDomain to BOTH watch targets
  is mandatory or nothing compiles.**
- Staged files (all re-typechecked against the watchOS 26 SDK after the v7.5
  hardening pass, with the exact flags in step 2):
  - Watch APP: `HelmWatch/HelmWatchApp.swift`, `HelmWatch/PhoneLink.swift`,
    `HelmWatch/WatchRootView.swift`
  - Watch WIDGET extension: `HelmWatch/Complications/HelmWatchComplications.swift`
    (contains its own `@main` WidgetBundle)
  - `HelmWatch/HelmWatch.entitlements` (the App Group shape both targets need)
  - `HelmWatch/README.md` / this file — documentation, not target members.

## Identifiers / settings (exact)

- Watch app target name: **HelmWatch**; companion of `Fusion-Studios.Helm`;
  bundle id `Fusion-Studios.Helm.watchkitapp` (Xcode derives it — verify).
- Watch widget extension: **HelmWatchComplications**, a child bundle of the
  watch app's bundle id.
- Team `8RUSX2C6R9`, Automatic signing, App Group `group.Fusion-Studios.Helm`
  on BOTH watch targets.
- Both watch targets: `SWIFT_VERSION = 6.0`,
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
  `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` — these match how
  the staged code was verified; divergence will surface as concurrency or
  member-visibility errors that are NOT bugs in the staged code.

## Steps

1. **Create the watch app target**: File ▸ New ▸ Target ▸ watchOS ▸ **App**,
   name **HelmWatch**, check **"Watch App for Existing iOS App"** so it
   companions `Fusion-Studios.Helm`. If the wizard offers a widget extension,
   accept and name it **HelmWatchComplications**; otherwise create it after
   via File ▸ New ▸ Target ▸ watchOS ▸ Widget Extension.
2. **Immediately run `git status`.** Restore any clobbered staged files
   (`git checkout -- HelmWatch/`) and note what the template generated.
3. **Apply the build settings** from the Identifiers section to BOTH watch
   targets.
4. **Link HelmDomain** (only that product) to BOTH watch targets via
   General ▸ Frameworks, Libraries and Embedded Content.
5. **Wire the staged sources.**
   - HelmWatch app target: delete the template's generated Swift files (disk
     + target); add the three staged app files with Target Membership =
     HelmWatch only.
   - HelmWatchComplications target: delete its generated Swift files; add
     `HelmWatch/Complications/HelmWatchComplications.swift` with membership =
     HelmWatchComplications only.
6. **App Groups** capability on BOTH watch targets:
   `group.Fusion-Studios.Helm` (same container as the iPhone app + widget;
   `HelmWatch/HelmWatch.entitlements` shows the expected shape — point
   `CODE_SIGN_ENTITLEMENTS` at it or let Xcode manage equivalent files).
   Without it the watch APP still works; the complications then depend on the
   standard-defaults fallback, so the App Group is the reliable channel.
7. **Build** the **HelmWatch scheme** for a watch simulator. Fix
   signing/provisioning errors (usually App Group registration or bundle-id
   hierarchy). Do not touch the Helm target to make the watch build.
8. **Runtime check**: run **Helm scheme → iPhone simulator** and
   **HelmWatch scheme → paired watch simulator** (Xcode pairs companion sims
   automatically; if the watch sim shows "unavailable", the watchOS runtime
   needs installing under Xcode ▸ Settings ▸ Components). In Helm,
   import/modify a roster → the watch app should show the next shift within
   seconds. Add the "Next Shift" and "Week Hours" complications to a watch
   face and confirm they render.
9. **Report** every build-setting/file change and paste the final build
   result. If a staged file needs a minimal SDK fix, make it and note it
   explicitly — flag any scope deviation the way the HelmWidget run did.

### Gotchas (carried over from the HelmWidget wiring + v7.5)
- The repo-root `HelmWatch/` folder is deliberately OUTSIDE the `Helm/`
  synchronized group — never add these files to the iOS/macOS app target.
- WCSession delegate callbacks arrive on a background queue — the staged code
  declares those witnesses `nonisolated` and hops to MainActor via
  `Task { @MainActor in … }`; don't "fix" that, it's the Swift 6 pattern.
- If complications show placeholders only: the watch APP must run once first
  (PhoneLink stores the snapshot the complications read), and the App Group
  must be on BOTH watch targets.
- End state for the developer: **Helm scheme runs on iPhone/Mac destinations
  only; HelmWatch scheme runs on watch destinations only.** If a watch
  simulator is selected for the Helm scheme, Xcode shows the
  platform-mismatch dialog — that is expected and not an error to "fix".
