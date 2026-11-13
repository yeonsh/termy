import Foundation

enum IssueRefQualifier: Equatable, Sendable {
    case joined(String)
    case spaced(String)

    var name: String {
        switch self {
        case .joined(let name), .spaced(let name): return name
        }
    }
}

struct IssueRef: Equatable, Sendable {
    var number: Int
    var kind: IssueRefKind
    var qualifier: IssueRefQualifier?
}

struct IssueRefHit: Equatable, Sendable {
    var ref: IssueRef
    /// Character offsets of the token (name included) in the scanned text.
    var start: Int
    var end: Int
}

/// A name or issue URL tied to a number, used to decide which project a bare
/// `#N` belongs to.
struct IssueRefClue: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case name(IssueRefQualifier)
        case url(RepoWebURL)
    }

    var numbers: ClosedRange<Int>
    var kind: IssueRefKind
    var source: Source
}

enum IssueRefParser {
    static let stopWords: Set<String> = ["pr", "mr", "issue", "issues", "bug", "ticket", "이슈", "버그"]

    private struct Token {
        var ref: IssueRef
        var start: Int
        var end: Int
        var markerIndex: Int
        var inherited: Bool
    }

    // MARK: Public API

    static func hit(in text: String, atOffset offset: Int) -> IssueRefHit? {
        let chars = Array(text)
        for token in tokens(in: chars) where token.start <= offset && offset < token.end {
            return IssueRefHit(ref: token.ref, start: token.start, end: token.end)
        }
        return nil
    }

    static func clues(in text: String) -> [IssueRefClue] {
        let chars = Array(text)
        var found: [(position: Int, clue: IssueRefClue)] = []
        var previousToken: Token?
        var previousClueIndex: Int?
        for token in tokens(in: chars) {
            defer { previousToken = token }
            guard let qualifier = token.ref.qualifier else {
                previousClueIndex = nil
                continue
            }
            if token.inherited, let prev = previousToken, let index = previousClueIndex,
               found[index].clue.kind == token.ref.kind,
               hasRangeMark(chars, from: prev.end, to: token.markerIndex) {
                let old = found[index].clue.numbers
                found[index].clue.numbers = min(old.lowerBound, token.ref.number)...max(old.upperBound, token.ref.number)
                continue
            }
            found.append((token.start, IssueRefClue(numbers: token.ref.number...token.ref.number,
                                                     kind: token.ref.kind, source: .name(qualifier))))
            previousClueIndex = found.count - 1
        }
        found.append(contentsOf: urlClues(in: text))
        return found.enumerated()
            .sorted { ($0.element.position, $0.offset) < ($1.element.position, $1.offset) }
            .map { $0.element.clue }
    }

