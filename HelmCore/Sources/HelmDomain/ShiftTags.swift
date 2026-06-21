//
//  ShiftTags.swift
//  HelmDomain
//
//  v7 tags: the ONE place that parses/encodes the per-shift-type tag list and
//  its optional per-tag colours. Storage is CloudKit-safe CSV on ShiftType
//  (tagsRaw + tagColorsRaw) — this pure type owns the (de)serialisation rules
//  so the editor (writer) and search/pills (readers) can never disagree.
//
//  tagsRaw:       "Night, Senior, Cover"   (comma-separated, order-preserving)
//  tagColorsRaw:  "Night|3A4A5E,Senior|FF7A1A"  (name|RRGGBB pairs)
//

import Foundation

public enum ShiftTags {
    /// Caps that keep a single CSV cell sane and a row's pill stack legible.
    public static let maxCount = 8
    public static let maxLength = 24

    /// Decode the tag list: trim, drop empties, strip the CSV/colour delimiters
    /// (',' and '|'), case-insensitive dedupe PRESERVING the first spelling,
    /// clamp each to `maxLength`, cap the list at `maxCount`.
    public static func parse(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty else { return [] }
        var out: [String] = []
        var seen = Set<String>()
        for piece in raw.split(separator: ",") {
            let cleaned = sanitizeTag(String(piece))
            guard !cleaned.isEmpty else { continue }
            let fold = cleaned.lowercased()
            guard !seen.contains(fold) else { continue }
            seen.insert(fold)
            out.append(cleaned)
            if out.count >= maxCount { break }
        }
        return out
    }

    /// Re-encode a (possibly user-edited) tag list through the same rules, so a
    /// round-trip is idempotent.
    public static func encode(_ tags: [String]) -> String {
        parse(tags.joined(separator: ",")).joined(separator: ",")
    }

    /// One tag, cleaned: no leading/trailing space, no delimiters, length-capped.
    public static func sanitizeTag(_ tag: String) -> String {
        let stripped = tag
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "|", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard stripped.count > maxLength else { return stripped }
        return String(stripped.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Per-tag colours

    /// Decode "name|RRGGBB" pairs into a map (keyed by the folded tag name so
    /// lookups are case-insensitive). Malformed pairs are skipped.
    public static func parseColors(_ raw: String?) -> [String: String] {
        guard let raw, !raw.isEmpty else { return [:] }
        var map: [String: String] = [:]
        for pair in raw.split(separator: ",") {
            let parts = pair.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let name = sanitizeTag(parts[0]).lowercased()
            let hex = normalizedHex(parts[1])
            guard !name.isEmpty, let hex else { continue }
            map[name] = hex
        }
        return map
    }

    /// Encode a tag→hex map, restricted to tags that still exist (so deleting a
    /// tag also forgets its custom colour). Output order follows `tags`.
    public static func encodeColors(_ colors: [String: String], among tags: [String]) -> String {
        tags.compactMap { tag -> String? in
            guard let hex = colors[tag.lowercased()], let norm = normalizedHex(hex) else { return nil }
            return "\(sanitizeTag(tag))|\(norm)"
        }
        .joined(separator: ",")
    }

    /// The resolved colour for a tag: its custom colour, else a deterministic
    /// palette colour derived from the (folded) name so the same tag always
    /// reads the same hue across the app.
    public static func colorHex(for tag: String, customColors: [String: String]) -> String {
        if let custom = customColors[tag.lowercased()], let norm = normalizedHex(custom) {
            return norm
        }
        return paletteColorHex(for: tag)
    }

    /// A stable hue for a tag with no custom colour: hash the folded name into
    /// the curated palette (deterministic, no randomness).
    public static func paletteColorHex(for tag: String) -> String {
        let palette = ShiftColorPresets.tagPalette
        guard !palette.isEmpty else { return "808080" }
        // FNV-1a over the folded name → stable, platform-independent.
        var hash: UInt64 = 1469598103934665603
        for byte in tag.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return palette[Int(hash % UInt64(palette.count))]
    }

    /// Validate + canonicalise a 6-hex colour ("#RRGGBB"/"RRGGBB" → "RRGGBB"
    /// uppercased). nil if it isn't 6 hex digits.
    public static func normalizedHex(_ value: String) -> String? {
        var hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        // ASCII-only: Character.isHexDigit also accepts fullwidth/non-ASCII forms.
        guard hex.count == 6, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return hex.uppercased()
    }
}
