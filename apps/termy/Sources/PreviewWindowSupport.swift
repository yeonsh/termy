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
}
