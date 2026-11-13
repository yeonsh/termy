import Foundation

enum IssueRefCandidateTag: Equatable, Sendable {
    case thisPane, sameLine, recent
}

struct IssueRefCandidate: Equatable, Sendable {
    var repo: RepoWebURL
    var tag: IssueRefCandidateTag?
}

enum IssueRefSaveTarget: Equatable, Sendable {
    case none
    case alias(String)
    case pick(IssueRefPickKey)
}

struct IssueRefMenuRequest: Equatable, Sendable {
    var title: String
    var number: Int
    var kind: IssueRefKind
    var candidates: [IssueRefCandidate]
    var limitToCandidates: Bool
    var saveTarget: IssueRefSaveTarget
}

enum IssueRefDecision: Equatable, Sendable {
    case open(URL, repo: RepoWebURL)
    case menu(IssueRefMenuRequest)
    case beep
}

struct IssueRefContext: Sendable {
    var ref: IssueRef
    var paneId: String?
    var paneRepos: [KnownRepo]
    /// 가까운 것 먼저
    var clues: [IssueRefClue]
    /// 가까운 것 먼저
    var nearbyNames: [String]
    var forceMenu: Bool
}

enum IssueRefResolver {
    static let maxInitialCandidates = 6

    static func isStrong(name: String, paneRepos: [KnownRepo], aliases: [String: RepoWebURL]) -> Bool {
        if aliases[name.lowercased()] != nil { return true }
        if name.contains(where: { $0 == "-" || $0 == "_" || $0 == "." || $0 == "/" || $0.isNumber }) {
            return true
        }
        return !KnownRepoSnapshot(repos: paneRepos).repos(named: name).isEmpty
    }

    static func names(in ctx: IssueRefContext) -> [String] {
        var result: [String] = []
        func add(_ name: String) { if !result.contains(name) { result.append(name) } }
        if let name = ctx.ref.qualifier?.name { add(name) }
        for clue in ctx.clues {
            if case .name(let qualifier) = clue.source { add(qualifier.name) }
        }
        return result
    }

