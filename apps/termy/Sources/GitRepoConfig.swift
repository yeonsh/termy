import Foundation

struct GitSubmodule: Equatable, Sendable {
    let path: String
    let url: String
}

/// Reads `.git/config` and `.gitmodules` as plain files (no git process).
enum GitRepoConfig {
    private struct Section {
        let kind: String
        let name: String
        var values: [String: String] = [:]
    }

    private static func sections(_ text: String) -> [Section] {
        var result: [Section] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let inner = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                if let q1 = inner.firstIndex(of: "\""), let q2 = inner.lastIndex(of: "\""), q1 < q2 {
                    let kind = inner[..<q1].trimmingCharacters(in: .whitespaces).lowercased()
                    result.append(Section(kind: kind, name: String(inner[inner.index(after: q1)..<q2])))
                } else {
                    result.append(Section(kind: inner.lowercased(), name: ""))
                }
            } else if !result.isEmpty, let eq = line.firstIndex(of: "="), !line.hasPrefix("#"), !line.hasPrefix(";") {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if result[result.count - 1].values[key] == nil {
                    result[result.count - 1].values[key] = value
                }
            }
        }
        return result
    }

    static func remoteURL(configText: String) -> String? {
        let remotes = sections(configText).filter { $0.kind == "remote" && $0.values["url"] != nil }
        if let origin = remotes.first(where: { $0.name == "origin" }) { return origin.values["url"] }
        return remotes.count == 1 ? remotes[0].values["url"] : nil
    }

    static func submodules(gitmodulesText: String) -> [GitSubmodule] {
        sections(gitmodulesText).compactMap { section in
            guard section.kind == "submodule",
                  let path = section.values["path"], let url = section.values["url"] else { return nil }
            return GitSubmodule(path: path, url: url)
        }
    }

    /// The config file that holds the remotes: handles a `.git` directory, a
    /// `.git` file (submodule / worktree) and a worktree's `commondir`.
    static func configPath(repoRoot: String) -> String? {
        let fm = FileManager.default
        let dotGit = (repoRoot as NSString).appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dotGit, isDirectory: &isDir) else { return nil }
        var gitDir = dotGit
        if !isDir.boolValue {
            guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
                  let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") })
            else { return nil }
            let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            gitDir = resolve(target, against: repoRoot)
        }
        if let common = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("commondir"), encoding: .utf8) {
            let trimmed = common.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { gitDir = resolve(trimmed, against: gitDir) }
        }
        let config = (gitDir as NSString).appendingPathComponent("config")
        return fm.fileExists(atPath: config) ? config : nil
    }

    private static func resolve(_ path: String, against base: String) -> String {
        let full = path.hasPrefix("/") ? path : (base as NSString).appendingPathComponent(path)
        return (full as NSString).standardizingPath
    }

    static func webURL(repoRoot: String) -> RepoWebURL? {
        guard let path = configPath(repoRoot: repoRoot),
              let text = try? String(contentsOfFile: path, encoding: .utf8),
              let remote = remoteURL(configText: text) else { return nil }
        return RepoWebURL(remote: remote)
    }

    static func submoduleWebURLs(repoRoot: String, parent: RepoWebURL?) -> [(path: String, web: RepoWebURL)] {
        let file = (repoRoot as NSString).appendingPathComponent(".gitmodules")
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        return submodules(gitmodulesText: text).compactMap { sub in
            let web: RepoWebURL?
            if sub.url.hasPrefix("./") || sub.url.hasPrefix("../") {
                web = parent?.resolving(relative: sub.url)
            } else {
                web = RepoWebURL(remote: sub.url)
            }
            return web.map { (path: sub.path, web: $0) }
        }
    }
}
