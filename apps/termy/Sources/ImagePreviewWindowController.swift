// ImagePreviewWindowController.swift
//
// One window per previewed image. Agents rewrite screenshots while the
// reader watches, sometimes by truncating and rewriting the file in place,
// and ImageIO reports a half-written PNG or JPEG as complete: NSImage opens
// it at full size with the rest blank. So completeness comes from per-format
// end markers (PNG's IEND chunk, JPEG's EOI, GIF's trailer, the sizes in a
// WebP or BMP header), and for HEIC/AVIF (ISO-BMFF) the top-level boxes
// must cover the file exactly, since a cut-off one still opens at full size
// and draws blank. TIFF opens with size 0 when cut off, and SVG has no
// rule; both are left to the decoder. A change
// only swaps in a complete version, the previous image stays up otherwise,
// and once the file has stopped changing for `settleInterval` we look again
// without the end-marker rule and only then show a banner if it still won't
// read. The file is read whole into memory, never mapped: a mapped file
// truncated under us is a SIGBUS.
//
// The image shows at its natural size in points (a Retina screenshot is
// half its pixels) and is fitted to the window, never enlarged, until the
// reader zooms by hand; a double-click toggles between fit and 100%. A swap
// keeps a manual zoom and the spot being looked at.

import AppKit

@MainActor
final class ImagePreviewWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, PreviewWindowController {
    static let defaultSettleInterval: TimeInterval = 1.0
    static let contentSizeDefaultsKey = "ImagePreview.contentSize"
    static let unreadableBanner = "Couldn't read this image."
    static let staleBanner = "Couldn't read the new version. Showing the previous one."

    let fileURL: URL
    /// Called from `windowWillClose`; the manager forgets the window here.
    var onClose: (() -> Void)?

