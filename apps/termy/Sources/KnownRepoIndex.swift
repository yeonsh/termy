import Foundation

struct KnownRepo: Hashable, Sendable {
    let web: RepoWebURL
    let localPath: String
}

struct KnownRepoSnapshot: Sendable {
    let repos: [KnownRepo]

    init(repos: [KnownRepo]) {
        self.repos = repos
    }

    /// Repos whose web path, short name or local folder name equals `name`
    /// (case-insensitive), deduplicated by web URL.
    func repos(named name: String) -> [RepoWebURL] {
        let needle = name.lowercased()
        var seen = Set<RepoWebURL>()
        var result: [RepoWebURL] = []
        for repo in repos {
            let folder = (repo.localPath as NSString).lastPathComponent.lowercased()
            guard repo.web.path.lowercased() == needle
                    || repo.web.name.lowercased() == needle
                    || folder == needle else { continue }
            if seen.insert(repo.web).inserted { result.append(repo.web) }
        }
        return result
    }
}

enum KnownRepoDiscovery {
    private static func isGitRepo(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
    }

    private static func gitChildren(of dir: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names.sorted()
            .map { (dir as NSString).appendingPathComponent($0) }
            .filter(isGitRepo)
    }

    /// The repo at `root` (when it has a web URL) followed by its submodules.
    private static func repoWithSubmodules(root: String) -> [KnownRepo] {
        let web = GitRepoConfig.webURL(repoRoot: root)
        var result: [KnownRepo] = []
        if let web { result.append(KnownRepo(web: web, localPath: root)) }
        for sub in GitRepoConfig.submoduleWebURLs(repoRoot: root, parent: web) {
            result.append(KnownRepo(web: sub.web,
                                    localPath: (root as NSString).appendingPathComponent(sub.path)))
        }
        return result
    }

    private static func dedup(_ repos: [KnownRepo]) -> [KnownRepo] {
        var seen = Set<RepoWebURL>()
        return repos.filter { seen.insert($0.web).inserted }
    }

    static func discover(workspacePaths: [String]) -> [KnownRepo] {
        var all: [KnownRepo] = []
        for path in workspacePaths where path.hasPrefix("/") {
            if isGitRepo(path) {
                all += repoWithSubmodules(root: path)
                let parent = (path as NSString).deletingLastPathComponent
                for sibling in gitChildren(of: parent) where sibling != path {
                    if let web = GitRepoConfig.webURL(repoRoot: sibling) {
                        all.append(KnownRepo(web: web, localPath: sibling))
                    }
                }
            } else {
                for child in gitChildren(of: path) {
                    if let web = GitRepoConfig.webURL(repoRoot: child) {
                        all.append(KnownRepo(web: web, localPath: child))
                    }
                }
            }
        }
        return dedup(all)
    }

    static func paneRepos(roots: [String]) -> [KnownRepo] {
        dedup(roots.flatMap { repoWithSubmodules(root: $0) })
    }
}

actor KnownRepoIndex {
    static let shared = KnownRepoIndex(workspacePaths: {
        guard let persistence = try? WorkspacePersistence() else { return [] }
        return await persistence.all().map(\.canonicalPath)
    })

    private let workspacePaths: @Sendable () async -> [String]
    private var cached: KnownRepoSnapshot?

    init(workspacePaths: @escaping @Sendable () async -> [String]) {
        self.workspacePaths = workspacePaths
    }

    func snapshot() async -> KnownRepoSnapshot {
        if let cached { return cached }
        return await rebuild()
    }

    func rebuild() async -> KnownRepoSnapshot {
        let paths = await workspacePaths()
        let snap = KnownRepoSnapshot(repos: KnownRepoDiscovery.discover(workspacePaths: paths))
        cached = snap
        return snap
    }

    func paneRepos(roots: [String]) -> [KnownRepo] {
        KnownRepoDiscovery.paneRepos(roots: roots)
    }
}
