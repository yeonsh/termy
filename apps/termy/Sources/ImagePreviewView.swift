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

/// An image view that draws a light checkerboard behind the image, so a
/// transparent picture with dark content stays visible in dark mode. The
/// colors are the same in light and dark appearances.
final class CheckerboardImageView: NSImageView {
    private static let tile: NSColor = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 16, height: 16).fill()
            NSColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: 1).setFill()
            NSRect(x: 8, y: 0, width: 8, height: 8).fill()
            NSRect(x: 0, y: 8, width: 8, height: 8).fill()
            return true
        }
        return NSColor(patternImage: image)
    }()

    override func draw(_ dirtyRect: NSRect) {
        Self.tile.setFill()
        bounds.fill()
        super.draw(dirtyRect)
    }
}