    static func decide(_ ctx: IssueRefContext, index: KnownRepoSnapshot,
                       memory: IssueRefMemorySnapshot) -> IssueRefDecision {
        let ref = ctx.ref
        let sigil = ref.kind == .mergeRequest ? "!" : "#"
        let n = ref.number
        let paneIndex = KnownRepoSnapshot(repos: ctx.paneRepos)
        let key: IssueRefSaveTarget = ctx.paneId.map {
            .pick(IssueRefPickKey(paneId: $0, number: n, kind: ref.kind))
        } ?? .none
        let pickKey: IssueRefPickKey? = ctx.paneId.map { IssueRefPickKey(paneId: $0, number: n, kind: ref.kind) }

        func matching(_ name: String) -> [RepoWebURL] {
            var seen = Set<RepoWebURL>()
            let all = index.repos(named: name) + paneIndex.repos(named: name)
            return all.filter { seen.insert($0).inserted }
        }
        func resolve(_ name: String) -> (repos: [RepoWebURL], viaAlias: Bool) {
            if let alias = memory.aliases[name.lowercased()] { return ([alias], true) }
            return (matching(name), false)
        }
        func open(_ repo: RepoWebURL) -> IssueRefDecision {
            .open(repo.url(number: n, kind: ref.kind), repo: repo)
        }
        func defaults() -> [IssueRefCandidate] {
            var seen = Set<RepoWebURL>()
            var list: [IssueRefCandidate] = []
            func add(_ repo: RepoWebURL, _ tag: IssueRefCandidateTag) {
                if seen.insert(repo).inserted { list.append(IssueRefCandidate(repo: repo, tag: tag)) }
            }
            for repo in ctx.paneRepos { add(repo.web, .thisPane) }
            for name in ctx.nearbyNames { for repo in resolve(name).repos { add(repo, .sameLine) } }
            for repo in memory.recents { add(repo, .recent) }
            return Array(list.prefix(maxInitialCandidates))
        }
        func menu(_ candidates: [IssueRefCandidate], title: String? = nil, limit: Bool = false,
                  save: IssueRefSaveTarget) -> IssueRefDecision {
            .menu(IssueRefMenuRequest(title: title ?? "Open \(sigil)\(n) in…", number: n, kind: ref.kind,
                                      candidates: candidates, limitToCandidates: limit, saveTarget: save))
        }
        func xFirst(_ xs: [RepoWebURL], save: IssueRefSaveTarget) -> IssueRefDecision {
            var seen = Set<RepoWebURL>()
            var list = xs.filter { seen.insert($0).inserted }.map { IssueRefCandidate(repo: $0, tag: nil) }
            for c in defaults() where seen.insert(c.repo).inserted { list.append(c) }
            return menu(Array(list.prefix(maxInitialCandidates)), save: save)
        }
        func limited(_ repos: [RepoWebURL], name: String) -> IssueRefDecision {
            menu(repos.map { IssueRefCandidate(repo: $0, tag: nil) }, limit: true, save: .alias(name))
        }
        /// 줄임말로 정한 이름: 그냥 클릭은 줄임말 대상을 열고, ⌥⌘는 줄임말을 고쳐 쓸 메뉴를 띄운다.
        /// 메뉴에는 줄임말 대상 다음에 같은 이름의 다른 저장소를 둔다. 줄임말을 고른 원래 후보들이다.
        func aliased(_ target: RepoWebURL, name: String) -> IssueRefDecision {
            ctx.forceMenu ? xFirst([target] + matching(name), save: .alias(name)) : open(target)
        }

        var qualifier = ref.qualifier
        if case .joined(let name)? = qualifier {
            let found = resolve(name)
            if found.viaAlias { return aliased(found.repos[0], name: name) }
            switch found.repos.count {
            case 1: return ctx.forceMenu ? xFirst(found.repos, save: .none) : open(found.repos[0])
            case 0:
                return menu(defaults(), title: "\(name)\(sigil)\(n) — which project is “\(name)”?", save: .alias(name))
            default: return limited(found.repos, name: name)
            }
        }
        if case .spaced(let name)? = qualifier {
            let found = resolve(name)
            if found.viaAlias { return aliased(found.repos[0], name: name) }
            switch found.repos.count {
            case 0: qualifier = nil
            case 1:
                if !ctx.forceMenu,
                   isStrong(name: name, paneRepos: ctx.paneRepos, aliases: memory.aliases) {
                    return open(found.repos[0])
                }
                return xFirst(found.repos, save: .none)
            default:
                if isStrong(name: name, paneRepos: ctx.paneRepos, aliases: memory.aliases) {
                    return limited(found.repos, name: name)
                }
                // 약한 이름(일반 낱말)은 줄임말로 저장하지 않는다.
                return xFirst(found.repos, save: .none)
            }
        }

        if !ctx.forceMenu, let pickKey, let picked = memory.picks[pickKey] { return open(picked) }

        // 3·4에서 열었을 프로젝트(들)
        var clueRepos: [RepoWebURL] = []
        var clueDirect = false
        for clue in ctx.clues where clue.kind == ref.kind && clue.numbers.contains(n) {
            switch clue.source {
            case .url(let repo):
                clueRepos = [repo]; clueDirect = true
            case .name(let q):
                let found = resolve(q.name)
                if found.repos.isEmpty { continue }
                clueRepos = found.repos
                if found.repos.count == 1 {
                    if found.viaAlias { clueDirect = true }
                    else if case .joined = q { clueDirect = true }
                    else { clueDirect = isStrong(name: q.name, paneRepos: ctx.paneRepos, aliases: memory.aliases) }
                }
            }
            break
        }

        if !ctx.forceMenu {
            if !clueRepos.isEmpty {
                return clueDirect ? open(clueRepos[0]) : xFirst(clueRepos, save: key)
            }
        } else {
            var x: [RepoWebURL] = clueRepos
            if let pickKey, let picked = memory.picks[pickKey] { x = [picked] }
            if !x.isEmpty { return xFirst(x, save: key) }
        }

        let initial = defaults()
        if initial.isEmpty && index.repos.isEmpty { return .beep }
        return menu(initial, save: key)
    }
}
