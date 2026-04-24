// AppearanceBanner.swift
//
// Brief HUD that flashes the active appearance after ⌘⇧T cycles. Without
// it the chord rotates silently between three states and the user has to
// inspect the View menu to know which mode they landed on.

import AppKit

@MainActor
final class AppearanceBanner {
    static let shared = AppearanceBanner()

    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    /// Bumped on each `show`; the fade-out completion bails if this
    /// changed mid-animation, which means another `show` interrupted us.
    private var generation: Int = 0

    private init() {}

    func show(_ preference: AppAppearancePreference, over host: NSWindow?) {
        let panel = ensurePanel()
        configurePanel(panel, for: preference)
        position(panel, over: host)

        hideWorkItem?.cancel()
        generation &+= 1
        let myGeneration = generation
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1.0
        }

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.fadeOut(generation: myGeneration)
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    private func fadeOut(generation expected: Int) {
        guard let panel, generation == expected else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == expected, let panel = self.panel else { return }
                panel.orderOut(nil)
            }
        })
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 96),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.ignoresMouseEvents = true

        let content = AppearanceAwareView(frame: panel.contentRect(forFrameRect: panel.frame))
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        content.layer?.cornerRadius = 14
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1
        panel.contentView = content
        self.panel = panel
        return panel
    }

    private func configurePanel(_ panel: NSPanel, for preference: AppAppearancePreference) {
        // Re-render content from scratch each time so the icon + label match
        // the new mode and the panel themes against its own appearance (not
        // the previous mode's).
        panel.appearance = preference.appearance
        guard let content = panel.contentView else { return }
        content.subviews.forEach { $0.removeFromSuperview() }

        let theme = PaneStyling.theme(for: content.effectiveAppearance)
        content.layer?.backgroundColor = theme.panelBackgroundColor.cgColor
        content.layer?.borderColor = theme.panelBorderColor.cgColor

        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: preference.symbolName,
            accessibilityDescription: preference.displayName
        )
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        icon.contentTintColor = .labelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: preference.displayName)
        label.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(icon)
        content.addSubview(label)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),

            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 10),
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16)
        ])
    }

    private func position(_ panel: NSPanel, over host: NSWindow?) {
        let size = panel.frame.size
        if let host {
            let hf = host.frame
            panel.setFrameOrigin(NSPoint(
                x: hf.midX - size.width / 2,
                y: hf.midY - size.height / 2
            ))
        } else if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: sf.midX - size.width / 2,
                y: sf.midY - size.height / 2
            ))
        }
    }
}
