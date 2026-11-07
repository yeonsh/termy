// ImagePreviewView.swift
//
// The image preview's scroll view and clip view. The scroll view has a hook
// for the controller's context-menu items (NSScrollView builds its menu in
// `menu(for:)`, so the hook runs on the menu it returns); the clip view
// keeps an image that is smaller than the window in the middle of it.

import AppKit

final class ImagePreviewScrollView: NSScrollView {
    /// Adds items to the context menu. Set by the preview controller.
    var onWillOpenMenu: ((NSMenu) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        onWillOpenMenu?(menu)
        return menu
    }
}

/// Centers the document on any axis where it is smaller than the visible area.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentFrame = documentView?.frame else { return rect }
        if documentFrame.width < rect.width {
            rect.origin.x = documentFrame.minX - (rect.width - documentFrame.width) / 2
        }
        if documentFrame.height < rect.height {
            rect.origin.y = documentFrame.minY - (rect.height - documentFrame.height) / 2
        }
        return rect
    }
}
