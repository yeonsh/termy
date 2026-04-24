// FuzzyMatch.swift
//
// Tiny subsequence-based fuzzy scorer powering the ⌘K switcher. Each char
// of `query` must appear in `text` in order (case-insensitive). Score is a
// cost metric — *lower* is a better match. Nil means "no match, hide row."
//
// The model matches user expectations for command palettes: typing `abc`
// matches `a-boarding-card`, `abacus`, and `absolute-circle`; it does NOT
// match `b-a-c`, `xbc`, or any text missing one of the query chars.
//
// Cost components:
//   * Distance from the start of `text` to the first match (earlier = better)
//   * Gap between consecutive matches (tighter runs = better)
//
// Why subsequence, not full Smith-Waterman / typo-correcting: project names
// are short and visible. A user typing `ap` wants `api`, not `arPi`. Levenshtein
// tolerance is a nicety we can add when users complain about hitting an `l`
// on the way to `api-legacy`.

import Foundation

enum FuzzyMatch {
    /// Nil if `query` isn't a subsequence of `text`; otherwise a cost where
    /// lower is tighter. Empty query always scores 0 (every row qualifies).
    static func score(query: String, text: String) -> Int? {
        if query.isEmpty { return 0 }
        let q = Array(query.lowercased())
        let t = Array(text.lowercased())
        var qi = 0
        var cost = 0
        var lastMatchIdx: Int? = nil

        for (ti, ch) in t.enumerated() {
            if qi >= q.count { break }
            if ch == q[qi] {
                if let last = lastMatchIdx {
                    cost += (ti - last - 1) // gap between matches
                } else {
                    cost += ti              // leading distance
                }
                lastMatchIdx = ti
                qi += 1
            }
        }
        return qi == q.count ? cost : nil
    }
}
