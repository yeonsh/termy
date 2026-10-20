// PDFPreviewWindowController.swift
//
// One window per previewed PDF. Agents regenerate PDFs while the reader
// watches, sometimes by truncating and rewriting the file in place, and
// PDFKit opens many half-written files anyway: it repairs a cut-off
// cross-reference table, and a generator that writes its page list first
// leaves a file that opens with every page blank. So a change only swaps
// in a complete version — `%%EOF` in the last 1024 bytes and a page or more.
// Anything else leaves the previous document up; once the file has stopped
// changing for `settleInterval` we look again without the end-marker rule,
// and only then show a banner if it still won't read. The file is read
// whole into memory, never mapped and never through `PDFDocument(url:)`:
// a mapped file truncated under us is a SIGBUS. Swaps keep the page, the
// spot on it, and a zoom the reader set by hand.

import AppKit
import PDFKit

@MainActor
final class PDFPreviewWindowController: NSWindowController, NSWindowDelegate, @preconcurrency PDFViewDelegate, NSMenuItemValidation, PreviewWindowController {
    static let defaultSettleInterval: TimeInterval = 1.0
    static let contentSizeDefaultsKey = "PDFPreview.contentSize"
    static let unreadableBanner = "Couldn't read this PDF."
    static let staleBanner = "Couldn't read the new version. Showing the previous one."

    /// Where a clicked link goes. Pure for testing.
    enum LinkRoute: Equatable {
        case openExternally(URL)
        case preview(URL)
        case ignore
    }

    let fileURL: URL
    /// Called from `windowWillClose`; the manager forgets the window here.
    var onClose: (() -> Void)?

    let pdfView: PDFPreviewView
    /// The one line above the document; nil hides it.
    private(set) var bannerText: String? {
        didSet { updateBanner() }
    }

    private let defaults: UserDefaults
    private let settleInterval: TimeInterval
    private let contentStack: NSStackView
    private let bannerLabel: NSTextField
    private var watcher: PreviewFileWatcher?
    /// The second look at an incomplete version, once the file settles.
    private var pendingSettle: DispatchWorkItem?

