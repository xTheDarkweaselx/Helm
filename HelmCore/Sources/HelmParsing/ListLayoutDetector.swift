//
//  ListLayoutDetector.swift
//  HelmParsing
//
//  Auto-detects the header row and which columns hold date / shift / title /
//  location in a list-layout sheet, by matching header keywords. Keeps the
//  import wizard to "confirm" rather than "configure" for common formats
//  (DEVELOPMENT_PLAN.md §4 step 4). Returns nil when it can't find the two
//  required columns (date + shift) so the caller can fall back to manual mapping.
//

import Foundation

public enum ListLayoutDetector {

    private static let dateKeys = ["date"]
    private static let shiftKeys = ["shift", "duty", "code", "rota", "watch"]
    private static let titleKeys = ["course", "title", "activity", "task", "description", "event", "subject"]
    private static let locationKeys = ["location", "site", "place", "room", "venue"]

    /// Inspect up to the first `maxHeaderScan` rows for the best header row.
    public static func detect(sheet: Sheet, maxHeaderScan: Int = 6) -> ListColumnMapping? {
        let scanLimit = min(maxHeaderScan, sheet.rowCount)
        guard scanLimit > 0 else { return nil }

        var best: (mapping: ListColumnMapping, score: Int)?
        for row in 0..<scanLimit {
            guard let mapping = mapping(forHeaderRow: row, sheet: sheet) else { continue }
            let score = scoreFor(mapping)
            if best == nil || score > best!.score {
                best = (mapping, score)
            }
        }
        return best?.mapping
    }

    private static func mapping(forHeaderRow row: Int, sheet: Sheet) -> ListColumnMapping? {
        var dateCol: Int?, shiftCol: Int?, titleCol: Int?, locationCol: Int?
        for cell in sheet.row(row) {
            let header = cell.text.lowercased()
            let col = cell.reference.column
            if dateCol == nil, dateKeys.contains(where: header.contains) { dateCol = col }
            else if shiftCol == nil, shiftKeys.contains(where: header.contains) { shiftCol = col }
            else if titleCol == nil, titleKeys.contains(where: header.contains) { titleCol = col }
            else if locationCol == nil, locationKeys.contains(where: header.contains) { locationCol = col }
        }
        guard let dateCol, let shiftCol else { return nil }
        return ListColumnMapping(
            dateColumn: dateCol,
            codeColumn: shiftCol,
            titleColumn: titleCol,
            locationColumn: locationCol,
            headerRowCount: row + 1
        )
    }

    private static func scoreFor(_ m: ListColumnMapping) -> Int {
        2 + (m.titleColumn != nil ? 1 : 0) + (m.locationColumn != nil ? 1 : 0)
    }
}
