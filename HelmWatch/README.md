# HelmWatch (staged)

The **watchOS companion app + watch-face complications** for Helm. Like
`HelmWidget/` was, these files are **not yet in the Xcode project** — watch
targets must be created through the Xcode GUI. The iPhone side is already
live: `WatchBridge` pushes the shared `HelmSnapshot` to the paired watch over
WatchConnectivity on every data change (it silently no-ops until a watch app
is installed, so nothing breaks meanwhile).

## What the watch gets

- **App** (3 vertically-paged screens): On Now / Next Shift (live countdown),
  Today's shifts, Week gauge (worked vs scheduled hours, TBC badge).
- **Complications**: Next Shift (rectangular + inline) and Week Hours gauge
  (circular + corner) for the watch face.
- **Data path**: iPhone `SnapshotWriter` → `WatchBridge`
  (`updateApplicationContext`, latest-state semantics) → watch `PhoneLink`
  stores the blob → app renders it; complications read the same stored blob.
  No CloudKit required; works offline once synced.

## One-time setup in Xcode (mirror of the HelmWidget flow)

Use `XCODE_AGENT_PROMPT.md` in this folder with the in-Xcode Claude agent, or
by hand:

1. **Create the watch app target.** *File ▸ New ▸ Target… ▸ watchOS ▸ App*.
   - Product name: **HelmWatch**; check **"Watch App for Existing iOS App"**
     (companion to Helm). Bundle id must be
     `Fusion-Studios.Helm.watchkitapp` (Xcode derives it). Team `8RUSX2C6R9`.
   - Include a **Widget Extension** when offered, or add one after: *File ▸
     New ▸ Target… ▸ watchOS ▸ Widget Extension*, name **HelmWatchComplications**.
2. **Match build settings to the verification done here**: both watch targets
   should have `SWIFT_VERSION = 6.0`, `SWIFT_DEFAULT_ACTOR_ISOLATION =
   MainActor`, `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`
   (the staged code was typechecked against the watchOS SDK with exactly
   these flags).
3. **Link HelmDomain** to BOTH watch targets (General ▸ Frameworks ▸ + ▸
   HelmDomain — only that product).
4. **Swap in the staged sources.**
   - Watch APP target: delete the generated stubs; add `HelmWatchApp.swift`,
     `PhoneLink.swift`, `WatchRootView.swift` (Target Membership: HelmWatch
     only).
   - Watch WIDGET target: delete its generated stubs; add
     `Complications/HelmWatchComplications.swift` (membership:
     HelmWatchComplications only).
5. **App Group** on BOTH watch targets: Signing & Capabilities ▸ + App Groups
   ▸ `group.Fusion-Studios.Helm` (the staged `HelmWatch.entitlements` shows
   the expected shape; point both targets' `CODE_SIGN_ENTITLEMENTS` at copies
   of it or let Xcode manage). Without it the app still works — complications
   then rely on the standard-defaults fallback, which works only if watchOS
   grants the extension that store; the App Group is the reliable channel.
6. **Build & run** the HelmWatch scheme on a watch simulator paired with the
   iPhone simulator running Helm. Open Helm on the iPhone (any data change
   pushes the snapshot), then check the watch app + add the complications.

## Verification status

- Staged watch sources **typecheck against the watchOS SDK** (Swift 6,
  MainActor default isolation, MemberImportVisibility) with HelmDomain built
  for watchOS — done in the dev environment on every change.
- What can't be verified outside Xcode: target creation/signing, WatchConnectivity
  runtime pairing, complication gallery rendering. That's steps 1–6 above.