    static func mentionedNames(in text: String) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for token in tokens(in: Array(text)) {
            guard let name = token.ref.qualifier?.name, seen.insert(name).inserted else { continue }
            names.append(name)
        }
        return names
    }

    // MARK: Scanning

    private static let inheritSeparators: Set<Character> = ["~", "-", "–", "·", ",", "/", "、"]

    private static func isASCIIWordChar(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "_")
    }

    private static func isNameChar(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "_" || c == "-")
    }

    private static func isAlnum(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }

    private static func hasRangeMark(_ chars: [Character], from: Int, to: Int) -> Bool {
        guard from < to else { return false }
        return chars[from..<to].contains { $0 == "~" || $0 == "-" || $0 == "–" }
    }

    /// Longest valid name ending right before `end` (exclusive), as a start index.
    private static func nameStart(in chars: [Character], endingBefore end: Int) -> Int? {
        var begin = end
        while begin > 0, isNameChar(chars[begin - 1]) || chars[begin - 1] == "/" { begin -= 1 }
        while begin < end, !isAlnum(chars[begin]) { begin += 1 }
        guard begin < end else { return nil }
        // Each "/" separates non-empty segments; the first starts with an alphanumeric (ensured above).
        var segmentLength = 0
        for c in chars[begin..<end] {
            if c == "/" {
                if segmentLength == 0 { return nil }
                segmentLength = 0
            } else {
                segmentLength += 1
            }
        }
        return segmentLength == 0 ? nil : begin
    }

    private static func tokens(in chars: [Character]) -> [Token] {
        var result: [Token] = []
        var i = 0
        while i < chars.count {
            let marker = chars[i]
            guard marker == "#" || marker == "!" else { i += 1; continue }
            var j = i + 1
            while j < chars.count, j - i - 1 < 7, chars[j].isASCII, chars[j].isNumber { j += 1 }
            let digitCount = j - i - 1
            guard digitCount >= 1,
                  let number = Int(String(chars[(i + 1)..<j])),
                  !(j < chars.count && isASCIIWordChar(chars[j])) else { i += 1; continue }

            var kind: IssueRefKind = marker == "!" ? .mergeRequest : .issue
            var qualifier: IssueRefQualifier?
            var start = i
            if let nameBegin = nameStart(in: chars, endingBefore: i) {
                let name = String(chars[nameBegin..<i])
                start = nameBegin
                apply(name: name, joined: true, kind: &kind, qualifier: &qualifier)
            } else if i == 0 || !(isASCIIWordChar(chars[i - 1]) || chars[i - 1] == "/") {
                var gap = i
                while gap > 0, chars[gap - 1].isWhitespace { gap -= 1 }
                if gap < i, gap > 0, let nameBegin = nameStart(in: chars, endingBefore: gap) {
                    apply(name: String(chars[nameBegin..<gap]), joined: false, kind: &kind, qualifier: &qualifier)
                }
            } else {
                i = j
                continue
            }

            var inherited = false
            if qualifier == nil, let prev = result.last, let prevQualifier = prev.ref.qualifier,
               start >= prev.end,
               chars[prev.end..<start].allSatisfy({ $0.isWhitespace || inheritSeparators.contains($0) }) {
                qualifier = prevQualifier
                inherited = true
            }
            result.append(Token(ref: IssueRef(number: number, kind: kind, qualifier: qualifier),
                                start: start, end: j, markerIndex: i, inherited: inherited))
            i = j
        }
        return result
    }

    private static func apply(name: String, joined: Bool, kind: inout IssueRefKind,
                              qualifier: inout IssueRefQualifier?) {
        let lower = name.lowercased()
        if stopWords.contains(lower) {
            if lower == "mr" { kind = .mergeRequest }
        } else {
            qualifier = joined ? .joined(name) : .spaced(name)
        }
    }

    // MARK: URL clues

    private static let urlPattern = try! NSRegularExpression(
        pattern: #"(https?)://([A-Za-z0-9.-]+(?::[0-9]+)?)/([A-Za-z0-9._~/-]+?)/(?:-/)?(issues|pull|merge_requests)/([0-9]+)"#)

    private static func urlClues(in text: String) -> [(position: Int, clue: IssueRefClue)] {
        let whole = NSRange(text.startIndex..., in: text)
        var out: [(position: Int, clue: IssueRefClue)] = []
        for match in urlPattern.matches(in: text, range: whole) {
            func group(_ n: Int) -> String? {
                Range(match.range(at: n), in: text).map { String(text[$0]) }
            }
            guard let scheme = group(1), let host = group(2), let path = group(3),
                  let tail = group(4), let numberText = group(5), let number = Int(numberText),
                  let repo = RepoWebURL(remote: "\(scheme)://\(host)/\(path)"),
                  let full = Range(match.range, in: text) else { continue }
            let position = text.distance(from: text.startIndex, to: full.lowerBound)
            let kind: IssueRefKind = tail == "merge_requests" ? .mergeRequest : .issue
            out.append((position, IssueRefClue(numbers: number...number, kind: kind, source: .url(repo))))
        }
        return out
    }
}
