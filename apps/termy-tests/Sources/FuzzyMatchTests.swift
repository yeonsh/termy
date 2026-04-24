// FuzzyMatchTests.swift
//
// Covers the subsequence scorer. Lower score = better match; nil = no match.

import XCTest
@testable import termy

final class FuzzyMatchTests: XCTestCase {

    // MARK: - Basics

    func test_emptyQuery_scoresZero() {
        XCTAssertEqual(FuzzyMatch.score(query: "", text: "api"), 0)
    }

    func test_exactPrefix_scoresZero() {
        XCTAssertEqual(FuzzyMatch.score(query: "api", text: "api"), 0)
        XCTAssertEqual(FuzzyMatch.score(query: "api", text: "api-legacy"), 0)
    }

    func test_subsequence_matches() {
        // `ap` → a, then p — gap of 0 between consecutive → score 0.
        XCTAssertEqual(FuzzyMatch.score(query: "ap", text: "api"), 0)
        // `ai` → a at 0, i at 2 — gap of 1 character (`p`).
        XCTAssertEqual(FuzzyMatch.score(query: "ai", text: "api"), 1)
    }

    func test_nonSubsequence_returnsNil() {
        XCTAssertNil(FuzzyMatch.score(query: "xyz", text: "api"))
        XCTAssertNil(FuzzyMatch.score(query: "ab", text: "ba"))  // order matters
        XCTAssertNil(FuzzyMatch.score(query: "api", text: "ap")) // missing final char
    }

    // MARK: - Case insensitivity

    func test_caseInsensitive() {
        XCTAssertEqual(FuzzyMatch.score(query: "API", text: "my-api"),
                       FuzzyMatch.score(query: "api", text: "my-api"))
        XCTAssertNotNil(FuzzyMatch.score(query: "AP", text: "api"))
    }

    // MARK: - Ranking / ordering

    func test_earlierMatch_beatsLaterMatch() {
        // Both contain `api` as a subsequence; the one starting at index 0
        // should score tighter than one starting later.
        let early = FuzzyMatch.score(query: "api", text: "api")!
        let late = FuzzyMatch.score(query: "api", text: "my-api")!
        XCTAssertLessThan(early, late)
    }

    func test_tighterRun_beatsLooseRun() {
        // `ai` → a at 0, i at 2 in `api` = 1-char gap → cost 1.
        // `ai` → a at 0, i at 3 in `abci` = 2-char gap → cost 2.
        let tight = FuzzyMatch.score(query: "ai", text: "api")!
        let loose = FuzzyMatch.score(query: "ai", text: "abci")!
        XCTAssertLessThan(tight, loose)
    }

    // MARK: - Realistic project-switcher examples

    func test_realistic_projectNames() {
        // Mix of exact-prefix, hyphenated, interior-match, and no-match names
        // to exercise ranking. `api` is subsequence of each *-match name.
        let names = [
            "api",            // exact → score 0
            "api-legacy",     // prefix → score 0
            "application",    // a-p-p-l-i → matches, higher cost
            "my-api",         // interior → score > 0
            "terminal",       // no `a-p-i` subsequence
            "pineapple"       // `p` before `a`, no `i` after last `a` → no match
        ]
        let query = "api"
        let ranked: [(name: String, score: Int)] = names.compactMap { name in
            FuzzyMatch.score(query: query, text: name).map { (name, $0) }
        }.sorted { $0.score < $1.score }

        XCTAssertEqual(ranked.first?.name, "api", "exact match must win")
        let matched = Set(ranked.map(\.name))
        XCTAssertTrue(matched.contains("api-legacy"))
        XCTAssertTrue(matched.contains("application"))
        XCTAssertTrue(matched.contains("my-api"))
        XCTAssertFalse(matched.contains("terminal"), "no `a-p-i` subsequence")
        XCTAssertFalse(matched.contains("pineapple"), "`a` comes after `p` — no subsequence")
    }
}
