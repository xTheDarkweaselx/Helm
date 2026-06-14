//
//  RosterDateParser.swift
//  HelmParsing
//
//  Locale-aware date parsing. The same string "03/04/2026" is March or April
//  depending on the source's locale (DEVELOPMENT_PLAN.md §5), so the day/month
//  order is explicit (and confirmed in the import wizard), never silently guessed.
//  Returns a Date anchored at local noon on the parsed calendar day, so only
//  y/m/d is meaningful (date-only semantics) and DST midnight edges are avoided.
//

import Foundation

public enum RosterDateParser {

    public enum Order: Sendable {
        case dayFirst    // dd/MM/yyyy (UK, the first real sample)
        case monthFirst  // MM/dd/yyyy (US)
        case iso         // yyyy-MM-dd
        case auto        // infer from the values where unambiguous, else dayFirst
    }

    /// Parse a date string. Accepts `/ - .` separators and 2- or 4-digit years.
    public static func parse(_ raw: String, order: Order = .dayFirst, timeZoneIdentifier: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(whereSeparator: { "/-. ".contains($0) }).map(String.init)
        guard parts.count == 3, let n0 = Int(parts[0]), let n1 = Int(parts[1]), let n2 = Int(parts[2]) else {
            return nil
        }

        let (day, month, year): (Int, Int, Int)
        switch resolvedOrder(order, n0: n0, n1: n1, n2: n2) {
        case .iso:
            (year, month, day) = (normalizeYear(n0), n1, n2)
        case .monthFirst:
            (month, day, year) = (n0, n1, normalizeYear(n2))
        case .dayFirst, .auto:
            (day, month, year) = (n0, n1, normalizeYear(n2))
        }

        guard (1...12).contains(month), (1...31).contains(day) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .gmt
        let comps = DateComponents(year: year, month: month, day: day, hour: 12)
        guard let date = calendar.date(from: comps) else { return nil }
        // Reject roll-over (e.g. day 31 in a 30-day month yielding the next month).
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else { return nil }
        return date
    }

    /// Infer the most likely order for a whole COLUMN of date strings by tallying
    /// unambiguous evidence across rows (a part 13…31 forces the day position; a
    /// 4-digit first part forces ISO year-first). Deliberately HARD to move off
    /// the UK day-first default so one typo or stray cell can't flip a whole
    /// column (May↔June corruption): a non-default order needs a QUORUM (≥2
    /// decisive votes), a clear plurality, and — for month-first — zero
    /// contradicting day-first evidence. Only real 4-digit-year dates vote, so
    /// stray times/totals in the column are ignored.
    public static func inferOrder(from samples: [String]) -> Order {
        var dayFirst = 0, monthFirst = 0, iso = 0
        for raw in samples {
            let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { "/-. ".contains($0) }).map(String.init)
            guard parts.count == 3, let n0 = Int(parts[0]), let n1 = Int(parts[1]), let n2 = Int(parts[2]) else { continue }
            // ISO: 4-digit year first (e.g. 2026-06-14).
            if parts[0].count == 4, (1900...2100).contains(n0) { iso += 1; continue }
            // Day/month-first: require a real 4-digit year last, so a time like
            // "06.30.00" or a "1/2" note can't masquerade as a date vote.
            guard parts[2].count == 4, (1900...2100).contains(n2) else { continue }
            if n0 > 12, n0 <= 31 { dayFirst += 1 }
            else if n1 > 12, n1 <= 31 { monthFirst += 1 }
        }
        if iso >= 2, iso > dayFirst, iso > monthFirst { return .iso }
        if monthFirst >= 2, dayFirst == 0, monthFirst > iso { return .monthFirst }
        return .dayFirst
    }

    private static func resolvedOrder(_ order: Order, n0: Int, n1: Int, n2: Int) -> Order {
        guard order == .auto else { return order }
        if n0 > 31 { return .iso }       // 2026-06-14
        if n0 > 12, n0 <= 31 { return .dayFirst }  // 14/06/2026 — first part must be a day
        if n1 > 12, n1 <= 31 { return .monthFirst } // 06/14/2026 — second part must be a day
        return .dayFirst                  // ambiguous → default to day-first
    }

    private static func normalizeYear(_ y: Int) -> Int {
        if y >= 100 { return y }
        return y >= 70 ? 1900 + y : 2000 + y // 2-digit year window
    }
}
