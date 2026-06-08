# Spike 2 — CoreXLSX under Xcode 26 / Swift 6 / visionOS

**Question (DEVELOPMENT_PLAN.md §7):** does CoreXLSX resolve + build for our platforms
under Xcode 26 / Swift 6, and how does it handle dates? **Verdict: vendor/fork it** (ADR-7 confirmed).

Run `swift run CoreXLSXSpike <file.xlsx>` to reproduce.

## What works
- **Resolves** cleanly: CoreXLSX 0.14.2 + XMLCoder + ZIPFoundation, via SwiftPM under the Swift 6 toolchain.
- **Builds**: macOS (host) ✅ and **iOS Simulator** ✅ (`** BUILD SUCCEEDED **`). Dependencies compile in their own (Swift 5) language mode, so our Swift 6 code consuming them is fine.
- Parses worksheets, rows, cells, shared strings, and inline strings correctly once it can read the archive.

## Blockers found (all argue for a fork)
1. **Closed `Relationship.SchemaType` enum aborts on real files.** Our actual roster carries a Microsoft **sensitivity/classification label** (`docMetadata/LabelInfo.xml`) and **cell metadata** (`xl/metadata.xml`). Their relationship types (`…/2020/02/relationships/classificationlabels`, `…/relationships/sheetMetadata`) are not in CoreXLSX's allow-list `enum SchemaType: String, Codable`, so `parseWorkbooks()`/`parseWorksheet()` throw `DecodingError.dataCorrupted` and **the whole parse fails**. Modern Excel exports routinely include these.
   - **Fork fix (proven in this spike):** make `SchemaType` lenient — add a `.unknown` case and a custom `init(from:)` that falls back to it. After patching the checkout, our **original file parsed end-to-end**.
2. **`dateValue` is wrong three ways** (see `CellQueries.swift`):
   - hardcodes the **1899-12-30 epoch** → ignores `date1904` (1462-day error on Mac/1904 files);
   - uses **`TimeZone.autoupdatingCurrent`** → e.g. our `A3` (26/05/2026) came back as `2026-05-25T23:00:00Z` (midnight BST stored as prev-day 23:00 UTC) — non-deterministic per device;
   - **no number-format gating** → a plain `Day # = 0` counter cell was "converted" to `1899-12-30`.
   - CoreXLSX's `Workbook` doesn't even expose `date1904`. **We must build our own date resolver** (read `date1904` from `xl/workbook.xml`, gate on `styleIndex` → `numFmt`, fixed time zone, date-only semantics).

## Not verified here
- **visionOS build**: the visionOS 26.5 platform component isn't installed on this Mac, so the visionOS build couldn't run. Low risk (pure-Foundation deps; iOS + macOS pass) and visionOS isn't a v1 focus — confirm once the platform is installed.

## Decision
Fork CoreXLSX into the repo at v1.0: (a) lenient `SchemaType`, (b) ignore/strip its `dateValue`,
(c) add `Sendable`/isolation annotations. Pair it with a Helm-owned date resolver. Keep XMLCoder +
ZIPFoundation as upstream deps. The normalized `SpreadsheetGrid` (already built + tested in HelmParsing)
insulates the rest of the app from all of this.
