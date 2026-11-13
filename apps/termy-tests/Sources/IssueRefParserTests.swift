import XCTest
@testable import termy

final class IssueRefParserTests: XCTestCase {
    let example = "- 답을 기다리는 것: #1300 코디네이터 판단, bdrive-core #26~#28 수정."
    private func ref(_ text: String, at needle: String, plus: Int = 1) -> IssueRef? {
        let offset = text.distance(from: text.startIndex, to: text.range(of: needle)!.lowerBound) + plus
        return IssueRefParser.hit(in: text, atOffset: offset)?.ref
    }
    func test_example_bareNumber() { XCTAssertEqual(ref(example, at: "#1300"), IssueRef(number: 1300, kind: .issue, qualifier: nil)) }
    func test_example_spacedName() { XCTAssertEqual(ref(example, at: "#26"), IssueRef(number: 26, kind: .issue, qualifier: .spaced("bdrive-core"))) }
    func test_example_rangeEndInheritsName() { XCTAssertEqual(ref(example, at: "#28"), IssueRef(number: 28, kind: .issue, qualifier: .spaced("bdrive-core"))) }
    func test_clickOnNameOfJoinedRef_hits() { XCTAssertEqual(ref("see fl#45 now", at: "fl#45", plus: 0)?.qualifier, .joined("fl")) }
    func test_joinedForms() {
        XCTAssertEqual(ref("fl!189", at: "!189"), IssueRef(number: 189, kind: .mergeRequest, qualifier: .joined("fl")))
        XCTAssertEqual(ref("x netdrive4_flutter#25", at: "#25")?.qualifier, .joined("netdrive4_flutter"))
        XCTAssertEqual(ref("x bdrive/netdrive3#1300", at: "#1300")?.qualifier, .joined("bdrive/netdrive3"))
    }
    func test_stopWords() {
        XCTAssertEqual(ref("PR#12", at: "#12"), IssueRef(number: 12, kind: .issue, qualifier: nil))
        XCTAssertEqual(ref("MR!3", at: "!3"), IssueRef(number: 3, kind: .mergeRequest, qualifier: nil))
        XCTAssertEqual(ref("see MR #102", at: "#102"), IssueRef(number: 102, kind: .mergeRequest, qualifier: nil))
        XCTAssertEqual(ref("issue #12", at: "#12")?.qualifier, nil)
        XCTAssertEqual(ref("항목 #3", at: "#3")?.qualifier, nil)
    }
    func test_koreanParticleAfterNumber() { XCTAssertEqual(ref("#1300에 9번 항목", at: "#1300")?.number, 1300) }
    func test_notTokens() {
        XCTAssertNil(ref("abc#12x", at: "#12")); XCTAssertNil(ref("## 2", at: "## 2", plus: 0))
        XCTAssertNil(IssueRefParser.hit(in: example, atOffset: example.count - 3))   // "수정" 위
    }
    func test_wordBreaksInheritance() { XCTAssertNil(ref("netdrive3 #1300 코디네이터 판단, #26", at: "#26")?.qualifier) }
    func test_commaListInherits() { XCTAssertEqual(ref("bdrive-core #26, #27", at: "#27")?.qualifier, .spaced("bdrive-core")) }
    func test_clues_nameAndRange() {
        XCTAssertEqual(IssueRefParser.clues(in: "2. netdrive3 #1300 코디네이터 판단"),
                       [IssueRefClue(numbers: 1300...1300, kind: .issue, source: .name(.spaced("netdrive3")))])
        XCTAssertEqual(IssueRefParser.clues(in: example),
                       [IssueRefClue(numbers: 26...28, kind: .issue, source: .name(.spaced("bdrive-core")))])
    }
    func test_clues_urls() {
        let gl = RepoWebURL(storageKey: "gitlab.bdrive.com/bdrive/netdrive3")!
        XCTAssertEqual(IssueRefParser.clues(in: "1300 https://gitlab.bdrive.com/bdrive/netdrive3/-/issues/1300 ['nd4::GA전']"),
                       [IssueRefClue(numbers: 1300...1300, kind: .issue, source: .url(gl))])
        XCTAssertEqual(IssueRefParser.clues(in: "https://github.com/bdrive/bdweb/pull/7").first?.kind, .issue)
        XCTAssertEqual(IssueRefParser.clues(in: "https://gitlab.bdrive.com/bdrive/netdrive3/-/merge_requests/102").first?.kind, .mergeRequest)
    }
    func test_mentionedNames() { XCTAssertEqual(IssueRefParser.mentionedNames(in: example), ["bdrive-core"]) }

    func test_spacedNameAcrossInkHardWrap() { XCTAssertEqual(ref("…bdrive-core\n  #26 fix", at: "#26"), IssueRef(number: 26, kind: .issue, qualifier: .spaced("bdrive-core"))) }
    func test_positionsAreCharacterOffsets() {
        let hit = IssueRefParser.hit(in: example, atOffset: example.distance(from: example.startIndex, to: example.range(of: "#1300")!.lowerBound))
        XCTAssertEqual(hit?.start, example.distance(from: example.startIndex, to: example.range(of: "#1300")!.lowerBound))
        XCTAssertEqual(hit?.end, hit.map { $0.start + 5 })
        let joined = IssueRefParser.hit(in: "한글 fl#45", atOffset: 4)
        XCTAssertEqual(joined?.start, 3); XCTAssertEqual(joined?.end, 8)
    }
    func test_unsplitDigitsAndLongNumbers() { XCTAssertNil(ref("#12345678", at: "#1")) }


    func test_digitsAreNotNames() {
        XCTAssertNil(ref("#1300 #1301", at: "#1301")?.qualifier)
        XCTAssertEqual(IssueRefParser.clues(in: "#1300 #1301"), [])
        XCTAssertEqual(ref("fl#45 #46", at: "#46")?.qualifier, .joined("fl"))
        XCTAssertNil(ref("step 2 #12", at: "#12")?.qualifier)
    }
    func test_dashRangeInheritsAndMerges() {
        let want = [IssueRefClue(numbers: 26...28, kind: .issue, source: .name(.spaced("bdrive-core")))]
        for text in ["bdrive-core #26-#28", "bdrive-core #26–#28"] {
            XCTAssertEqual(ref(text, at: "#28")?.qualifier, .spaced("bdrive-core"))
            XCTAssertEqual(IssueRefParser.clues(in: text), want)
        }
    }
    func test_nameCannotEndInPunctuation() { XCTAssertNil(ref("Fixed in main. #12", at: "#12")?.qualifier) }
    func test_urlFragmentIsNotARef() {
        let text = "see https://example.com/page#12"
        XCTAssertNil(ref(text, at: "#12"))
        XCTAssertEqual(IssueRefParser.mentionedNames(in: text), [])
    }
}
