// MarkdownPreviewWindowController.swift
//
// One window per previewed markdown file (MarkdownPreviewManager keeps the
// one-per-file rule). The file is agent-written, so the WKWebView runs with
// page JavaScript off and every navigation is decided here: our own loads
// go through, links leave for the browser or open another preview, nothing
// else happens. Live reloads keep the reader's place by reading and
// restoring `scrollY` from the `.defaultClient` content world, which the
// page JavaScript switch doesn't affect. Markdown files dropped onto the
// window open in their own previews (`MarkdownPreviewWebView`).

import AppKit
import WebKit

@MainActor
final class MarkdownPreviewWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {
    static let defaultContentSize = NSSize(width: 820, height: 900)
    static let contentSizeDefaultsKey = "MarkdownPreview.contentSize"
    static let deletedBanner = "This file was deleted. The preview will reload if it comes back."

    /// Where a navigation inside the preview goes.
    enum LinkRoute: Equatable {
        case allow
        case cancel
        case openExternally(URL)
        case preview(URL)
    }

    let fileURL: URL
    /// Called from `windowWillClose`; the manager forgets the window here.
    var onClose: ((MarkdownPreviewWindowController) -> Void)?

    let webView: MarkdownPreviewWebView
    private let defaults: UserDefaults
    private var watcher: MarkdownFileWatcher?
    private var lastMarkdown = ""
    private var hasLoaded = false
    private var pendingScrollY: Double?
    /// Bumped per render; a render that finds a newer one gives up, so the
    /// newest HTML always wins.
    private var renderGeneration = 0
    /// Counts started loads, so a scroll read can tell a load began under it.
    private var loadCount = 0
    /// The newest load; only its callbacks may restore or drop the scroll.
    private var currentNavigation: WKNavigation?

