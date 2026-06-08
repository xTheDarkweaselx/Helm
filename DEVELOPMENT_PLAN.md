# Helm — Development Plan

> An Apple multiplatform app that imports a complicated work‑shift roster (usually an Excel
> spreadsheet) and pushes it, seamlessly, into the user's calendar of choice.
>
> **Status:** planning · **Branch:** `develop` · **Last updated:** 2026‑06‑08
> **Target OS:** iOS / iPadOS / macOS / visionOS 26.5 · **Toolchain:** Xcode 26, SwiftUI + SwiftData, Swift 6

This plan is grounded in a multi‑agent research pass (EventKit, provider strategy, Google Calendar,
Excel ingestion, CloudKit + SwiftData, shift domain modelling, import UX, multiplatform architecture)
plus an adversarial review. Where a claim is load‑bearing but only *medium* confidence, it is called
out as a **spike** to validate before we build on it.

---

## 0. Confirmed product decisions

These were decided up front because each one changes the architecture:

| Decision | Choice | Consequence |
|---|---|---|
| **Sharing model** | Personal now, **keep a seam** | v1 = each person's roster is private and syncs across *their own* Apple devices via SwiftData + private CloudKit. All persistence sits behind a `RosterStore` protocol so team sharing (Core Data + `CKShare`) can be added later without rewriting import/UI. |
| **Calendar destinations** | Apple (EventKit) + `.ics` export **+ direct Google sign‑in in v1** | EventKit is the spine (also writes to Google/Exchange accounts already on the device). `.ics` is the universal fallback. Direct Google API is layered behind the same protocol — **gated on Google's sensitive‑scope verification** (see §9). |
| **First‑class platforms** | **iPhone, iPad, Mac** | visionOS stays compiling but is not a design/test focus for v1. |
| **v1 extras (all in)** | Shift reminders/alarms · saved one‑tap re‑import · in‑app rotation builder · background auto‑update | All four are in v1 scope. Because that's a lot, v1 is split into sub‑phases (§8). Idempotent re‑import (no duplicates) is core regardless. |

**Still needed from you (highest‑value input):** 5–10 *real, anonymised* roster spreadsheets in
the formats you actually receive. Format variability (grid vs list, colour‑coded shifts, separate
legends, locale dates, one‑sheet‑per‑month) is the #1 schedule risk and the thing that decides whether
"seamless" is achievable. Drop them in `Fixtures/Rosters/` (see §11).

---

## 1. Vision & success criteria

**Vision.** A nurse, pilot, factory worker, or anyone on a rotating roster opens Helm, picks the Excel
file HR sent them, taps through a short (often one‑tap) confirmation, and their shifts — correct times,
overnight crossings, breaks, the lot — appear in Apple Calendar (and/or Google). Next month they get an
updated sheet, tap "re‑import", and Helm updates the calendar **in place with zero duplicates**.

**v1 is a success when** a non‑technical user can:
1. Import a real rotating‑roster `.xlsx` on iPhone, iPad, or Mac.
2. Confirm only the things Helm couldn't infer (unknown shift codes, "which row is me").
3. See a clear preview, then write to Apple Calendar (and a Google account added on‑device, or via direct Google sign‑in).
4. Re‑import a changed file and see an **add / update / remove** diff — no duplicates, manual edits preserved.
5. Get a reminder before their next shift, and have it all sync across their own devices.

**Non‑negotiable quality bars:** correct dates/times across DST and overnight; idempotent re‑import;
no launch crash without an iCloud account; on‑device parsing (the spreadsheet never leaves the device
except via the destination the user explicitly chooses).

---

## 2. Architecture decisions (ADRs)

Condensed, opinionated, and adjusted for the decisions in §0. Format: **Decision — Why — Rejected.**

