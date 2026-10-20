// PDFPreviewView.swift
//
// The preview's PDFView, plus a hook for the controller's context-menu
// items. PDFView builds its menu in `menu(for:)` and has no willOpenMenu
// like WKWebView, so the hook runs on the menu it returns.

import AppKit
import PDFKit

final class PDFPreviewView: PDFView {
    /// Adds items to PDFView's context menu. Set by the preview controller.
    var onWillOpenMenu: ((NSMenu) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        onWillOpenMenu?(menu)
        return menu
    }
}
