# Roster fixtures

Real spreadsheets dropped here are **gitignored** (they contain personal/employer schedule
data — see `.gitignore`). Keep them local for development. Commit only **anonymised** samples
(`anonymised-*` / `sample-*.csv`) and this spec. These files drive the `HelmParsing` test corpus.

---

## Observed format #1 — "list layout, single person, shift-code column"

First real sample analysed (a 7-month training programme, `dd/mm/yyyy`, single sheet,
formula-driven from an external workbook with cached values present → readable without the link).

**Shape:** one row per calendar day. Header in row 1. Date axis = column **A** (list layout).

| Col | Header          | Role                              | Notes |
|-----|-----------------|-----------------------------------|-------|
| A   | DATE            | the day                           | date-styled, custom numFmt `dd/mm/yyyy;@` (UK) |
| B   | Day of the Week | weekday (redundant, derivable)    | ignore for import |
| C   | Course Title    | → event **title**                 | also encodes `OFF` on off days |
| D   | Location        | → event **location**             | `-` / `0` / `TBC` mean "none" |
| E   | Day #           | course-day counter                | optional → event note |
| F   | **SHIFT**       | → start/end **time**              | the key column (see vocabulary) |

**Shift-code vocabulary (column F) for this employer:**

| Code        | Meaning            | Times                | Import action |
|-------------|--------------------|----------------------|---------------|
| `M`         | Morning            | 06:30–13:30          | timed event |
| `A`         | Afternoon          | 13:30–22:00          | timed event |
| `M/A`       | Morning + Afternoon| 06:30–22:00 (assumed)| timed event — **flag to confirm** (could be split) |
| `OFF`       | Day off            | —                    | no event (optionally an all-day "OFF" marker) |
| `TBC`       | To be confirmed    | unknown              | tentative: all-day or skip-with-flag, never guess a time |
| `HHMM-HHMM` | Explicit range     | e.g. `0900-1700`, `0930-1500` | parse inline times |

> The `M`/`A` → time mapping is **employer-specific** and was supplied by the user, not present
> in the file. This is exactly the "missing legend" problem in `DEVELOPMENT_PLAN.md` §5: codes are
> in the sheet, their times are not. Helm remembers this mapping per `ImportProfile`.

**Parser implications validated by this sample:**
- List layout + a single shift-code column (no "which row is me" needed here, but the matrix case still must be supported).
- Codes need a per-source legend (`ShiftCodeMapping`); some cells carry **inline** times (`HHMM-HHMM`) that bypass the legend.
- Non-shift columns (Title, Location, Day#) enrich the event — the importer must pull title/location from sibling columns, not just the shift cell.
- Sentinel "none" values appear in multiple guises (`-`, `0`, `TBC`, `OFF`).
- Date format is locale-specific (`dd/mm/yyyy`) and must be confirmed/inferred, not assumed `MM/DD`.
- File is formula-driven from an external workbook; the cached `<v>` values are what we read.
