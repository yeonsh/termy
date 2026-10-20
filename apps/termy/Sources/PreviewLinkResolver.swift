// PreviewLinkResolver.swift
//
// Decides whether a Cmd+clicked terminal link names a markdown or PDF file
// termy should preview, and which file on disk that is. SwiftTerm hands over
// the raw matched text — `docs/x.md`, `./x.pdf:12`, `file:///…/x.md`, often
// with prose punctuation or the rest of a Korean sentence (`x.md에 저장했습니다.`)
// stuck to it — and a relative path is relative to whatever cwd the agent
// printed it from, so callers pass candidate base directories in priority
// order and the first one holding the file wins.

import Foundation

enum PreviewLinkResolution: Equatable {
    /// Not a markdown or PDF link; the caller falls back to its URL handling.
    case notPreviewable
    /// Shaped like a markdown or PDF path, but no such file exists.
    case missing
    /// The markdown or PDF file to open, symlinks resolved.
    case file(URL)
}

enum PreviewLinkResolver {
    static let extensions: Set<String> = ["md", "markdown", "pdf"]

    private static let leadingPunctuation: Set<Character> = ["(", "[", "`", "'", "\""]
    private static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "`", "'", "\""]

    /// Resolves `linkText` to a markdown or PDF file. A relative path is tried
    /// against `baseDirectories` in order and the first base holding the
    /// file wins, so callers list the most likely base first.
    static func resolve(
        linkText: String,
        baseDirectories: [String],
        homeDirectory: String,
        isRegularFile: (String) -> Bool
    ) -> PreviewLinkResolution {
        guard let path = previewPath(from: linkText) else { return .notPreviewable }

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

    /// The path in `linkText` when it names a markdown or PDF file: surrounding
    /// punctuation, `file://`, `#fragment`, `:line[:col]` and text glued
    /// after the extension removed. nil for any other extension and for
    /// web URLs.
    static func previewPath(from linkText: String) -> String? {
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

        if !hasPreviewExtension(path) {
            // SwiftTerm's path regex keeps matching into Hangul particles
            // (`\w`), `**`, and trailing words ending in `.`; cut at the
            // first .md/.markdown/.pdf that isn't followed by another file-name
            // character. A glued `:12에서` goes with the rest.
            guard let range = path.range(
                of: #"^.*?\.(md|markdown|pdf)(?![A-Za-z0-9._/-])"#,
                options: [.regularExpression, .caseInsensitive]
            ) else { return nil }
            path = String(path[range])
        }
        guard hasPreviewExtension(path) else { return nil }
        return path
    }

    /// `isRegularFile` for real use: `path`, symlinks followed, is a
    /// regular file. A FIFO or device named `x.md` would block the
    /// synchronous read on the main thread.
    static func fileExistsAsRegularFile(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    private static func hasPreviewExtension(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
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

/// Which preview window a file opens in, by extension.
enum PreviewKind: Equatable {
    case markdown
    case pdf

    init?(fileURL: URL) {
        switch fileURL.pathExtension.lowercased() {
        case "md", "markdown": self = .markdown
        case "pdf": self = .pdf
        default: return nil
        }
    }
}
