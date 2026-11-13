import Foundation

struct IssueRefPickerRow: Equatable {
    enum Action: Equatable {
        case pick(RepoWebURL)
        case showAll
    }

    let action: Action
    let title: String
    let tagLabel: String?
    let detail: String
}

/// 프로젝트 고르는 메뉴의 줄 목록을 정하는 순수 모델.
struct IssueRefPickerModel {
    static let maxSearchResults = 12
    static let showAllTitle = "Show All Projects…"

    private let request: IssueRefMenuRequest
    private let allRepos: [RepoWebURL]

    init(request: IssueRefMenuRequest, allRepos: [RepoWebURL]) {
        self.request = request
        self.allRepos = allRepos
    }

    func rows(query: String, showAll: Bool) -> [IssueRefPickerRow] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if showAll {
                return universe().sorted(by: Self.byName).map { row($0, tag: tag(for: $0)) }
            }
            var rows = request.candidates.map { row($0.repo, tag: $0.tag) }
            if !request.limitToCandidates {
                rows.append(IssueRefPickerRow(action: .showAll, title: Self.showAllTitle, tagLabel: nil, detail: ""))
            }
            return rows
        }
        let scope = request.limitToCandidates ? request.candidates.map(\.repo) : universe()
        var scored: [(score: Int, repo: RepoWebURL)] = []
        for repo in scope {
            if let s = FuzzyMatch.score(query: trimmed, text: repo.name)
                ?? FuzzyMatch.score(query: trimmed, text: repo.storageKey) {
                scored.append((s, repo))
            }
        }
        scored.sort { l, r in
            l.score != r.score ? l.score < r.score : Self.byName(l.repo, r.repo)
        }
        return scored.prefix(Self.maxSearchResults).map { row($0.repo, tag: tag(for: $0.repo)) }
    }

    private func universe() -> [RepoWebURL] {
        var seen = Set<RepoWebURL>()
        return (allRepos + request.candidates.map(\.repo)).filter { seen.insert($0).inserted }
    }

    private func tag(for repo: RepoWebURL) -> IssueRefCandidateTag? {
        request.candidates.first { $0.repo == repo }?.tag
    }

    private static func byName(_ a: RepoWebURL, _ b: RepoWebURL) -> Bool {
        let c = a.name.localizedCaseInsensitiveCompare(b.name)
        if c != .orderedSame { return c == .orderedAscending }
        return a.storageKey < b.storageKey
    }

    private func row(_ repo: RepoWebURL, tag: IssueRefCandidateTag?) -> IssueRefPickerRow {
        let label: String?
        switch tag {
        case .thisPane: label = "this pane"
        case .sameLine: label = "same line"
        case .recent: label = "recent"
        case nil: label = nil
        }
        return IssueRefPickerRow(action: .pick(repo), title: repo.name, tagLabel: label, detail: repo.displayOwner)
    }
}
