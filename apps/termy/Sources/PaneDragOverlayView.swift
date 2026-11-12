import AppKit

/// pane header를 끄는 동안 Workspace 맨 위에 얹는 투명한 판. 놓으면 끌리는 pane이 차지할 frame을 그림자 상자로,
/// 그 pane의 header 글자를 커서 옆 칩으로 보여 준다. 터미널 내용은 그리지 않고 클릭도 받지 않는다.
/// 좌표는 Workspace 기준 y-아래(`PaneDropPlanner`와 같다) — Workspace의 bounds를 그대로 덮는다.
final class PaneDragOverlayView: NSView {
    private let previewBox = PreviewBoxView(frame: .zero)
    private let chip = ChipView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        previewBox.isHidden = true
        chip.isHidden = true
        addSubview(previewBox)
        addSubview(chip)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 지금 보이는 그림자 상자의 frame. 숨겨져 있으면 nil.
    var previewFrame: CGRect? { previewBox.isHidden ? nil : previewBox.frame }

    /// 놓일 자리. nil이면(작업 영역 밖·제자리) 상자를 숨긴다.
    func showPreview(_ frame: CGRect?) {
        guard let frame else {
            previewBox.isHidden = true
            return
        }
        previewBox.frame = frame
        previewBox.isHidden = false
    }

    /// 커서(`point`) 오른쪽 아래에 칩을 띄운다. 판 밖으로 나가지 않게 안쪽으로 붙인다.
    func showChip(title: String, at point: CGPoint) {
        chip.title = title
        let size = chip.preferredSize
        let x = min(point.x + 14, bounds.maxX - size.width)
        let y = min(point.y + 12, bounds.maxY - size.height)
        chip.frame = CGRect(x: max(x, bounds.minX), y: max(y, bounds.minY), width: size.width, height: size.height)
        chip.isHidden = false
    }
}

/// 강조색 테두리 2pt + 같은 색 옅은 채움 + 부드러운 그림자, pane과 같은 둥근 모서리.
private final class PreviewBoxView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 2
        layer?.masksToBounds = false
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 10
        layer?.shadowOffset = .zero
        needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let accent = NSColor.controlAccentColor
        layer?.borderColor = accent.cgColor
        layer?.backgroundColor = accent.withAlphaComponent(0.16).cgColor
        layer?.shadowColor = NSColor.black.cgColor
    }
}

/// 커서를 따라다니는 작은 칩: 둥근 배경 + header 글자.
private final class ChipView: NSView {
    private let label = NSTextField(labelWithString: "")
    private static let padding = NSSize(width: 9, height: 4)

    var title: String {
        get { label.stringValue }
        set {
            guard label.stringValue != newValue else { return }
            label.stringValue = newValue
            label.sizeToFit()
            label.setFrameOrigin(NSPoint(x: Self.padding.width, y: Self.padding.height))
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.masksToBounds = false
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 7
        layer?.shadowOffset = .zero
        label.font = TermyTypography.medium(size: 12)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        addSubview(label)
        needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var isFlipped: Bool { true }

    var preferredSize: NSSize {
        let text = label.frame.size
        return NSSize(width: ceil(text.width + Self.padding.width * 2), height: ceil(text.height + Self.padding.height * 2))
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.shadowColor = NSColor.black.cgColor
    }
}