    init(fileURL: URL, defaults: UserDefaults = .standard) {
        self.fileURL = fileURL
        self.defaults = defaults
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = MarkdownPreviewWebView(frame: .zero, configuration: configuration)
        // Force Touch previews load link targets without asking
        // `decidePolicyFor`.
        webView.allowsLinkPreview = false
        webView.onDropMarkdownFiles = { urls in
            for url in urls {
                MarkdownPreviewManager.shared.open(url)
            }
        }
        self.webView = webView

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.savedContentSize(defaults: defaults)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = fileURL.lastPathComponent
        window.subtitle = (fileURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        window.representedURL = fileURL
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentView = webView
        super.init(window: window)

        window.delegate = self
        webView.navigationDelegate = self
        reload(after: nil)
        watcher = MarkdownFileWatcher(fileURL: fileURL) { [weak self] change in
            self?.reload(after: change)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Content size for a new preview window: the last one closed, or the
    /// default when nothing usable is stored.
    static func savedContentSize(defaults: UserDefaults) -> NSSize {
        guard let stored = defaults.string(forKey: contentSizeDefaultsKey) else {
            return defaultContentSize
        }
        let size = NSSizeFromString(stored)
        return size.width >= 320 && size.height >= 240 ? size : defaultContentSize
    }

    /// UTF-8 with invalid bytes replaced — one stray byte shouldn't hide
    /// the whole document behind an error.
    nonisolated static func decodeMarkdown(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    // MARK: - Loading

    /// Re-reads and renders the file. `change == nil` is the first load.
    private func reload(after change: FileChange?) {
        if change == .deleted {
            render(markdown: lastMarkdown, banner: Self.deletedBanner)
            return
        }
        do {
            lastMarkdown = Self.decodeMarkdown(try Data(contentsOf: fileURL))
            render(markdown: lastMarkdown, banner: nil)
        } catch {
            render(markdown: "", banner: "Couldn't read this file: \(error.localizedDescription)")
        }
    }

    private func render(markdown: String, banner: String?) {
        let html = MarkdownHTMLRenderer.document(
            markdown: markdown,
            title: fileURL.lastPathComponent,
            banner: banner
        )
        renderGeneration += 1
        let generation = renderGeneration
        guard hasLoaded else {
            hasLoaded = true
            startLoad(html)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            // A page that is still loading has no real position; keep the
            // one saved before that load started.
            if !self.webView.isLoading {
                let loadsBefore = self.loadCount
                let scrollY = try? await self.webView.callAsyncJavaScript(
                    "return window.scrollY;",
                    contentWorld: .defaultClient
                ) as? Double
                if let scrollY, loadsBefore == self.loadCount {
                    self.pendingScrollY = scrollY
                }
            }
            guard generation == self.renderGeneration else { return }
            self.startLoad(html)
        }
    }

    private func startLoad(_ html: String) {
        loadCount += 1
        currentNavigation = webView.loadHTMLString(html, baseURL: fileURL)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === currentNavigation, let scrollY = pendingScrollY else { return }
        pendingScrollY = nil
        Task {
            _ = try? await webView.callAsyncJavaScript(
                "window.scrollTo(0, y);",
                arguments: ["y": scrollY],
                contentWorld: .defaultClient
            )
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        dropPendingScroll(for: navigation)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        dropPendingScroll(for: navigation)
    }

    /// A failed newest load must not leak its saved position into the next one.
    private func dropPendingScroll(for navigation: WKNavigation?) {
        if navigation === currentNavigation { pendingScrollY = nil }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        let route = Self.route(
            navigationType: navigationAction.navigationType,
            url: navigationAction.request.url,
            documentURL: fileURL,
            isRegularFile: MarkdownLinkResolver.fileExistsAsRegularFile
        )
        // PROBE (temporary)
        NSLog("PREVIEW-NAV type=%ld url=%@ filePath=%@ doc=%@ route=%@",
              navigationAction.navigationType.rawValue,
              navigationAction.request.url?.absoluteString ?? "nil",
              (navigationAction.request.url as NSURL?)?.filePathURL?.path ?? "nil",
              fileURL.path,
              String(describing: route))
        switch route {
        case .allow:
            return .allow
        case .cancel:
            return .cancel
        case .openExternally(let url):
            NSWorkspace.shared.open(url)
            return .cancel
        case .preview(let url):
            MarkdownPreviewManager.shared.open(url)
            return .cancel
        }
    }

    /// Where a navigation inside the preview goes. Pure for testing.
    nonisolated static func route(
        navigationType: WKNavigationType,
        url: URL?,
        documentURL: URL,
        isRegularFile: (String) -> Bool
    ) -> LinkRoute {
        switch navigationType {
        case .other:
            // Our own loadHTMLString targets the document itself. Any other
            // `.other` is WebKit acting for the user (context-menu Open Link,
            // a drop), so route it like a click.
            guard let url else { return .cancel }
            if url.isFileURL, url.path == documentURL.path { return .allow }
            return linkRoute(for: url, documentURL: documentURL, isRegularFile: isRegularFile)
        case .reload:
            // Would load the base URL itself, the raw `.md` as plain text.
            // Live reload renders anew instead.
            return .cancel
        case .linkActivated:
            guard let url else { return .cancel }
            return linkRoute(for: url, documentURL: documentURL, isRegularFile: isRegularFile)
        default:
            return .cancel
        }
    }

    nonisolated private static func linkRoute(
        for url: URL,
        documentURL: URL,
        isRegularFile: (String) -> Bool
    ) -> LinkRoute {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            return .openExternally(url)
        case "file":
            if url.fragment != nil, url.path == documentURL.path {
                return .allow   // in-page anchor; WebKit scrolls to it
            }
            let resolution = MarkdownLinkResolver.resolve(
                linkText: url.absoluteString,
                baseDirectories: [],
                homeDirectory: NSHomeDirectory(),
                isRegularFile: isRegularFile
            )
            if case .file(let target) = resolution {
                return .preview(target)
            }
            return .cancel
        default:
            return .cancel
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        watcher?.stop()
        watcher = nil
        if let contentSize = window?.contentLayoutRect.size {
            defaults.set(NSStringFromSize(contentSize), forKey: Self.contentSizeDefaultsKey)
        }
        onClose?(self)
    }
}
