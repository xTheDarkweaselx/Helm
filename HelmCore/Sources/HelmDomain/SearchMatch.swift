//
//  SearchMatch.swift
//  HelmDomain
//
//  v7 search: the one matching rule used by global search — case- and
//  diacritic-insensitive, token-AND (every whitespace-separated query token must
//  appear somewhere in the haystack). Pure and unit-tested.
//

import Foundation

public enum SearchMatch {
    /// True when every token of `query` appears in `haystack` (both normalised).
    /// An empty/whitespace query never matches (callers show tips instead).
    public static func matches(_ haystack: String, query: String) -> Bool {
        let tokens = normalize(query).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return false }
        let hay = normalize(haystack)
        return tokens.allSatisfy { hay.contains($0) }
    }

    /// Lowercased, diacritic-folded, whitespace-collapsed.
    public static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