### ADR‑1 · Layered calendar targets behind one `CalendarTarget` protocol
EventKit (full access) is the primary write path and ships first; a spec‑correct `.ics` exporter is the
universal fallback; **direct Google Calendar API is included in v1 but layered last**, behind the same
protocol. *Why:* a Google/Exchange account added in iOS/macOS Settings already surfaces in EventKit as a
writable `EKSource`, so most "Apple OR Google" cases need zero OAuth; the protocol lets us add the direct
Google adapter without touching the import pipeline; `.ics` covers Android/Outlook/web and sharing.
*Rejected:* Google‑only or `.ics`‑only as primary; `EKEventEditViewController` as primary (absent on
native macOS, doesn't scale to a year of shifts).

### ADR‑2 · Request EventKit **full** access (not write‑only)
*Why:* Helm's core promise is idempotent re‑import, which requires reading back previously‑created events
to update/remove them and letting the user pick a calendar — **write‑only access blocks all reads** and
would duplicate the whole roster every time. *Rejected:* write‑only (cannot dedupe, cannot clean up,
cannot pick a calendar). Add `NSCalendarsFullAccessUsageDescription` + legacy `NSCalendarsUsageDescription`
fallback; on sandboxed macOS also add the Calendar personal‑information entitlement.

### ADR‑3 · Own idempotency with a local ledger; never trust calendar‑side UIDs
Persist a SwiftData ledger mapping a deterministic
`shiftKey = hash(importProfileID + personID + localDate + normalizedCode)` →
`{eventIdentifier, contentHash, status, target}`. Also stamp `event.url = helm://roster/<id>/shift/<hash>`,
a hidden marker in `event.notes`, and (Google) `extendedProperties.private[helmKey]`.
*Why:* EventKit won't let apps set a UID; `calendarItemExternalIdentifier` is read‑only, non‑unique, and
per‑device; Apple Calendar's *file* import ignores UID and duplicates on re‑import. The ledger is the only
robust dedupe and it powers the diff + "undo last import". *Rejected:* `.ics` UID round‑tripping (works on
Google, fails on Apple); `calendarItemExternalIdentifier` as the key.

### ADR‑4 · Materialise shifts as concrete dated instances; recurrence rules only for genuinely regular cases
Expand rotations into individual `ShiftInstance` rows and push those. Use `EKRecurrenceRule`/`RRULE` only
for truly regular patterns (e.g. fixed Mon–Fri 09:00–17:00). *Why:* RFC 5545 frequencies are
calendar‑aligned (DAILY/WEEKLY/MONTHLY); 4‑on‑4‑off, N‑week rotations, and per‑week varying times/titles
**cannot** be expressed as one rule and would silently produce wrong dates. Materialisation also makes
per‑shift dedupe/edit/cancel/diff tractable. *Rejected:* RRULE‑as‑primary.

### ADR‑5 · Store wall‑clock + IANA time zone; derive UTC; model overnight via an end‑day offset
Templates hold `startMinuteOfDay`/`endMinuteOfDay` (may exceed 1440) **or** an `endDayOffset`; instances
hold `localDate` + `timeZoneIdentifier` and cache derived `startUTC`/`endUTC`. Overnight shifts are
ordinary *timed* events whose `endDate` is the next day; `EKEvent.timeZone` is always set explicitly.
Paid hours = UTC delta − breaks. *Why:* human intent ("Late starts 14:00") is the source of truth and must
survive DST and travel; UTC‑only discards intent; naive local subtraction breaks duration math (a fall‑back
night is 9h, not 8h); all‑day events lose the times. *Rejected:* UTC‑only; all‑day modelling of timed
shifts; local‑clock subtraction.

### ADR‑6 · SwiftData + private CloudKit for v1; persistence behind a `RosterStore` protocol
Single‑user, all‑devices sync via SwiftData + `.private("iCloud.Fusion-Studios.Helm")`. Wrap all
persistence behind a protocol so a future migration to `NSPersistentCloudKitContainer` (for team sharing)
doesn't touch import/UI. *Why:* SwiftData has **no native `CKShare`/shared/public‑DB support** even in the
OS 26 generation; for single‑user multi‑device it's the lowest‑effort correct choice; the protocol seam
de‑risks the sharing future you asked us to preserve. *Rejected:* Core Data from day one (over‑engineering
a maybe‑feature); hand‑rolled `CKShare` on SwiftData (fragile, undocumented).

### ADR‑7 · Vendor/fork CoreXLSX; build a Helm‑owned date resolver; normalise every format into one grid
Adopt **CoreXLSX (Apache‑2.0)** for `.xlsx` but **vendor/fork** it (it's dormant since 2023, Swift 5.1,
not `Sendable`). Keep XMLCoder + ZIPFoundation as live SwiftPM deps. Build a **Helm date resolver** that
reads `date1904`, gates on `numFmtId`/format codes, and converts via the correct epoch
(1899‑12‑30 or 1904‑01‑01) with a fixed time zone. Use TabularData / CodableCSV for CSV. Every parser
emits the same `SpreadsheetGrid`. *Why:* CoreXLSX is the only viable pure‑Swift on‑device `.xlsx` reader,
but its `dateValue` ignores `date1904` and number formats — the #1 silent data‑corruption risk; a normalised
grid decouples brittle parsing from roster interpretation and makes fixture testing trivial. *Rejected:*
upstream CoreXLSX unmodified (toolchain + date risk); parsing `.numbers` directly (WorkKit is AGPL‑3.0,
App‑Store‑incompatible → ask users to export CSV/`.xlsx`); naive `.xls` (no Swift lib → detect by magic
bytes, guide a re‑save).

### ADR‑8 · One app target + a local SwiftPM package (`HelmCore`)
App target = SwiftUI shell + `@Model` types. Local package targets: `HelmDomain` (pure value types),
`HelmParsing` (grid → `[ParsedShift]` DTOs), `HelmCalendar` (`CalendarTarget` protocol + EventKit/ICS/Google
adapters). `#if os()` only at thin UI seams. *Why:* package targets build and unit‑test headlessly without
launching the app; pure parsing/domain stays platform‑neutral and `nonisolated`. *Rejected:* per‑platform
targets; monolithic app target (slow builds, untestable core).

### ADR‑9 · `@ModelActor` for writes; pass `PersistentIdentifier` across actors; parse off‑main
Parse spreadsheets off‑main (`@concurrent`) into `Sendable [ParsedShift]`; hand them to a `@ModelActor`
that inserts/dedupes/saves and returns `[PersistentIdentifier]`; UI re‑fetches by ID on `@MainActor`.
*Why:* `@Model` instances aren't `Sendable`; `PersistentIdentifier` is; heavy XLSX decode on the main actor
janks the UI. Note: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is **already set** in the project, so parse
code is implicitly main‑isolated *today* and must be deliberately offloaded. *Rejected:* writes on
`@MainActor`; passing `@Model` across actors (data race).

### ADR‑10 · Replace the template's `fatalError` ModelContainer init with a graceful local‑only fallback
On container‑init failure (CloudKit misconfig, schema mismatch, corrupt store, no iCloud account), log and
fall back to a local‑only `ModelConfiguration` so import + calendar export still work. *Why:* a CloudKit
rule violation or an account‑less device would otherwise hard‑crash on launch. *Rejected:* default
`fatalError`.

### ADR‑11 · Saved "import recipe" + security‑scoped bookmark for one‑tap re‑import
After the first successful import, persist a recipe (source bookmark/fingerprint, sheet, layout, header
location, date axis, "me"‑row identity, code→template map). **Copy the picked file into the app container
immediately** and store a security‑scoped bookmark. *Why:* "seamless" means the second import is one tap;
security‑scoped URLs expire, so the file must be copied + bookmarked or replay fails. *Rejected:* re‑running
the full wizard monthly; holding the original sandbox URL.

### ADR‑12 · `NavigationSplitView` shell on all platforms; import as a sheet‑presented wizard
Replace the hand‑rolled `#if os(macOS)` wrapper with a real `NavigationSplitView` (sidebar = rosters/sources,
detail = shift list); drive the multi‑step import with a `WizardStep` state machine in a sheet. *Why:*
`NavigationSplitView` auto‑collapses to a stack on iPhone and renders glass sidebars on macOS — exactly the
cross‑platform adaptation needed, no per‑platform branches. *Rejected:* per‑platform nav; deprecated
`NavigationView`.

### ADR‑13 · Adopt Liquid Glass via SDK recompile; explicit glass only on custom wizard chrome
Toolbars/sidebars/tab bars/sheets get glass automatically on the Xcode 26 SDK; use
`.glassEffect`/`GlassEffectContainer`/`.buttonStyle(.glass)` only on custom floating wizard controls; never
set `UIDesignRequiresCompatibility`; keep glass off the shift‑list content layer (contrast). *Rejected:*
hand‑styling all chrome; shipping the compatibility flag; glass on content.

### ADR‑14 · Direct Google via OAuth Auth‑Code + PKCE through `ASWebAuthenticationSession`
For the direct Google adapter, do **not** use the GoogleSignIn SDK (no visionOS support, heavier dep). Use
the OAuth 2.0 Authorization‑Code + PKCE flow via `ASWebAuthenticationSession`, scope `calendar.events`,
tokens in the Keychain (device‑only). *Why:* portable across all four platforms, no third‑party SDK, minimal
scope. *Rejected:* GoogleSignIn SDK (platform gap); implicit flow (deprecated/insecure).

---

## 3. Domain & data model (SwiftData, CloudKit‑safe)

**CloudKit rules applied to every entity:** every attribute optional **or** defaulted · **no
`@Attribute(.unique)`** (uniqueness enforced in code via fetch‑by‑key‑then‑upsert) · relationships optional
with explicit inverses · **no ordered relationships** (use `sortIndex: Int`) · no `.deny` delete rule · enums
stored as raw `String`/`Int` with defaults · IDs app‑generated. **Schema evolution is add‑only.**

### Abstract layer (templates & patterns)
- **`UserProfile`** — `id`, `displayName?`, `nameAliases: [String]?` (for "which row is me"). → `rosters`, `assignments`, `importProfiles`.
- **`ShiftType`** (named template) — `id`, `code?`, `label?`, `startMinuteOfDay = 0`, `endMinuteOfDay = 0` (may exceed 1440) **or** `endDayOffset = 0`, `breakMinutes = 0`, `paid = true`, `paidHoursOverride?`, `workKind = "worked"` (worked/onCall/standby/off/leave), `colorHex?`, `locationName?`, `defaultTimeZoneID?`, `defaultAlarmOffsets: [Int]?` (reminders). ← `instances`.
- **`RotationPattern`** — `id`, `name?`, `cycleLengthDays = 7`. → `slots`. *(In v1 because of the in‑app rotation builder.)*
- **`RotationSlot`** — `id`, `sortIndex = 0` (cycle position), `shiftType?` (nil = OFF). ← `pattern`.
- **`RotationAssignment`** — `id`, `anchorDate?` (cycle Day‑1), `dayOffset = 0`, `effectiveFrom?`, `effectiveTo?`, `timeZoneIdentifier?`. → `user`, `pattern`.

### Materialised layer (what gets pushed to a calendar)
- **`Roster`** — `id`, `title?`, `createdAt = .now`, `sourceImportProfileID?`. → `user`, `instances`.
- **`ShiftInstance`** — `id`, `localDate?` (date‑only in shift tz), `timeZoneIdentifier = TimeZone.current.identifier`, `startUTC?`/`endUTC?` (cached), `computedPaidHours?`, `overrideKind = "none"` (none/modified/cancelled/added/swapped), `originalDate?`, `originalShiftTypeCode?`, **`dedupKey?`**, `sortIndex = 0`. → `shiftType`, `roster`, `segments`, `syncRecords`.
- **`ShiftSegment`** (split shifts) — `id`, `sortIndex = 0`, `startMinuteOfDay = 0`, `endMinuteOfDay = 0`. ← `instance`.

### Import & sync bookkeeping
- **`ImportProfile`** (employer/source recipe) — `id`, `name?`, `sourceBookmark: Data?`, `sourceFingerprint?`, `sheetName?`, `layoutKind?` (list/matrix), `headerRowIndex?`, `dateAxis?`, `dateLocaleID?`, `firstDayOfWeek?`, `meRowIdentity?`, `lastImportedAt?`. → `user`, `codeMappings`, `runs`.
- **`ShiftCodeMapping`** — `id`, `rawCode?` (normalised: upper/trim), `shiftType?`, `confidenceLastConfirmed?`. ← `importProfile`.
- **`ImportRun`** — `id`, `ranAt = .now`, `addedCount/changedCount/removedCount/skippedCount = 0`. ← `importProfile`; → `syncRecords` (batch undo).
- **`CalendarSyncRecord`** (the idempotency ledger) — `id`, `shiftKey?` (== `ShiftInstance.dedupKey`), `target?` (eventkit/google/ics), `calendarIdentifier?`, `eventIdentifier?`, `externalEventID?`, `contentHash?`, `status = "pending"` (pending/written/confirmed/failed/deleted), `importRunID?`. ← `shiftInstance`.

---

## 4. End‑to‑end import pipeline

1. **Intake.** One "Import roster" button → `.fileImporter(allowedContentTypes: [.spreadsheet, .commaSeparatedText, xlsx, xls, numbers])` + `.dropDestination` (macOS/iPad) + "Open in Helm" document types. On pick: `startAccessingSecurityScopedResource()`, **copy file into the app container**, store a security‑scoped bookmark, then stop.
2. **Format detection** — UTType **plus magic‑byte sniffing**: `.xlsx` = ZIP (`PK\x03\x04`) with `[Content_Types].xml`; `.xls` = OLE2 (`D0 CF 11 E0 A1 B1 1A E1`) → friendly "re‑save as `.xlsx`/CSV"; CSV/TSV by content. Never trust the extension. Cap decompressed size/entry count (zip‑bomb guard).
3. **Parse → normalised grid (off‑main, `@concurrent`).** Format‑specific extractor → one `SpreadsheetGrid`. Resolve shared strings; **apply the Helm date resolver** (`date1904`, `numFmtId`/format codes, correct epoch, fixed tz); propagate merged‑cell values; index by `CellReference` (not array position) so blanks don't misalign.
4. **Layout auto‑detection.** Header row = most distinct non‑numeric strings. Date axis = row/column with the highest date‑parse ratio (also disambiguates list vs matrix). Shift‑code cells = short repeated tokens. Pre‑select "me" by matching `UserProfile.nameAliases`. Infer/confirm date **locale** and **first‑day‑of‑week**. Attach a confidence score per detection.
5. **Wizard (progressive disclosure — only ask when confidence is low).** (1) sheet pick (skip if one) → (2) confirm layout/header/date axis + date locale over a live highlighted grid → (3) confirm "which row is me" → (4) **map only unknown codes**, each with a fuzzy‑suggested `ShiftType` + "create template" → (5) preview. Always offer a raw‑grid manual‑mapping fallback — never dead‑end.
6. **Resolve to instances.** For each (person, date) cell: normalise code → `ShiftCodeMapping` → `ShiftType` → emit a candidate `ShiftInstance` (compute `startUTC`/`endUTC`/paid hours from wall‑clock + tz, applying the documented spring‑forward/fall‑back policy). Compute `dedupKey`.
7. **Diff + preview.** Compare candidates against the ledger: new key = **ADD**, same key + changed `contentHash` = **UPDATE**, missing key = **REMOVE**. **Preserve any `ShiftInstance` with `overrideKind != none`** (user swaps/edits never clobbered). Show a plain‑language summary ("Add 18, update 2, remove 1, skip 1") with per‑skip reasons.
8. **Persist (via `@ModelActor`).** Upsert by `dedupKey` (fetch‑then‑update). Record an `ImportRun`. Return `[PersistentIdentifier]`.
9. **Calendar write (via `CalendarTarget`).** Ensure the dedicated `EKCalendar` ("Helm Shifts") on the iCloud source (fallback `.local`). Batch `save(_:span:commit:false)` per event then one `commit()`. Stamp `event.url` + notes marker + explicit `event.timeZone` + `EKAlarm`s from the shift type. Store `eventIdentifier` in the ledger; mark `confirmed`. (Google direct: `events.insert` with a client‑generated id + `extendedProperties.private[helmKey]`.)
10. **Save recipe + offer undo.** Persist/refresh the `ImportProfile`. Expose "Re‑import <month> roster" on the home screen and "Undo last import" (delete exactly the latest `ImportRun`'s `CalendarSyncRecord`s). `BGAppRefreshTask`/`BGProcessingTask` re‑runs steps 6–9 against the bookmarked source (background auto‑update).

---

## 5. The genuinely hard part: semantic extraction

File‑format reading is solved; **understanding a messy real roster is not.** These must be designed, not
hand‑waved (each surfaced by the adversarial review):

- **Person identification** in a multi‑person grid — inconsistent names (initials, "A.Ibrahim", payroll IDs); some rosters list crews not people. Plan: alias list + fuzzy match + an explicit "my name appears as…" step; support "pick my row manually".
- **Missing legend** — code→time legend often lives in a separate email/doc/tribal knowledge. Plan: cold‑start flow that lets the user define an unknown code's times once, remembered per `ImportProfile`.
- **Non‑code cells** — `"L (swap w/ Jo)"`, `"08‑16"`, `"Off ½"`, **colour‑only encoding** (shift type conveyed by fill colour — CoreXLSX can read styles), strikethrough = cancelled. Plan: tokeniser that extracts inline times, recognises annotations, and optionally reads cell fill as a signal (later sub‑phase).
- **Multi‑month / merged‑title workbooks** — one sheet per month, or month/year in a merged title cell rather than per‑date. Plan: per‑sheet detection + title‑cell month inference.
- **Locale dates & first‑day‑of‑week** — `03/04/2026` is March or April by locale; matrix columns depend on Mon‑ vs Sun‑first. Plan: infer, then **confirm in the wizard** rather than silently guess (prevents the worst silent‑corruption class — shifts on the wrong day).
- **Republished roster (v2 of June)** — recognise "this file is a newer version of that roster" via `sourceFingerprint`, then diff against the prior import, not a fresh insert.
- **Human‑vs‑Helm edits** — user drags a Helm event in Calendar. Policy needed: detect divergence (content hash mismatch on the calendar side) and prompt rather than blindly overwrite.
- **Cleanup / uninstall** — provide "Remove all Helm shifts" (enumerates the dedicated calendar) so uninstalling doesn't orphan events forever.
- **Account disappears** — user removes the Google account from Settings → the `EKCalendar` and events vanish, ledger points at dead ids. Detect and offer re‑write.

---

## 6. Platform & UI architecture

- **Shell:** `NavigationSplitView` everywhere (sidebar: rosters/sources; detail: shift list/calendar view). Auto‑adapts iPhone→stack, Mac/iPad→columns.
- **Import wizard:** sheet‑presented `WizardStep` state machine; adapts to phone (full‑screen steps) vs Mac/iPad (roomier).
- **Liquid Glass:** automatic on chrome via SDK recompile; explicit glass only on custom wizard floating controls.
- **Concurrency:** parse off‑main (`@concurrent`), write via `@ModelActor`, UI on `@MainActor` re‑fetching by `PersistentIdentifier`. Move project to **Swift 6 language mode** (currently Swift 5 with `MainActor` default isolation already on).
- **macOS specifics:** EventKitUI's editor is unavailable → ship a **SwiftUI‑native calendar picker** from `EKEventStore.calendars(for: .event)`. Add the App Sandbox Calendar entitlement; **link `CloudKit.framework`** on the macOS target.
- **visionOS:** keeps compiling; not a design/test target for v1.
- **Reminders:** `EKAlarm`s on events + optional independent `UNUserNotificationCenter` notifications (so reminders work even if the user hides the Helm calendar). Per‑`ShiftType` default offsets, editable.
- **Background auto‑update:** `BGAppRefreshTask` (light re‑check) + `BGProcessingTask` (heavier re‑materialise) re‑running the pipeline against the bookmarked source; bounded materialisation horizon (see §10 risk 7).
- **Testing:** Swift Testing for `HelmParsing`/`HelmDomain` with a fixtures corpus (real + adversarial); a thin set of UI tests for the wizard happy path.

---

## 7. De‑risking spikes (do these before building abstractions)

Run **Spike 1 & 2 first** — they're go/no‑go gates on the whole architecture.

1. **Google‑via‑EventKit reality check (½ day, FIRST).** On a physical iOS 26 device with a real Google account in Settings: enumerate `calendars(for:.event)`, log `allowsContentModifications` + `EKSource`, create a timed event with explicit `timeZone`, confirm it appears in Google Calendar web within minutes. *Gates the "one code path for Apple + Google" strategy.*
2. **CoreXLSX under Xcode 26 / Swift 6 / visionOS (½ day).** Add CoreXLSX to a throwaway package target; build for iOS, macOS, **and** visionOS sims; flip to Swift 6; parse a real `.xlsx` with dates, merged cells, a leading‑zero code, **and a deliberately 1904‑system file**. *Gates the parsing strategy (vendor/fork vs build‑your‑own).*
3. **EventKit full vs write‑only round‑trip + cleanup (½–1 day).** With full access: create "Helm Shifts" `EKCalendar`, batch‑write ~300 events (`commit:false` then one `commit()`), re‑fetch by predicate, update 10, delete 10, delete the calendar. *Validates idempotent re‑import + "remove all Helm shifts".*
4. **End‑to‑end thin slice on a real roster (1–2 days, after 1–3).** One actual employer sheet → parse → manual map → materialise (incl. an overnight shift across a DST boundary and one swap) → write → re‑import a *modified* copy → confirm the diff with no duplicates. *Proves the headline promise; surfaces semantic‑extraction problems.*
5. **SwiftData + CloudKit private sync incl. release path (½–1 day).** CloudKit‑legal model, `cloudKitDatabase: .private(...)`, populate the container array, **provision the container in the portal**, `initializeCloudKitSchema`, deploy schema to **Production**, verify sync across two devices **from a TestFlight build**, link `CloudKit.framework` on macOS. *The release/macOS‑link traps only appear here.*
6. **Locale date + matrix detection on adversarial fixtures (cheap, anytime).** US `MM/DD`, UK `DD/MM`, Mon‑first matrix, month‑in‑merged‑title workbook → confirm it infers correctly or *asks*, never silently guesses.
7. **Google OAuth + PKCE spike (½ day, before the v1.4 Google adapter).** `ASWebAuthenticationSession` auth‑code+PKCE → `calendar.events` token in Keychain → one `events.insert`. Confirm the redirect scheme + token refresh work on iOS/macOS.

---

## 8. Phased roadmap

Because Google‑direct and all four extras are in v1, v1 is split into shippable sub‑phases. Each phase has a
**Definition of Done (DoD)**.

### Phase 0 — Spikes & foundations (gate the architecture)
- Run Spikes 1, 2, 3, 5 (§7). Fix the scaffold: populate `iCloud.Fusion-Studios.Helm` in entitlements; set `cloudKitDatabase: .private(...)`; replace `fatalError` container init (ADR‑10); add calendar usage strings + macOS Calendar entitlement; add `PrivacyInfo.xcprivacy`; move to Swift 6 language mode; create the `HelmCore` package (`HelmDomain`/`HelmParsing`/`HelmCalendar`); replace the `Item`/`ContentView` template with a `NavigationSplitView` shell.
- **DoD:** all four spikes pass (or their failure has reshaped the plan); the app builds for iOS/iPadOS/macOS on Swift 6 with the package wired and no launch crash without iCloud.

### Phase v0 — Walking skeleton (prove the spine end‑to‑end)
- CSV‑only parser → `SpreadsheetGrid` → hardcoded list layout → `ShiftInstance` → EventKit full‑access write into "Helm Shifts" (no dedupe yet). `CalendarTarget` with one `EventKitTarget`. Swift Testing fixtures for the CSV parser.
- **DoD:** on iOS *and* macOS, pick a simple CSV → shifts appear in Apple Calendar; parser tests pass headlessly.

### Phase v1.0 — Robust import (the parsing core)
- Vendored/forked CoreXLSX `.xlsx` reader + Helm date resolver (`date1904` + number‑format detection); merged‑cell propagation; magic‑byte detection; `.xls` re‑save guidance. Full 5‑step wizard with auto‑detection (list **and** matrix), fuzzy code mapping, "which row is me", date‑locale/first‑day confirmation. Saved import recipe + security‑scoped bookmark (one‑tap re‑import). Off‑main parsing (`@concurrent`) + `@ModelActor` writes.
- **DoD:** a non‑technical user imports a real rotating `.xlsx`, confirms only unknown codes, and writes to Apple Calendar; a second import of the same format is one tap.

### Phase v1.1 — Idempotency, diff & sync
- `CalendarSyncRecord` ledger + add/changed/removed diff + preview + "undo last import" + "remove all Helm shifts". SwiftData + private CloudKit live (container provisioned, Production schema deployed, macOS framework linked). Overrides preserved on re‑import; republish (`sourceFingerprint`) handling; human‑vs‑Helm edit detection.
- **DoD:** re‑importing a changed file updates in place with **zero duplicates**, preserves manual swaps, and syncs across the user's own devices — verified from a TestFlight build.

### Phase v1.2 — Reminders + `.ics` export
- `EKAlarm` + `UNUserNotificationCenter` reminders with per‑`ShiftType` default offsets; spec‑correct `.ics` exporter (`VTIMEZONE`/`TZID`, stable UID, overnight DTEND‑next‑day) via the share sheet.
- **DoD:** a reminder fires before a shift; an exported `.ics` imports cleanly into Google/Outlook with correct overnight times.

### Phase v1.3 — In‑app rotation builder
- Author `RotationPattern`s (4‑on‑4‑off, multi‑week) with an `anchorDate`; expand over a bounded rolling horizon into `ShiftInstance`s that flow through the same diff/sync path; per‑instance overrides/swaps.
- **DoD:** a user builds a 4‑on‑4‑off pattern, it materialises correctly across a DST boundary, and edits/swaps survive re‑expansion.

### Phase v1.4 — Direct Google sign‑in + background auto‑update
- `GoogleAPITarget` behind `CalendarTarget`: OAuth auth‑code + PKCE via `ASWebAuthenticationSession`, `calendar.events` scope, Keychain tokens, `events.insert` with client id + `extendedProperties`. **Complete Google sensitive‑scope verification** (see §9) before public launch. `BGAppRefreshTask`/`BGProcessingTask` background re‑import against the bookmarked source.
- **DoD:** a user with no on‑device Google account connects Google directly and shifts appear; background refresh updates a changed roster without opening the app; Google verification submitted/approved.

### Later (post‑v1)
- Hosted **webcal feed** (per‑user opaque HTTPS `text/calendar`) for true auto‑subscribe. **Team sharing** → evaluate migrating the `RosterStore` to `NSPersistentCloudKitContainer` + `CKShare`. Rotation‑pattern *detection* from imported cells. Colour‑encoded‑shift reading. WidgetKit "next shift" + on‑call Live Activity. Employer roster‑template catalogue (public DB).

---

## 9. Privacy, App Store & legal (own this now, not at submission)

- **Calendar usage strings** — add review‑survivable, specific copy for `NSCalendarsFullAccessUsageDescription` (+ legacy `NSCalendarsUsageDescription`). Vague strings get rejected.
- **`PrivacyInfo.xcprivacy` manifest + Privacy Nutrition Label** — rosters reveal employer, work location, and inferable shift‑work/health patterns. Declare data use accurately; note that copying the file into the container + keeping a bookmark changes the data‑retention story. Cover **required‑reason APIs** (file‑timestamp/disk‑space during copy).
- **Google sensitive‑scope verification (blocker for public launch with direct Google).** `calendar.events` is a *sensitive* scope: until Google verifies the app it's **capped at 100 users** and shows a warning screen; verification needs a privacy policy, brand info, and a demo video, with an unpredictable timeline. Because EventKit already covers Google‑added‑on‑device, the direct adapter (v1.4) can ship to a limited audience while verification is pending — sequence accordingly.
- **Sign in with Apple** — if a third‑party login (Google) is ever the *only* sign‑in, App Store Guideline 4.8 requires an equivalent privacy‑preserving option. Helm's primary path is account‑less (EventKit), so this only bites if Google becomes a required login.
- **Demo account + sample spreadsheet** for App Review (needed once any auth/import path requires review).
- **Accessibility & localisation** — VoiceOver + Dynamic Type for the wizard and shift list (Liquid Glass transparency raises contrast concerns); locale‑aware date parsing is a *feature*, not just a pitfall.
- **Data ownership/export** — let users export their roster/shift data (GDPR‑friendly), distinct from `.ics`.

---

## 10. Top risks & mitigations

1. **Silent date corruption from CoreXLSX** (ignores `date1904` + number formats; 1462‑day shift on 1904 files). → Never call `Cell.dateValue`; build the Helm date resolver; validate with 1900‑ and 1904‑system fixtures (Spike 2).
2. **Duplicate‑on‑re‑import** if the ledger is lost or write‑only is used. → Full access (ADR‑2) + owned ledger (ADR‑3) + provider‑side stamps (`event.url`/`extendedProperties`) as recovery.
3. **CloudKit "works in Debug, dead in production"** (empty container array, undeployed Production schema, unlinked macOS framework, unprovisioned container). → Spike 5 + a release checklist; verify from TestFlight.
4. **Launch crash from `fatalError` + a CloudKit‑rule violation.** → Graceful local‑only fallback (ADR‑10); audit every `@Model` property against CloudKit rules in CI.
5. **DST / overnight duration errors.** → Wall‑clock + IANA tz, `endDayOffset`, paid hours from UTC delta; documented spring‑forward/fall‑back policy; surface DST‑affected shifts in the preview.
6. **Messy real layouts** (matrix vs list, merged cells, multi‑row headers, locale dates, colour encoding, separate legends). → Empirical detection + `CellReference` indexing + a show‑and‑confirm wizard with a raw‑grid manual fallback. **Needs real sample files to tune.**
7. **Horizon/scale** — a multi‑year materialised roster = thousands of `EKEvent`s/CloudKit records/Google calls. → Bounded rolling horizon (e.g. ±N months), background extension, paginate/batch, and document the cap.
8. **Google verification timeline** blocks public direct‑Google launch. → Ship EventKit/`.ics` first; run direct‑Google to a limited audience while verifying; start verification early in v1.4.
9. **CoreXLSX not Swift‑6/concurrency‑clean + main‑thread jank.** → Vendor/fork, add `Sendable`/isolation; parse off‑main (`@concurrent`); keep package targets `nonisolated`.
10. **Semantic extraction underestimated** (person ID, missing legend, non‑code cells). → Treat §5 as first‑class v1.0 work; gate the "seamless" claim on Spike 4 against real files.

---

## 11. Immediate next actions

1. **You:** drop 5–10 anonymised real roster files into `Fixtures/Rosters/` (and, if handy, the code→time legend for each). This unblocks the parser and the "seamless" tuning.
2. **Phase 0 scaffold fixes** (small, safe, high‑value — can start immediately):
   - `Helm/Helm.entitlements` — set `com.apple.developer.icloud-container-identifiers` to `iCloud.Fusion-Studios.Helm` (empty today).
   - `Helm/HelmApp.swift` — `cloudKitDatabase: .private("iCloud.Fusion-Studios.Helm")` + replace `fatalError` with a local‑only fallback (ADR‑10).
   - `Helm/Info.plist` — add `NSCalendarsFullAccessUsageDescription` (+ legacy key); add `PrivacyInfo.xcprivacy`.
   - `Helm/ContentView.swift` — replace the `#if os(macOS)` wrapper with a real `NavigationSplitView` (ADR‑12).
   - `Helm/Item.swift` — replace the template model with the §3 entities (CloudKit‑safe).
   - `Helm.xcodeproj/project.pbxproj` — `SWIFT_VERSION = 5.0` → 6; add the macOS App Sandbox Calendar entitlement + link `CloudKit.framework` on macOS.
   - Create the `HelmCore` SwiftPM package (`HelmDomain`/`HelmParsing`/`HelmCalendar`).
3. **Run Spikes 1 & 2** (the architecture go/no‑go gates) before building any abstraction.

---

## Appendix — caveats to re‑verify against the live SDK

- No EventKit API changes surfaced for the iOS 26 / macOS 26 generation; the iOS 17 access model is treated as current — re‑verify against the Xcode 26 SDK headers.
- "Apple Calendar ignores `.ics` UID on import" is sourced partly to older community threads — re‑verify on OS 26 before building user messaging around it.
- "Google‑via‑EventKit writes back near‑instantly" is the load‑bearing assumption behind ADR‑1 and is only medium‑confidence — **Spike 1 must pass** or the provider strategy shifts to Apple + `.ics` + direct‑Google‑sooner.
