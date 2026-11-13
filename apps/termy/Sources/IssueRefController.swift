// IssueRefController.swift
//
// Cmd+click한 issue 참조(`#1300`, `fl#45`, `bdrive-core #26`)를 받아 어느 프로젝트로 열지 정하고
// 브라우저로 열거나 메뉴를 띄운다. 화면 텍스트는 TermyTerminalView가, 저장소 목록은 KnownRepoIndex
// actor가, 결정은 IssueRefResolver가 맡는다.

import AppKit

/// Cmd+click한 자리의 화면 텍스트.
struct IssueRefScreenContext: Equatable, Sendable {
    /// 클릭한 행과 wrap으로 이어진 행들을 합친 텍스트.
    var text: String
    /// `text` 안에서 클릭한 글자의 Character offset.
    var clickOffset: Int
    /// `text`의 첫 행 위의 모든 행. 오래된 것 먼저.
    var linesAbove: [String]
}

struct IssueRefClick: Sendable {
    var hit: IssueRefHit
    var screen: IssueRefScreenContext
    var forceMenu: Bool
    var anchorScreenPoint: NSPoint
}

@MainActor
final class IssueRefController {
    static let shared = IssueRefController(
        index: .shared,
        memory: .shared,
        openURL: { NSWorkspace.shared.open($0) },
        presentMenu: { request, allRepos, point, onPick in
            IssueRefPickerPanel.shared.present(request: request, allRepos: allRepos, at: point, onPick: onPick)
        },
        beep: { NSSound.beep() }
    )

    /// "근처" 이름을 찾는 클릭한 줄 위 행 수.
    nonisolated static let nearbyRows = 20

    private let index: KnownRepoIndex
    private let memory: IssueRefMemory
    private let openURL: (URL) -> Void
    private let presentMenu: (IssueRefMenuRequest, [RepoWebURL], NSPoint, @escaping (RepoWebURL) -> Void) -> Void
    private let beep: () -> Void

    init(
        index: KnownRepoIndex,
        memory: IssueRefMemory,
        openURL: @escaping (URL) -> Void,
        presentMenu: @escaping (IssueRefMenuRequest, [RepoWebURL], NSPoint, @escaping (RepoWebURL) -> Void) -> Void,
        beep: @escaping () -> Void
    ) {
        self.index = index
        self.memory = memory
        self.openURL = openURL
        self.presentMenu = presentMenu
        self.beep = beep
    }

    func handle(_ click: IssueRefClick, paneId: String?, paneRoots: [String]) async {
        let paneRepos = await index.paneRepos(roots: paneRoots)
        var snapshot = await index.snapshot()
        let ctx = Self.context(for: click, paneId: paneId, paneRepos: paneRepos)
        var decision = IssueRefResolver.decide(ctx, index: snapshot, memory: memory.snapshot)
        // 목록을 만든 뒤에 clone한 저장소일 수 있으니, 이 참조를 가리키는 이름을 모르면 한 번만 다시 만든다.
        if case .menu = decision, hasUnknownName(ctx, in: snapshot) {
            snapshot = await index.rebuild()
            decision = IssueRefResolver.decide(ctx, index: snapshot, memory: memory.snapshot)
        }
        switch decision {
        case .open(let url, let repo):
            memory.noteOpened(repo)
            openURL(url)
        case .menu(let request):
            let allRepos = menuRepos(snapshot: snapshot, paneRepos: paneRepos)
            presentMenu(request, allRepos, click.anchorScreenPoint) { repo in
                self.applyPick(repo, request: request)
            }
        case .beep:
            beep()
        }
    }

    func applyPick(_ repo: RepoWebURL, request: IssueRefMenuRequest) {
        switch request.saveTarget {
        case .alias(let name): memory.setAlias(name, to: repo)
        case .pick(let key): memory.setPick(repo, for: key)
        case .none: break
        }
        memory.noteOpened(repo)
        openURL(repo.url(number: request.number, kind: request.kind))
    }

    /// 참조에 붙은 이름이나 같은 번호를 가리키는 단서의 이름 중 목록에도 줄임말에도 없는 것이 있는가.
    /// 다른 번호 앞의 낱말(`Task #3`, `see #12`)은 보지 않는다. 그런 낱말 때문에 메뉴마다 다시 만들지 않게.
    private func hasUnknownName(_ ctx: IssueRefContext, in snapshot: KnownRepoSnapshot) -> Bool {
        let ref = ctx.ref
        var names: [String] = []
        if let name = ref.qualifier?.name { names.append(name) }
        for clue in ctx.clues where clue.kind == ref.kind && clue.numbers.contains(ref.number) {
            if case .name(let qualifier) = clue.source { names.append(qualifier.name) }
        }
        return names.contains { snapshot.repos(named: $0).isEmpty && memory.alias($0) == nil }
    }

    /// 메뉴 검색 대상: ⌘K 목록, 줄임말 대상, 이 pane의 repo(⌘K 목록 밖일 수 있다). web URL로 중복 제거.
    private func menuRepos(snapshot: KnownRepoSnapshot, paneRepos: [KnownRepo]) -> [RepoWebURL] {
        var seen = Set<RepoWebURL>()
        let all = snapshot.repos.map(\.web) + memory.aliases.map(\.repo) + paneRepos.map(\.web)
        return all.filter { seen.insert($0).inserted }
    }

    /// 단서는 클릭한 텍스트의 참조 앞부분과 그 위 행들에서, 아래 줄부터 · 한 줄 안에서는 오른쪽부터.
    /// 근처 이름은 클릭한 텍스트 전체, 그다음 위 `nearbyRows`행을 아래부터.
    nonisolated static func context(for click: IssueRefClick, paneId: String?,
                                    paneRepos: [KnownRepo]) -> IssueRefContext {
        let text = click.screen.text
        let above = click.screen.linesAbove
        let before = String(text.prefix(click.hit.start))

        var clues: [IssueRefClue] = []
        for line in [before] + above.reversed() {
            clues += IssueRefParser.clues(in: line).reversed()
        }

        var nearbyNames: [String] = []
        for line in [text] + above.suffix(nearbyRows).reversed() {
            for name in IssueRefParser.mentionedNames(in: line) where !nearbyNames.contains(name) {
                nearbyNames.append(name)
            }
        }

        return IssueRefContext(ref: click.hit.ref, paneId: paneId, paneRepos: paneRepos,
                               clues: clues, nearbyNames: nearbyNames, forceMenu: click.forceMenu)
    }
}
