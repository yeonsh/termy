// MarkdownLinkResolver.swift
//
// Decides whether a Cmd+clicked terminal link names a markdown file termy
// should preview, and which file on disk that is. SwiftTerm hands over the
// raw matched text — `docs/x.md`, `./x.md:12`, `file:///…/x.md`, often with
// prose punctuation stuck to it — and a relative path is relative to
// whatever cwd the agent printed it from, so callers pass candidate base
// directories in priority order and the first one holding the file wins.

import Foundation

enum MarkdownLinkResolution: Equatable {
    /// Not a markdown link; the caller falls back to its URL handling.
    case notMarkdown
    /// Shaped like a markdown path, but no such file exists.
    case missing
    /// The markdown file to open, symlinks resolved.
    case file(URL)
}

enum MarkdownLinkResolver {
    static let extensions: Set<String> = ["md", "markdown"]

    private static let leadingPunctuation: Set<Character> = ["(", "[", "`", "'", "\""]
    private static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "`", "'", "\""]

    static func resolve(
        linkText: String,
        baseDirectories: [String],
        homeDirectory: String,
        isRegularFile: (String) -> Bool
    ) -> MarkdownLinkResolution {
        guard let path = markdownPath(from: linkText) else { return .notMarkdown }

        let candidates: [String]
        if path.hasPrefix("~/") {
            candidates = [(homeDirectory as NSString).appendingPathComponent(String(path.dropFirst(2)))]
        } else if path.hasPrefix("/") {
            candidates = [path]
        } else {
            var seen = Set<String>()
            candidates = baseDirectories
                .filter { !$0.isEmpty && seen.insert($0).inserted }
                .map { ($0 as NSString).appendingPathComponent(path) }
        }

        for candidate in candidates {
            let standardized = (candidate as NSString).standardizingPath
            if isRegularFile(standardized) {
                return .file(URL(fileURLWithPath: standardized).resolvingSymlinksInPath())
            }
        }
        return .missing
    }

    /// The path in `linkText` when it names a markdown file: surrounding
    /// punctuation, `file://`, `#fragment` and `:line[:col]` removed. nil
    /// for any other extension and for web URLs.
    static func markdownPath(from linkText: String) -> String? {
        var text = Substring(linkText.trimmingCharacters(in: .whitespacesAndNewlines))
        while let first = text.first, leadingPunctuation.contains(first) {
            text = text.dropFirst()
        }
        while let last = text.last, trailingPunctuation.contains(last) {
            text = text.dropLast()
        }

        var path = String(text)
        if path.lowercased().hasPrefix("file://") {
            guard let url = URL(string: path), url.isFileURL else { return nil }
            path = url.path
        } else if path.contains("://") {
            // `https://…/README.md` is a web page, not a local file.
            return nil
        } else if let hash = path.firstIndex(of: "#") {
            path = String(path[..<hash])
        }
        path = stripLineSuffix(path)

        guard extensions.contains((path as NSString).pathExtension.lowercased()) else { return nil }
        return path
    }

    /// `isRegularFile` for real use: something exists at `path` and it is
    /// not a directory.
    static func fileExistsAsRegularFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// Drops an editor-style `:12` or `:12:3` suffix.
    private static func stripLineSuffix(_ path: String) -> String {
        var result = Substring(path)
        for _ in 0..<2 {
            guard let colon = result.lastIndex(of: ":") else { break }
            let tail = result[result.index(after: colon)...]
            guard !tail.isEmpty, tail.allSatisfy({ $0.isASCII && $0.isNumber }) else { break }
            result = result[..<colon]
        }
        return String(result)
    }
}
