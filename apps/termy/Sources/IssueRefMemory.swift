import Foundation

struct IssueRefPickKey: Hashable, Sendable {
    let paneId: String
    let number: Int
    let kind: IssueRefKind
}

struct IssueRefAlias: Equatable, Sendable {
    let name: String
    let repo: RepoWebURL
}

/// Plain value copy of the memory, readable off the main actor.
struct IssueRefMemorySnapshot: Sendable {
    var aliases: [String: RepoWebURL]
    var picks: [IssueRefPickKey: RepoWebURL]
    var recents: [RepoWebURL]

    init(aliases: [String: RepoWebURL] = [:],
         picks: [IssueRefPickKey: RepoWebURL] = [:],
         recents: [RepoWebURL] = []) {
        self.aliases = aliases
        self.picks = picks
        self.recents = recents
    }
}

/// Remembers aliases and recent projects (persisted as `host/path` strings)
/// and per-pane picks (memory only).
@MainActor
final class IssueRefMemory {
    static let shared = IssueRefMemory(defaults: .standard)
    static let aliasesKey = "termy.issueRef.aliases"
    static let recentsKey = "termy.issueRef.recents"
    static let maxRecents = 5

    private let defaults: UserDefaults
    private var picks: [IssueRefPickKey: RepoWebURL] = [:]

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private var storedAliases: [String: RepoWebURL] {
        let raw = defaults.dictionary(forKey: Self.aliasesKey) as? [String: String] ?? [:]
        return raw.compactMapValues { RepoWebURL(storageKey: $0) }
    }

    func alias(_ name: String) -> RepoWebURL? {
        storedAliases[name.lowercased()]
    }

    func setAlias(_ name: String, to repo: RepoWebURL) {
        var raw = defaults.dictionary(forKey: Self.aliasesKey) as? [String: String] ?? [:]
        raw[name.lowercased()] = repo.storageKey
        defaults.set(raw, forKey: Self.aliasesKey)
    }

    func removeAlias(_ name: String) {
        var raw = defaults.dictionary(forKey: Self.aliasesKey) as? [String: String] ?? [:]
        raw.removeValue(forKey: name.lowercased())
        defaults.set(raw, forKey: Self.aliasesKey)
    }

    var aliases: [IssueRefAlias] {
        storedAliases
            .map { IssueRefAlias(name: $0.key, repo: $0.value) }
            .sorted { $0.name < $1.name }
    }

    func setPick(_ repo: RepoWebURL, for key: IssueRefPickKey) {
        picks[key] = repo
    }

    var recents: [RepoWebURL] {
        let raw = defaults.stringArray(forKey: Self.recentsKey) ?? []
        return raw.compactMap { RepoWebURL(storageKey: $0) }
    }

    func noteOpened(_ repo: RepoWebURL) {
        var list = recents.filter { $0 != repo }
        list.insert(repo, at: 0)
        defaults.set(list.prefix(Self.maxRecents).map(\.storageKey), forKey: Self.recentsKey)
    }

    var snapshot: IssueRefMemorySnapshot {
        IssueRefMemorySnapshot(aliases: storedAliases, picks: picks, recents: recents)
    }
}