    let scrollView: ImagePreviewScrollView
    let imageView: NSImageView
    /// The one line above the image; nil hides it.
    private(set) var bannerText: String? {
        didSet { updateBanner() }
    }
    /// True until the reader zooms by hand: the image is fitted to the window.
    private(set) var fitsWindow = true

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
        settleInterval: TimeInterval = ImagePreviewWindowController.defaultSettleInterval
    ) {
        self.fileURL = fileURL
        self.defaults = defaults
        self.settleInterval = settleInterval

        let imageView = NSImageView(frame: .zero)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        self.imageView = imageView

        let scrollView = ImagePreviewScrollView(frame: .zero)
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = imageView
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.01
        scrollView.maxMagnification = 16
        scrollView.postsFrameChangedNotifications = true
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        self.scrollView = scrollView

        let bannerLabel = NSTextField(labelWithString: "")
        bannerLabel.lineBreakMode = .byTruncatingTail
        bannerLabel.setContentHuggingPriority(.defaultHigh, for: .vertical)
        bannerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bannerLabel.isHidden = true
        self.bannerLabel = bannerLabel

        // A hidden banner is detached, so the image takes the whole window.
        let contentStack = NSStackView(views: [bannerLabel, scrollView])
        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.distribution = .fill
        contentStack.spacing = 8
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
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
        window.initialFirstResponder = scrollView
        super.init(window: window)

        window.delegate = self
        scrollView.onWillOpenMenu = { [weak self] menu in
            self?.addShowInFinder(to: menu)
        }
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        scrollView.addGestureRecognizer(doubleClick)
        NotificationCenter.default.addObserver(
            self, selector: #selector(didEndLiveMagnify(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView
        )
        // The window resizing and the banner appearing both change the
        // scroll view's frame; a fitted image follows.
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollViewFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification, object: scrollView
        )
        // `contentSize` is only real once laid out; the first fit needs it.
        contentStack.layoutSubtreeIfNeeded()
        reload(after: nil)
        watcher = PreviewFileWatcher(fileURL: fileURL) { [weak self] change in
            self?.reload(after: change)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Completeness

    /// Whether `data` ends the way a finished file of its format does; the
    /// format comes from the leading bytes, not the file name. Formats
    /// without a rule count as finished and are left to the decoder.
    /// HEIC/AVIF can't be decoded partially, so `image(from:)` applies the
    /// box rule in both of its modes.
    nonisolated static func hasEndMarker(_ data: Data) -> Bool {
        func byte(_ index: Int) -> UInt8 { data[data.startIndex + index] }
        func littleEndianUInt32(at offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | Int(byte(offset + $1)) << (8 * $1) }
        }
        let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let pngEnd = Data([0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
        if data.starts(with: pngSignature) {
            return data.suffix(64).range(of: pngEnd) != nil
        }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return data.suffix(32).range(of: Data([0xFF, 0xD9])) != nil
        }
        if data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)) {
            return data.last == 0x3B
        }
        if data.count >= 12, data.starts(with: Data("RIFF".utf8)), data.dropFirst(8).starts(with: Data("WEBP".utf8)) {
            return littleEndianUInt32(at: 4) + 8 <= data.count
        }
        if data.count >= 6, data.starts(with: Data("BM".utf8)) {
            return littleEndianUInt32(at: 2) <= data.count
        }
        if isISOBMFF(data) {
            return isoBMFFBoxesCoverData(data)
        }
        return true
    }

    /// Walks the top-level ISO-BMFF boxes: complete when they end exactly at
    /// the end of `data`, or a box runs to EOF (size 0).
    nonisolated private static func isoBMFFBoxesCoverData(_ data: Data) -> Bool {
        func bigEndian(at offset: Int, count: Int) -> UInt64 {
            (0..<count).reduce(0) { $0 << 8 | UInt64(data[data.startIndex + offset + $1]) }
        }
        var offset = 0
        let total = data.count
        while offset < total {
            guard total - offset >= 8 else { return false }
            var size = bigEndian(at: offset, count: 4)
            if size == 0 { return true }
            if size == 1 {
                guard total - offset >= 16 else { return false }
                size = bigEndian(at: offset + 8, count: 8)
            }
            guard size >= 8, size <= UInt64(total - offset) else { return false }
            offset += Int(size)
        }
        return true
    }

    nonisolated private static func isISOBMFF(_ data: Data) -> Bool {
        data.count >= 8 && data.dropFirst(4).starts(with: Data("ftyp".utf8))
    }

    /// The image in `data` when it decodes to a non-empty size.
    /// `requireEndMarker` also demands a finished file (see the header).
    nonisolated static func image(from data: Data, requireEndMarker: Bool) -> NSImage? {
        if requireEndMarker || isISOBMFF(data), !hasEndMarker(data) { return nil }
        guard let image = NSImage(data: data), image.isValid,
              image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }

    /// The magnification that fits `imageSize` into `viewSize` without
    /// enlarging it. Any non-positive size gives 1.
    nonisolated static func fitMagnification(imageSize: NSSize, viewSize: NSSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else { return 1 }
        return min(1, viewSize.width / imageSize.width, viewSize.height / imageSize.height)
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
        if let image = Self.image(from: data, requireEndMarker: true) {
            cancelSettle()
            swap(image)
            bannerText = nil
        } else {
            // The watcher only calls on a new fingerprint, so restarting the
            // wait here means "unchanged for `settleInterval`".
            scheduleSettle()
        }
    }

    /// The file stopped changing: show whatever decodes, else say so.
    private func settle() {
        pendingSettle = nil
        guard let data = readFile() else { return }
        if let image = Self.image(from: data, requireEndMarker: false) {
            swap(image)
            bannerText = nil
        } else {
            bannerText = imageView.image == nil ? Self.unreadableBanner : Self.staleBanner
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

    /// Puts `image` up: fitted while the reader hasn't zoomed, otherwise at
    /// the same zoom and the same spot.
    private func swap(_ image: NSImage) {
        let visibleOrigin = scrollView.contentView.bounds.origin
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)
        if fitsWindow {
            applyFit()
        } else {
            // CenteringClipView clamps the origin to the new image's extent.
            scrollView.contentView.scroll(to: visibleOrigin)
        }
    }

    private func applyFit() {
        guard let image = imageView.image else { return }
        // Classic scrollers take room from `contentSize` while the image
        // overflows and give it back once it fits, so a second pass settles it.
        for _ in 0..<2 {
            scrollView.magnification = Self.fitMagnification(imageSize: image.size, viewSize: scrollView.contentSize)
        }
    }

    private func updateBanner() {
        bannerLabel.stringValue = bannerText ?? ""
        bannerLabel.isHidden = bannerText == nil
        contentStack.edgeInsets.top = bannerText == nil ? 0 : 8
    }

    // MARK: - Zoom

    /// Double-click: 100% when fitted, fitted otherwise.
    func toggleFitOrActualSize() {
        if fitsWindow {
            fitsWindow = false
            scrollView.magnification = 1
        } else {
            fitsWindow = true
            applyFit()
        }
    }

    @objc private func handleDoubleClick(_ recognizer: NSClickGestureRecognizer) {
        toggleFitOrActualSize()
    }

    @objc private func didEndLiveMagnify(_ notification: Notification) {
        fitsWindow = false
    }

    @objc private func scrollViewFrameDidChange(_ notification: Notification) {
        if fitsWindow { applyFit() }
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
