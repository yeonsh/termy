// MarkdownPreviewWebView.swift
//
// The preview's WKWebView, plus one job WebKit won't do: open markdown
// files dropped onto it. Apps built against current SDKs get WKWebView's
// `DropToNavigateDisallowedByDefault` behavior — the "load" drop action is
// masked off — so a dropped file never becomes a navigation that
// `MarkdownPreviewWindowController.route` could send to a preview. File
// drops are handled here instead; every other drag is left to WebKit.

import AppKit
import WebKit

final class MarkdownPreviewWebView: WKWebView {
    /// Opens dropped markdown files. Set by the preview controller.
    var onDropMarkdownFiles: (([URL]) -> Void)?

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let files = Self.fileURLs(on: sender.draggingPasteboard) else {
            return super.draggingEntered(sender)
        }
        return markdownFiles(in: files).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let files = Self.fileURLs(on: sender.draggingPasteboard) else {
            return super.draggingUpdated(sender)
        }
        return markdownFiles(in: files).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let files = Self.fileURLs(on: sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }
        let markdown = markdownFiles(in: files)
        guard !markdown.isEmpty else { return false }
        onDropMarkdownFiles?(markdown)
        return true
    }

    /// File URLs on a drag pasteboard; nil when the drag carries none.
    static func fileURLs(on pasteboard: NSPasteboard) -> [URL]? {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        guard let urls, !urls.isEmpty else { return nil }
        return urls
    }

    /// The dropped files that are markdown files on disk, symlinks resolved.
    nonisolated static func markdownFiles(in urls: [URL], isRegularFile: (String) -> Bool) -> [URL] {
        urls.compactMap { url in
            guard url.isFileURL else { return nil }
            let resolution = MarkdownLinkResolver.resolve(
                linkText: url.absoluteString,
                baseDirectories: [],
                homeDirectory: NSHomeDirectory(),
                isRegularFile: isRegularFile
            )
            if case .file(let file) = resolution {
                return file
            }
            return nil
        }
    }

    private func markdownFiles(in urls: [URL]) -> [URL] {
        Self.markdownFiles(in: urls, isRegularFile: MarkdownLinkResolver.fileExistsAsRegularFile)
    }
}
