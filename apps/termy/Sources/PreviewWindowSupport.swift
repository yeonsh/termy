// PreviewWindowSupport.swift
//
// What the markdown and PDF preview windows share around their content.
// Each kind remembers the size of its last closed window under its own
// defaults key, so a reader who widens PDFs doesn't widen markdown too,
// but both fall back the same way when nothing usable is stored.

import AppKit

enum PreviewWindowSupport {
    static let defaultContentSize = NSSize(width: 820, height: 900)

    /// Content size for a new preview window: the one stored under `key`
    /// when a window closed, or the default when nothing usable is stored.
    static func savedContentSize(defaults: UserDefaults, key: String) -> NSSize {
        guard let stored = defaults.string(forKey: key) else {
            return defaultContentSize
        }
        let size = NSSizeFromString(stored)
        return size.width >= 320 && size.height >= 240 ? size : defaultContentSize
    }

    /// The banner both preview kinds show when the file can't be read at all.
    static func readErrorBanner(_ error: Error) -> String {
        "Couldn't read this file: \(error.localizedDescription)"
    }

    enum FinderReveal: Equatable {
        case selectFile(URL)
        case openFolder(URL)
    }

    /// The file itself, or the folder it lived in once it's deleted (the
    /// preview stays open for a file that may come back). Pure for testing.
    nonisolated static func finderReveal(for fileURL: URL, exists: (String) -> Bool) -> FinderReveal? {
        if exists(fileURL.path) { return .selectFile(fileURL) }
        let folder = fileURL.deletingLastPathComponent()
        return exists(folder.path) ? .openFolder(folder) : nil
    }
}

/// What `PreviewManager` needs from a preview window, whatever it shows.
@MainActor
protocol PreviewWindowController: NSWindowController {
    var fileURL: URL { get }
    /// Called from `windowWillClose`; the manager forgets the window here.
    var onClose: (() -> Void)? { get set }
}
