import AppKit

@MainActor
protocol FloatingBallControlDelegate: AnyObject {
    func floatingBallTapped()
    func floatingBallDragBegan(at screenPoint: NSPoint)
    func floatingBallDragged(to screenPoint: NSPoint)
    func floatingBallDragEnded()
    func floatingEdgeHandleEntered()
}

@MainActor
final class FloatingBallControl: NSView {
    weak var delegate: FloatingBallControlDelegate?
    private let iconView = NSImageView()
    private let statusDot = NSView()

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        iconView.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "教务悬浮助手")
        iconView.contentTintColor = .white
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        statusDot.layer?.borderWidth = 1.25
        statusDot.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        addSubview(statusDot)
        update(state: .sample)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("教务悬浮助手")
    }

    required init?(coder: NSCoder) { fatalError("FloatingBallControl must be created programmatically") }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 17, y: 17, width: 24, height: 24)
        statusDot.frame = NSRect(x: bounds.maxX - 18, y: 8, width: 10, height: 10)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.current?.cgContext.setShouldAntialias(true)
        let circleRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let circle = NSBezierPath(ovalIn: circleRect)
        NSColor(red: 0.045, green: 0.087, blue: 0.17, alpha: 1).setFill()
        circle.fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = window.convertPoint(toScreen: event.locationInWindow)
        delegate?.floatingBallDragBegan(at: start)
        var hasDragged = false

        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                delegate?.floatingBallDragEnded()
                if !hasDragged { delegate?.floatingBallTapped() }
                return
            }
            let point = window.convertPoint(toScreen: next.locationInWindow)
            if abs(point.x - start.x) > 2 || abs(point.y - start.y) > 2 { hasDragged = true }
            delegate?.floatingBallDragged(to: point)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        delegate?.floatingBallTapped()
        return true
    }

    func update(state: SyncState) {
        let color: NSColor
        let label: String
        switch state {
        case .ready:
            color = .systemGreen; label = "课表已同步"
        case .syncing:
            color = .systemOrange; label = "正在同步课表"
        case .needsAuthorization, .failed:
            color = .systemRed; label = "课表需要重新授权"
        case .sample:
            color = .systemBlue; label = "尚未授权"
        }
        statusDot.layer?.backgroundColor = color.cgColor
        setAccessibilityLabel("教务悬浮助手，\(label)")
    }
}

@MainActor
final class FloatingEdgeHandle: NSView {
    enum Side: String { case left, right }

    weak var delegate: FloatingBallControlDelegate?
    let side: Side

    override var isOpaque: Bool { false }

    init(side: Side) {
        self.side = side
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("显示教务悬浮球")
    }

    required init?(coder: NSCoder) { fatalError("FloatingEdgeHandle must be created programmatically") }

    override func draw(_ dirtyRect: NSRect) {
        let width: CGFloat = 8
        let x = side == .left ? 0 : bounds.maxX - width
        let rect = NSRect(x: x, y: 4, width: width, height: bounds.height - 8)
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSColor(red: 0.045, green: 0.087, blue: 0.17, alpha: 0.96).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.26).setStroke()
        path.lineWidth = 0.8
        path.stroke()
    }

    override func mouseEntered(with event: NSEvent) { delegate?.floatingEdgeHandleEntered() }
    override func mouseDown(with event: NSEvent) { delegate?.floatingEdgeHandleEntered() }
    override func accessibilityPerformPress() -> Bool { delegate?.floatingEdgeHandleEntered(); return true }
}
