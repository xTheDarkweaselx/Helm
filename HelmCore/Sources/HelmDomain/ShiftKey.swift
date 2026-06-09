//
//  ShiftKey.swift
//  HelmDomain
//
//  The canonical dedup key — "yyyy-MM-dd|tz|code" computed in the shift's own
//  time zone. Imports use a bare code; the rota BUILDER namespaces the code with
//  "g:<scope>:" so generated events can never collide with imported ones (or with
//  another schedule's) through the global helm:// calendar matching.
//

import Foundation

public enum ShiftKey {
    /// Build the dedup key for a shift on `localDate` in `timeZoneIdentifier`.
    public static func make(localDate: Date, timeZoneIdentifier: String, code: String) -> String {
        let tz = TimeZone(identifier: timeZoneIdentifier) ?? .gmt
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let c = calendar.dateComponents([.year, .month, .day], from: localDate)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return "\(day)|\(timeZoneIdentifier)|\(code)"
    }

    /// Namespace a code for a generated (built) schedule so its keys are disjoint
    /// from imports (bare code) and from other schedules. The FULL scope (schedule
    /// id) is used — truncating risked cross-schedule key collisions.
    public static func generatedCode(scope: String, code: String) -> String {
        "g:\(scope):\(code)"
    }
}
