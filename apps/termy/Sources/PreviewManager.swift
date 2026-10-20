// PreviewManager.swift
//
// One preview window per markdown file. Cmd+clicking a file that's already
// open brings its window forward instead of stacking another; files are
// keyed by their symlink-resolved standard path, so `./docs/x.md` and an
// absolute path to the same file share a window.

import AppKit

@MainActor
final class PreviewManager {
    static let shared = PreviewManager()

    private(set) var controllers: [String: MarkdownPreviewWindowController] = [:]
    private let defaults: UserDefaults
    /// Keys of the open previews, oldest first; a new window cascades from
    /// the last one.
    private var openOrder: [String] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    nonisolated static func key(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// A frame of `size` centered in `visibleFrame`. One that doesn't fit
    /// keeps its top-left (and title bar) on screen.
    nonisolated static func centeredFrame(size: NSSize, in visibleFrame: NSRect) -> NSRect {
        let x = max(visibleFrame.minX, visibleFrame.midX - size.width / 2)
        let y = min(visibleFrame.midY - size.height / 2, visibleFrame.maxY - size.height)
        return NSRect(origin: NSPoint(x: x.rounded(), y: y.rounded()), size: size)
    }

    /// True when `window` belongs to a markdown preview.
    static func isPreviewWindow(_ window: NSWindow?) -> Bool {
        window?.windowController is MarkdownPreviewWindowController
    }

    /// Shows the preview for `url`, reusing its window when already open.
    @discardableResult
    func open(_ url: URL) -> MarkdownPreviewWindowController {
        let key = Self.key(for: url)
        if let existing = controllers[key] {
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        let controller = MarkdownPreviewWindowController(fileURL: URL(fileURLWithPath: key), defaults: defaults)
        controller.onClose = { [weak self] _ in
            guard let self else { return }
            controllers.removeValue(forKey: key)
            openOrder.removeAll { $0 == key }
        }
        if let window = controller.window {
            place(window)
        }
        controllers[key] = controller
        openOrder.append(key)
        controller.showWindow(nil)
        return controller
    }

    /// Cascades a new window from the newest open preview; the first one is
    /// centered on the screen of the window the click came from.
    private func place(_ window: NSWindow) {
        if let newest = openOrder.last.flatMap({ controllers[$0]?.window }) {
            // `cascadeTopLeft(from:)` puts the window at the given point and
            // returns the next one in the cascade; the second call moves it
            // there.
            let topLeft = NSPoint(x: newest.frame.minX, y: newest.frame.maxY)
            _ = window.cascadeTopLeft(from: window.cascadeTopLeft(from: topLeft))
        } else if let screen = NSApp.keyWindow?.screen ?? NSScreen.main {
            window.setFrame(Self.centeredFrame(size: window.frame.size, in: screen.visibleFrame), display: false)
        } else {
            window.center()
        }
    }

    /// Closes every preview window.
    func closeAll() {
        for controller in Array(controllers.values) {
            controller.close()
        }
    }
}