    init(
        fileURL: URL,
        defaults: UserDefaults = .standard,
        settleInterval: TimeInterval = PDFPreviewWindowController.defaultSettleInterval
    ) {
        self.fileURL = fileURL
        self.defaults = defaults
        self.settleInterval = settleInterval
        let pdfView = PDFPreviewView(frame: .zero)
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.autoScales = true
        pdfView.setContentHuggingPriority(.defaultLow, for: .vertical)
        self.pdfView = pdfView

        let bannerLabel = NSTextField(labelWithString: "")
        bannerLabel.lineBreakMode = .byTruncatingTail
        bannerLabel.setContentHuggingPriority(.defaultHigh, for: .vertical)
        bannerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bannerLabel.isHidden = true
        self.bannerLabel = bannerLabel

        // A hidden banner is detached, so the document takes the whole window.
        let contentStack = NSStackView(views: [bannerLabel, pdfView])
        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.distribution = .fill
        contentStack.spacing = 8
        NSLayoutConstraint.activate([
            pdfView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            bannerLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor, constant: -28),
        ])
        self.contentStack = contentStack

        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: PreviewWindowSupport.savedContentSize(defaults: defaults, key: Self.contentSizeDefaultsKey)
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = fileURL.lastPathComponent
        window.subtitle = (fileURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        window.representedURL = fileURL
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentView = contentStack
        // Space, arrows and Page Down scroll the PDF without a click first.
        window.initialFirstResponder = pdfView
        super.init(window: window)

        window.delegate = self
        pdfView.delegate = self
        pdfView.onWillOpenMenu = { [weak self] menu in
            self?.addShowInFinder(to: menu)
        }
        reload(after: nil)
        watcher = PreviewFileWatcher(fileURL: fileURL) { [weak self] change in
            self?.reload(after: change)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The page in view, nil when no document is loaded.
    var currentPageIndex: Int? {
        guard let document = pdfView.document, let page = pdfView.currentPage else { return nil }
        return document.index(for: page)
    }

    // MARK: - Completeness

    /// A finished PDF ends with `%%EOF`; generators may leave a little
    /// whitespace after it, hence the last 1024 bytes.
    nonisolated static func hasEndMarker(_ data: Data) -> Bool {
        data.suffix(1024).range(of: Data("%%EOF".utf8)) != nil
    }

    /// The document in `data` when PDFKit finds at least one page in it
    /// and it isn't locked.
    /// `requireEndMarker` also demands a finished file (see the header).
    nonisolated static func document(from data: Data, requireEndMarker: Bool) -> PDFDocument? {
        if requireEndMarker, !hasEndMarker(data) { return nil }
        // A password-protected PDF opens with blank pages; we can't read it.
        guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else { return nil }
        return document
    }

    // MARK: - Loading

    /// Re-reads the file and swaps in a complete version. `change == nil`
    /// is the first load.
    private func reload(after change: FileChange?) {
        if change == .deleted {
            cancelSettle()
            bannerText = MarkdownPreviewWindowController.deletedBanner
            return
        }
        guard let data = readFile() else { return }
        if let document = Self.document(from: data, requireEndMarker: true) {
            cancelSettle()
            swap(document)
            bannerText = nil
        } else {
            // The watcher only calls on a new fingerprint, so restarting the
            // wait here means "unchanged for `settleInterval`".
            scheduleSettle()
        }
    }

    /// The file stopped changing: show whatever PDFKit can read, else say so.
    private func settle() {
        pendingSettle = nil
        guard let data = readFile() else { return }
        if let document = Self.document(from: data, requireEndMarker: false) {
            swap(document)
            bannerText = nil
        } else {
            bannerText = pdfView.document == nil ? Self.unreadableBanner : Self.staleBanner
        }
    }

    /// The whole file in memory, or nil after showing why it can't be read.
    private func readFile() -> Data? {
        do {
            return try Data(contentsOf: fileURL)
        } catch {
            bannerText = PreviewWindowSupport.readErrorBanner(error)
            return nil
        }
    }

    private func scheduleSettle() {
        pendingSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.settle() }
        }
        pendingSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settleInterval, execute: work)
    }

    private func cancelSettle() {
        pendingSettle?.cancel()
        pendingSettle = nil
    }

    /// Puts `newDocument` up where the reader was: same page (or the last
    /// one, if the document got shorter), same spot on it, same manual zoom.
    private func swap(_ newDocument: PDFDocument) {
        // Page and point come from one destination so they always belong
        // together; `currentPage` is only the fallback.
        let destination = pdfView.currentDestination
        let oldDocument = pdfView.document
        let autoScales = pdfView.autoScales
        let scaleFactor = pdfView.scaleFactor
        let oldPage = destination?.page ?? pdfView.currentPage
        pdfView.document = newDocument
        guard oldDocument != nil else { return }
        // Zoom is restored whether or not a page position is known.
        if !autoScales {
            pdfView.scaleFactor = scaleFactor
        }
        guard let oldDocument, let oldPage else { return }
        let pageIndex = oldDocument.index(for: oldPage)
        guard let page = newDocument.page(at: min(pageIndex, newDocument.pageCount - 1)) else { return }
        if let point = destination?.point {
            pdfView.go(to: PDFDestination(page: page, at: point))
        } else {
            pdfView.go(to: page)
        }
    }

    private func updateBanner() {
        bannerLabel.stringValue = bannerText ?? ""
        bannerLabel.isHidden = bannerText == nil
        contentStack.edgeInsets.top = bannerText == nil ? 0 : 8
    }

    // MARK: - Links

    /// Web links go to the browser, markdown and PDF files to a preview
    /// window; anything else (apps, scripts, missing files) does nothing.
    nonisolated static func linkRoute(for url: URL, isRegularFile: (String) -> Bool) -> LinkRoute {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            return .openExternally(url)
        case "file":
            let resolution = PreviewLinkResolver.resolve(
                linkText: url.absoluteString,
                baseDirectories: [],
                homeDirectory: NSHomeDirectory(),
                isRegularFile: isRegularFile
            )
            if case .file(let target) = resolution {
                return .preview(target)
            }
            return .ignore
        default:
            return .ignore
        }
    }

    /// Not calling super: its default opens the URL as-is.
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        switch Self.linkRoute(for: url, isRegularFile: PreviewLinkResolver.fileExistsAsRegularFile) {
        case .openExternally(let url):
            NSWorkspace.shared.open(url)
        case .preview(let url):
            PreviewManager.shared.open(url)
        case .ignore:
            break
        }
    }

    // MARK: - Show in Finder

    /// File ▸ Show in Finder reaches this through the responder chain while
    /// the preview is key; the context-menu item targets it directly.
    @objc func showInFinder(_ sender: Any?) {
        switch finderReveal {
        case .selectFile(let url)?:
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .openFolder(let url)?:
            NSWorkspace.shared.open(url)
        case nil:
            break
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(showInFinder(_:)) else { return true }
        return finderReveal != nil
    }

    private var finderReveal: PreviewWindowSupport.FinderReveal? {
        PreviewWindowSupport.finderReveal(for: fileURL, exists: FileManager.default.fileExists(atPath:))
    }

    private func addShowInFinder(to menu: NSMenu) {
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let item = menu.addItem(withTitle: "Show in Finder", action: #selector(showInFinder(_:)), keyEquivalent: "")
        item.target = self
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        watcher?.stop()
        watcher = nil
        cancelSettle()
        if let contentSize = window?.contentLayoutRect.size {
            defaults.set(NSStringFromSize(contentSize), forKey: Self.contentSizeDefaultsKey)
        }
        onClose?()
    }
}
