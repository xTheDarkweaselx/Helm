# HelmWidget (staged)

These files are the **WidgetKit + Live Activity** extension for Helm. They are
**not yet in the Xcode project** — a widget extension target must be created
through the Xcode GUI (hand-editing `project.pbxproj` for a new app-extension
target is error-prone and can't be verified without building). The app already
ships the write side: `SnapshotWriter` publishes a `HelmSnapshot` to the App
Group, and it **no-ops safely** until the App Group is configured, so the app
builds and runs today without this extension.

## One-time setup in Xcode

1. **App Group on the app.** Select the **Helm** target → *Signing &
   Capabilities* → **+ Capability** → **App Groups** → add
   `group.Fusion-Studios.Helm`. (This also un-parks the entry documented in
   `Helm/Helm.entitlements`.)

2. **Create the widget target.** *File ▸ New ▸ Target… ▸ Widget Extension*.
   - Product name: **HelmWidget**
   - **Include Live Activity: ✓**
   - Team: `8RUSX2C6R9`; bundle id will be `Fusion-Studios.Helm.HelmWidget`.

3. **App Group on the widget.** Select **HelmWidget** → *Signing &
   Capabilities* → **+ App Groups** → add the SAME `group.Fusion-Studios.Helm`.

4. **Link HelmDomain to the widget.** **HelmWidget** → *General ▸ Frameworks and
   Libraries* → **+** → add **HelmDomain** only (it carries `HelmSnapshot`,
   `SnapshotShift`, `ShiftActivityAttributes`).

5. **Swap in these files.** Delete the auto-generated widget Swift files, then
   drag the files in this folder into the HelmWidget group with **Target
   Membership = HelmWidget** (only):
   `HelmWidgetBundle.swift`, `NextShiftWidget.swift`, `ShiftLiveActivity.swift`,
   `SnapshotStore.swift`, `WidgetSupport.swift`.
   Point the widget target's `CODE_SIGN_ENTITLEMENTS` at the provided
   `HelmWidget.entitlements`, and merge the keys from this folder's `Info.plist`
   (notably `NSSupportsLiveActivities`).

6. **Live Activities on the app.** Add `NSSupportsLiveActivities = YES` to the
   **main Helm target**'s Info.plist too (the app starts the activity).

7. **Build & run** on an iOS device/simulator, add the widget, and trigger a
   current shift to see the Live Activity. (macOS shows no widgets by design.)

## How data flows

```
app: SnapshotWriter.refresh ──JSON──▶  group container file
                              └defaults▶ UserDefaults(suiteName:)
widget: SnapshotStore.load ◀───────────┘   → NextShiftWidget / timeline
app: LiveActivityController.sync ──▶ ActivityKit ──▶ ShiftLiveActivity (here)
```

Everything reads the shared `HelmSnapshot`, so the widget, the dashboard and
Siri always agree (one `NextShiftRule`).
