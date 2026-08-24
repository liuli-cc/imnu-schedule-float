import AppKit
import QuartzCore

@MainActor
protocol FloatingBallControlDelegate: AnyObject {
    func floatingBallTapped()
    func floatingBallDragBegan(at screenPoint: NSPoint)
    func floatingBallDragged(to screenPoint: NSPoint)
    func floatingBallDragEnded()
    func floatingEdgeHandleEntered()
    func floatingEdgeHandleClicked()
}

@MainActor
final class FloatingBallControl: NSView {
    weak var delegate: FloatingBallControlDelegate?
    private let iconView = NSImageView()
    private let statusDot = NSView()
    private var hoverTrackingArea: NSTrackingArea?
    private var mouseDownPoint: NSPoint?
    private var isDragging = false
    private var isHovered = false
    private var isPressed = false
    private let dragThreshold: CGFloat = 3
    private let baseBallColor = NSColor(red: 0.045, green: 0.087, blue: 0.17, alpha: 1)
    private let hoverBallColor = NSColor(red: 0.055, green: 0.115, blue: 0.225, alpha: 1)
    private let pressedBallColor = NSColor(red: 0.035, green: 0.070, blue: 0.145, alpha: 1)

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = baseBallColor.cgColor
        layer?.masksToBounds = true

        iconView.wantsLayer = true
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
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        hoverTrackingArea = tracking
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        if !isPressed { animateScale(to: 1.08, duration: 0.14) }
        animateFill(to: hoverBallColor)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if !isPressed { animateScale(to: 1, duration: 0.14) }
        animateFill(to: baseBallColor)
    }

    override func mouseDown(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        mouseDownPoint = point
        isDragging = false
        isPressed = true
        delegate?.floatingBallDragBegan(at: point)
        animateScale(to: 0.82, duration: 0.07)
        animateFill(to: pressedBallColor)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = NSEvent.mouseLocation
        if !isDragging {
            guard hypot(point.x - start.x, point.y - start.y) >= dragThreshold else { return }
            isDragging = true
            animateScale(to: 1.04, duration: 0.10)
        }
        delegate?.floatingBallDragged(to: point)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownPoint != nil else { return }
        let completedDrag = isDragging
        mouseDownPoint = nil
        isDragging = false
        isPressed = false
        animateScale(to: isHovered ? 1.08 : 1, duration: 0.16)
        animateFill(to: isHovered ? hoverBallColor : baseBallColor)
        if completedDrag {
            delegate?.floatingBallDragEnded()
        } else {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            playTapFeedback()
            DispatchQueue.main.asyncAfter(deadline: .now() + (shouldReduceMotion ? 0 : 0.055)) { [weak self] in
                self?.delegate?.floatingBallTapped()
            }
        }
    }

    override func accessibilityPerformPress() -> Bool {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        playTapFeedback()
        DispatchQueue.main.asyncAfter(deadline: .now() + (shouldReduceMotion ? 0 : 0.055)) { [weak self] in
            self?.delegate?.floatingBallTapped()
        }
        return true
    }

    func playOpenFeedback() {
        playScaleKeyframes(values: [currentScale, 0.78, 1.13, isHovered ? 1.08 : 1], duration: 0.25, key: "open")
    }

    func playCloseFeedback() {
        playScaleKeyframes(values: [currentScale, 1.12, 0.86, isHovered ? 1.08 : 1], duration: 0.21, key: "close")
    }

    func playRevealFeedback() {
        playScaleKeyframes(values: [0.62, 1.14, isHovered ? 1.08 : 1], duration: 0.22, key: "reveal")
    }

    func update(state: SyncState) {
        let color: NSColor
        let label: String
        switch state {
        case .ready:
            color = .systemGreen; label = "课表与成绩已同步"
        case .syncing:
            color = .systemOrange; label = "正在同步课表与成绩"
        case .offline:
            color = .systemOrange; label = "网络不可用，正在使用已缓存的数据"
        case .needsAuthorization, .failed:
            color = .systemRed; label = "教务数据需要重新授权"
        case .sample:
            color = .systemBlue; label = "尚未授权"
        }
        statusDot.layer?.backgroundColor = color.cgColor
        if case .syncing = state, !shouldReduceMotion {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.35
            pulse.duration = 0.65
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            statusDot.layer?.add(pulse, forKey: "syncPulse")
        } else {
            statusDot.layer?.removeAnimation(forKey: "syncPulse")
        }
        setAccessibilityLabel("教务悬浮助手，\(label)")
    }

    private var shouldReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var currentScale: CGFloat {
        if let value = iconView.layer?.presentation()?.value(forKeyPath: "transform.scale") as? NSNumber {
            return CGFloat(value.doubleValue)
        }
        return isHovered ? 1.08 : 1
    }

    private func playTapFeedback() {
        playScaleKeyframes(values: [currentScale, 0.76, isHovered ? 1.08 : 1], duration: 0.13, key: "tap")
    }

    private func animateScale(to scale: CGFloat, duration: TimeInterval) {
        guard let layer = iconView.layer else { return }
        layer.removeAnimation(forKey: "interactionScale")
        let from = currentScale
        layer.setValue(scale, forKeyPath: "transform.scale")
        guard !shouldReduceMotion else { return }
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = from
        animation.toValue = scale
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "interactionScale")
    }

    private func playScaleKeyframes(values: [CGFloat], duration: TimeInterval, key: String) {
        guard let layer = iconView.layer, let final = values.last else { return }
        layer.setValue(final, forKeyPath: "transform.scale")
        guard !shouldReduceMotion else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = values
        animation.keyTimes = values.indices.map { NSNumber(value: Double($0) / Double(max(values.count - 1, 1))) }
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "feedback.\(key)")
    }

    private func animateFill(to color: NSColor) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(shouldReduceMotion ? 0 : 0.14)
        layer.backgroundColor = color.cgColor
        CATransaction.commit()
    }
}

@MainActor
final class FloatingEdgeHandle: NSView {
    enum Side: String { case left, right }

    weak var delegate: FloatingBallControlDelegate?
    let side: Side
    var isHoverArmed = false
    private var isHovered = false

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
        setAccessibilityLabel("显示并打开教务悬浮窗")
    }

    required init?(coder: NSCoder) { fatalError("FloatingEdgeHandle must be created programmatically") }

    override func draw(_ dirtyRect: NSRect) {
        let width: CGFloat = isHovered ? 10 : 8
        let x = side == .left ? 0 : bounds.maxX - width
        let rect = NSRect(x: x, y: 4, width: width, height: bounds.height - 8)
        let path = NSBezierPath(roundedRect: rect, xRadius: width / 2, yRadius: width / 2)
        NSColor(red: 0.045, green: 0.087, blue: 0.17, alpha: isHovered ? 1 : 0.96).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(isHovered ? 0.42 : 0.26).setStroke()
        path.lineWidth = 0.8
        path.stroke()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
        guard isHoverArmed else { return }
        delegate?.floatingEdgeHandleEntered()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isHoverArmed = true
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        delegate?.floatingEdgeHandleClicked()
    }

    override func accessibilityPerformPress() -> Bool {
        delegate?.floatingEdgeHandleClicked()
        return true
    }
}
