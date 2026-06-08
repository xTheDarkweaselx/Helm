import Foundation
import CoreXLSX

// Usage: swift run CoreXLSXSpike <path-to.xlsx>
guard CommandLine.arguments.count > 1 else {
    print("usage: CoreXLSXSpike <file.xlsx>")
    exit(2)
}
let path = CommandLine.arguments[1]

guard let file = XLSXFile(filepath: path) else {
    print("ERROR: could not open \(path) as xlsx")
    exit(1)
}

do {
    // 1. Workbook + sheets
    let workbooks = try file.parseWorkbooks()
    print("workbooks: \(workbooks.count)")

    // FINDING: CoreXLSX's Workbook models only views + sheets — it does NOT
    // expose date1904. We must read it ourselves from xl/workbook.xml (ADR-7).
    for wb in workbooks {
        let sheetNames = wb.sheets.items.map { $0.name ?? "?" }
        print("workbook sheets: \(sheetNames)  (date1904 NOT exposed by CoreXLSX)")
    }

    let paths = try file.parseWorksheetPathsAndNames(workbook: workbooks[0])
    print("worksheets: \(paths.map { $0.name ?? "?" })")

    let sharedStrings = try file.parseSharedStrings()

    guard let first = paths.first else { print("no worksheets"); exit(1) }
    let ws = try file.parseWorksheet(at: first.path)
    let rows = ws.data?.rows ?? []
    print("rows: \(rows.count)")

    // 2. Dump the first 6 rows: raw value, resolved string, and CoreXLSX's dateValue.
    print("\n--- first rows (ref | type | rawValue | string | CoreXLSX.dateValue) ---")
    for row in rows.prefix(6) {
        for c in row.cells {
            let ref = c.reference.description
            let type = c.type.map { "\($0)" } ?? "-"
            let raw = c.value ?? ""
            let str = (sharedStrings.map { c.stringValue($0) } ?? nil) ?? ""
            let dv = c.dateValue.map { ISO8601DateFormatter().string(from: $0) } ?? "-"
            print("\(ref)\t\(type)\t\(raw)\t\(str)\t\(dv)")
        }
    }

    // 3. Date probe: show how CoreXLSX converts a known serial vs the correct value.
    //    Excel serial 46176 = 2026-06-14 in the 1900 system; in the 1904 system the
    //    SAME serial is 4 years + 1 day later. CoreXLSX.dateValue ignores date1904.
    print("\n--- date probe (does CoreXLSX honour date1904?) ---")
    if let probe = rows.first?.cells.first(where: { $0.type == .date || $0.dateValue != nil }) {
        print("probe cell \(probe.reference): raw=\(probe.value ?? "-") dateValue=\(probe.dateValue.map { ISO8601DateFormatter().string(from: $0) } ?? "-")")
    } else {
        print("no date-typed cell found in first row (dates may be number-formatted, not typed)")
    }

    print("\nSPIKE RESULT: parsed OK on \(ProcessInfo.processInfo.operatingSystemVersionString)")
} catch {
    print("PARSE ERROR: \(error)")
    exit(1)
}
