import Foundation

enum IssueRefKind: String, Codable, Sendable {
    case issue
    case mergeRequest
}

/// A repository's web identity: host and path only. Credentials in the
/// original remote URL are dropped at construction and never stored.
struct RepoWebURL: Hashable, Codable, Sendable {
    let host: String
    let path: String

    init?(remote: String) {
        let text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var hostPart: String
        var pathPart: String
        if let schemeRange = text.range(of: "://") {
            let scheme = text[..<schemeRange.lowerBound].lowercased()
            guard ["http", "https", "ssh", "git"].contains(scheme) else { return nil }
            let rest = text[schemeRange.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            var authority = String(rest[..<slash])
            pathPart = String(rest[rest.index(after: slash)...])
            if let at = authority.lastIndex(of: "@") {
                authority = String(authority[authority.index(after: at)...])
            }
            if let colon = authority.firstIndex(of: ":") {
                authority = String(authority[..<colon])
            }
            hostPart = authority
        } else {
            // scp-like: [user@]host:path
            guard !text.hasPrefix("/"), !text.hasPrefix("."),
                  let colon = text.firstIndex(of: ":") else { return nil }
            var authority = String(text[..<colon])
            pathPart = String(text[text.index(after: colon)...])
            if let at = authority.lastIndex(of: "@") {
                authority = String(authority[authority.index(after: at)...])
            }
            guard !authority.contains("/") else { return nil }
            hostPart = authority
        }
        self.init(host: hostPart, rawPath: pathPart)
    }

    init?(storageKey: String) {
        guard let slash = storageKey.firstIndex(of: "/") else { return nil }
        self.init(host: String(storageKey[..<slash]),
                  rawPath: String(storageKey[storageKey.index(after: slash)...]))
    }

    private init?(host: String, rawPath: String) {
        var path = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let host = host.lowercased()
        guard !host.isEmpty, !path.isEmpty else { return nil }
        self.host = host
        self.path = path
    }

    var storageKey: String { "\(host)/\(path)" }

    var name: String { path.split(separator: "/").last.map(String.init) ?? path }

    var displayOwner: String {
        let parts = path.split(separator: "/").dropLast()
        return ([host] + parts.map(String.init)).joined(separator: "/")
    }

    var isGitHub: Bool { host == "github.com" }

    func url(number: Int, kind: IssueRefKind) -> URL {
        let tail: String
        switch (isGitHub, kind) {
        case (true, .issue): tail = "issues"
        case (true, .mergeRequest): tail = "pull"
        case (false, .issue): tail = "-/issues"
        case (false, .mergeRequest): tail = "-/merge_requests"
        }
        return URL(string: "https://\(host)/\(path)/\(tail)/\(number)")!
    }

    /// Resolves a relative submodule URL (`../x.git`, `./x`) the way git does:
    /// against this repository's own remote path.
    func resolving(relative: String) -> RepoWebURL? {
        var parts = path.split(separator: "/").map(String.init)
        for component in relative.split(separator: "/").map(String.init) {
            switch component {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(component)
            }
        }
        return RepoWebURL(host: host, rawPath: parts.joined(separator: "/"))
    }
}
