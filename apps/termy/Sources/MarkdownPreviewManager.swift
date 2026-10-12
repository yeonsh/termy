// MarkdownPreviewManager.swift
//
// One preview window per markdown file. Cmd+clicking a file that's already
// open brings its window forward instead of stacking another; files are
// keyed by their symlink-resolved standard path, so `./docs/x.md` and an
// absolute path to the same file share a window.

import AppKit

@MainActor
final class MarkdownPreviewManager {
    static let shared = MarkdownPreviewManager()

    private(set) var controllers: [String: MarkdownPreviewWindowController] = [:]
    private let defaults: UserDefaults
    /// Top-left for the next window in the cascade.
    private var nextTopLeft: NSPoint = .zero

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    nonisolated static func key(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
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
            _ = self?.controllers.removeValue(forKey: key)
        }
        if let window = controller.window {
            if controllers.isEmpty {
                window.center()
                nextTopLeft = window.cascadeTopLeft(from: .zero)
            } else {
                nextTopLeft = window.cascadeTopLeft(from: nextTopLeft)
            }
        }
        controllers[key] = controller
        controller.showWindow(nil)
        return controller
    }

    /// Closes every preview window.
    func closeAll() {
        for controller in Array(controllers.values) {
            controller.close()
        }
    }
}
