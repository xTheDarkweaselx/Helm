//
//  ShiftContentHash.swift
//  HelmDomain
//
//  Deterministic content hash used to detect whether a shift changed between
//  imports. Swift's Hasher is per-process randomized, so we use FNV-1a (stable
//  across launches/devices) over a canonical field string.
//

import Foundation

public enum ShiftContentHash {
    /// Stable hash of the calendar-visible content of a shift. Two shifts with the
    /// same key but different hashes are treated as "updated" on re-import.
    public static func make(
        title: String?,
        startUTC: Date?,
        endUTC: Date?,
        location: String?,
        timeZoneIdentifier: String,
        alarmOffsetsMinutes: [Int] = []
    ) -> String {
        func stamp(_ date: Date?) -> String {
            guard let date else { return "-" }
            return String(format: "%.0f", date.timeIntervalSince1970)
        }
        let canonical = [
            title ?? "",
            stamp(startUTC),
            stamp(endUTC),
            location ?? "",
            timeZoneIdentifier,
            alarmOffsetsMinutes.sorted().map(String.init).joined(separator: ","),
        ].joined(separator: "\u{1f}")
        return fnv1a(canonical)
    }

    /// 64-bit FNV-1a, hex-encoded.
    static func fnv1a(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(hash, radix: 16)
    }
}
