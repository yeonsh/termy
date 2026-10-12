// MarkdownHTMLRenderer.swift
//
// Turns a markdown file into the HTML document the preview window shows.
// swift-markdown (cmark-gfm) parses; the HTML writer is ours because
// swift-markdown 0.9.0's `HTMLFormatter` writes text, inline code and code
// blocks without escaping them and emits headings without ids. Everything
// that came from the file — raw HTML included — is escaped, so the page
// shows exactly what the agent wrote and never interprets it.

import Foundation
import Markdown

enum MarkdownHTMLRenderer {
    /// Complete HTML document for the preview web view. `banner`, when set,
    /// is shown above the body (e.g. the file was deleted).
    static func document(markdown: String, title: String, banner: String? = nil) -> String {
        var html = """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <meta name="color-scheme" content="light dark">
        <title>\(escape(title))</title>
        <style>\(MarkdownPreviewStyle.css)</style>
        </head><body><main class="markdown-body">

        """
        if let banner {
            html += "<div class=\"preview-banner\">\(escape(banner))</div>\n"
        }
        html += body(markdown: markdown)
        html += "</main></body></html>\n"
        return html
    }

    /// HTML for the markdown body alone.
    static func body(markdown: String) -> String {
        var writer = MarkdownHTMLWriter()
        writer.visit(Document(parsing: markdown))
        return writer.result
    }

    /// Escapes the five HTML-significant characters; safe for text content
    /// and for quoted attribute values.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        // Scalars, not Characters: a special character followed by a combining
        // mark is one grapheme cluster that would match no case below.
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// GitHub-style heading anchor: lowercased; letters and digits of any
    /// script, `-` and `_` kept; spaces become `-`; everything else dropped.
    static func slug(for text: String) -> String {
        var out = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                out.unicodeScalars.append(scalar)
            } else if scalar == " " {
                out += "-"
            }
        }
        return out
    }
}

/// Walks a swift-markdown tree and appends HTML to `result`.
struct MarkdownHTMLWriter: MarkupWalker {
    private(set) var result = ""
    /// Uses per heading slug, for GitHub's `-1`, `-2` de-duplication.
    private var slugCounts: [String: Int] = [:]
    private var columnAlignments: [Table.ColumnAlignment?] = []
    private var inTableHead = false
    private var cellIndex = 0

    private mutating func wrap(_ tag: String, _ markup: Markup, attributes: String = "") {
        result += "<\(tag)\(attributes)>"
        descendInto(markup)
        result += "</\(tag)>"
    }

    private static func escape(_ text: String) -> String {
        MarkdownHTMLRenderer.escape(text)
    }

    // MARK: Blocks

    mutating func visitParagraph(_ paragraph: Paragraph) {
        wrap("p", paragraph)
        result += "\n"
    }

    mutating func visitHeading(_ heading: Heading) {
        let base = MarkdownHTMLRenderer.slug(for: heading.plainText)
        let uses = slugCounts[base, default: 0]
        slugCounts[base] = uses + 1
        let id = uses == 0 ? base : "\(base)-\(uses)"
        wrap("h\(heading.level)", heading, attributes: " id=\"\(Self.escape(id))\"")
        result += "\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        result += "<blockquote>\n"
        descendInto(blockQuote)
        result += "</blockquote>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        var classAttribute = ""
        if let language = codeBlock.language, !language.isEmpty {
            classAttribute = " class=\"language-\(Self.escape(language))\""
        }
        result += "<pre><code\(classAttribute)>\(Self.escape(codeBlock.code))</code></pre>\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        result += "<p class=\"raw-html\">\(Self.escape(html.rawHTML))</p>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        result += "<hr>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        result += "<ul>\n"
        descendInto(unorderedList)
        result += "</ul>\n"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        let start = orderedList.startIndex == 1 ? "" : " start=\"\(orderedList.startIndex)\""
        result += "<ol\(start)>\n"
        descendInto(orderedList)
        result += "</ol>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) {
        if let checkbox = listItem.checkbox {
            let checked = checkbox == .checked ? " checked" : ""
            result += "<li class=\"task-list-item\"><input type=\"checkbox\" disabled\(checked)> "
        } else {
            result += "<li>"
        }
        descendInto(listItem)
        result += "</li>\n"
    }

    // MARK: Tables

    mutating func visitTable(_ table: Table) {
        columnAlignments = table.columnAlignments
        result += "<table>\n"
        descendInto(table)
        result += "</table>\n"
    }

    mutating func visitTableHead(_ tableHead: Table.Head) {
        inTableHead = true
        cellIndex = 0
        result += "<thead><tr>"
        descendInto(tableHead)
        result += "</tr></thead>\n"
        inTableHead = false
    }

    mutating func visitTableBody(_ tableBody: Table.Body) {
        guard tableBody.childCount > 0 else { return }
        result += "<tbody>\n"
        descendInto(tableBody)
        result += "</tbody>\n"
    }

    mutating func visitTableRow(_ tableRow: Table.Row) {
        cellIndex = 0
        result += "<tr>"
        descendInto(tableRow)
        result += "</tr>\n"
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) {
        var style = ""
        if cellIndex < columnAlignments.count, let alignment = columnAlignments[cellIndex] {
            switch alignment {
            case .left: style = " style=\"text-align: left\""
            case .center: style = " style=\"text-align: center\""
            case .right: style = " style=\"text-align: right\""
            }
        }
        cellIndex += 1
        wrap(inTableHead ? "th" : "td", tableCell, attributes: style)
    }

    // MARK: Inlines

    mutating func visitText(_ text: Text) {
        result += Self.escape(text.string)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        result += "<code>\(Self.escape(inlineCode.code))</code>"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        wrap("em", emphasis)
    }

    mutating func visitStrong(_ strong: Strong) {
        wrap("strong", strong)
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        wrap("del", strikethrough)
    }

    mutating func visitLink(_ link: Link) {
        wrap("a", link, attributes: " href=\"\(Self.escape(link.destination ?? ""))\"")
    }

    mutating func visitImage(_ image: Image) {
        let alt = image.plainText.isEmpty ? (image.source ?? "") : image.plainText
        result += "<span class=\"image-alt\">[image: \(Self.escape(alt))]</span>"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        result += Self.escape(inlineHTML.rawHTML)
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        result += "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        result += "<br>\n"
    }
}
