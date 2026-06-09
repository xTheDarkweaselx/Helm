# Third-Party Notices

Helm includes the following third-party software.

## CoreXLSX (vendored & modified)

- Source: https://github.com/CoreOffice/CoreXLSX
- License: Apache License 2.0 (see `HelmCore/Sources/CoreXLSX/LICENSE.md`)
- Location: `HelmCore/Sources/CoreXLSX/`
- **Modifications by the Helm project (2026):**
  - `Relationships.swift` — `Relationship.SchemaType` made lenient (`.unknown`
    fallback) so files carrying unknown relationship types (e.g. Microsoft
    sensitivity-label `classificationlabels`, `sheetMetadata`) parse instead of
    aborting.
  - `Worksheet/Cell.swift` — `CellType` made lenient (`.unknown` fallback) so an
    unknown cell `t=` value does not abort the worksheet parse.
  - `Workbook.swift` — added `workbookPr`/`date1904` parsing (stock omits it),
    required for correct serial-date conversion.
  - `Styles.swift` — stopped decoding `<dxfs>` (differential/conditional formats),
    whose `<dxf>` entries omit `numFmtId` and broke the required-field decoder on
    real files. Helm does not use `dxfs`.
  - Helm never calls `Cell.dateValue` (it hardcodes the 1899-12-30 epoch, uses the
    device time zone, and gates on no number format); date handling lives in
    `HelmDateResolver`.

## XMLCoder

- Source: https://github.com/CoreOffice/XMLCoder (pinned 0.14.0)
- License: MIT
- Used transitively by the vendored CoreXLSX target.

## ZIPFoundation

- Source: https://github.com/weichsel/ZIPFoundation (pinned 0.9.20)
- License: MIT
- Used transitively by the vendored CoreXLSX target.
