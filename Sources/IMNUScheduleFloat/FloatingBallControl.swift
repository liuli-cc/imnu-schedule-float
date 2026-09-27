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

/// Native backdrop blur that never intercepts the floating control's events.
@MainActor
final class AcademicGlassEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("AcademicGlassEffectView must be created programmatically") }
}

@MainActor
final class FloatingBallControl: NSView {
    weak var delegate: FloatingBallControlDelegate?
    private let glassView = AcademicGlassEffectView(frame: .zero)
    private let surfaceTint = CALayer()
    private let iconView = NSImageView()
    private let statusDot = NSView()
    private let activityRing = CAShapeLayer()
    private var previousState: SyncState?
    private var completionResetWorkItem: DispatchWorkItem?
    private var upcomingCourseID: UUID?
    private var isSyncing = false
    private var isShowingCompletion = false
    private var hoverTrackingArea: NSTrackingArea?
    private var mouseDownPoint: NSPoint?
    private var isDragging = false
    private var isHovered = false
    private var isPressed = false
    private let dragThreshold: CGFloat = 3
    private let baseBallColor = NSColor.white.withAlphaComponent(0.025)
    private let hoverBallColor = NSColor.white.withAlphaComponent(0.10)
    private let pressedBallColor = NSColor.black.withAlphaComponent(0.07)
    private let accentColor = NSColor(red: 0.76, green: 0.68, blue: 0.96, alpha: 1)

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.30).cgColor
        addSubview(glassView)
        surfaceTint.backgroundColor = baseBallColor.cgColor
        layer?.addSublayer(surfaceTint)
        activityRing.zPosition = 1
        activityRing.fillColor = NSColor.clear.cgColor
        activityRing.strokeColor = accentColor.cgColor
        activityRing.lineWidth = 2
        activityRing.lineCap = .round
        activityRing.opacity = 0
        layer?.addSublayer(activityRing)

        iconView.wantsLayer = true
        iconView.layer?.zPosition = 2
        iconView.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "教务悬浮助手")
        iconView.contentTintColor = NSColor.white.withAlphaComponent(0.94)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        statusDot.wantsLayer = true
        statusDot.layer?.zPosition = 2
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
        glassView.frame = bounds
        glassView.layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        surfaceTint.frame = bounds
        iconView.frame = NSRect(x: 17, y: 17, width: 24, height: 24)
        statusDot.frame = NSRect(x: bounds.maxX - 18, y: 8, width: 10, height: 10)
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        activityRing.frame = bounds
        activityRing.path = CGPath(ellipseIn: bounds.insetBy(dx: 4.5, dy: 4.5), transform: nil)
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
        if !isPressed { animateScale(to: 1.045, duration: 0.14) }
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
        animateScale(to: 0.91, duration: 0.07)
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
        animateScale(to: isHovered ? 1.045 : 1, duration: 0.16)
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
        playScaleKeyframes(values: [currentScale, 0.91, 1.055, isHovered ? 1.045 : 1], duration: 0.25, key: "open")
    }

    func playCloseFeedback() {
        playScaleKeyframes(values: [currentScale, 1.05, 0.94, isHovered ? 1.045 : 1], duration: 0.21, key: "close")
    }

    func playRevealFeedback() {
        playScaleKeyframes(values: [0.90, 1.065, isHovered ? 1.045 : 1], duration: 0.22, key: "reveal")
    }

    func update(state: SyncState) {
        let didFinish: Bool
        if case .syncing = previousState, case .ready = state { didFinish = true }
        else { didFinish = false }
        previousState = state
        let color: NSColor
        switch state {
        case .ready: color = NSColor.white.withAlphaComponent(0.86)
        case .syncing: color = accentColor
        case .offline, .needsAuthorization, .failed: color = .systemOrange
        case .sample: color = NSColor.white.withAlphaComponent(0.55)
        }
        statusDot.layer?.backgroundColor = color.cgColor
        isSyncing = state == .syncing
        activityRing.removeAnimation(forKey: "syncRotation")
        statusDot.layer?.removeAnimation(forKey: "syncPulse")
        if isSyncing {
            completionResetWorkItem?.cancel()
            isShowingCompletion = false
            iconView.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)
            activityRing.strokeColor = accentColor.cgColor
            activityRing.strokeEnd = 0.7
            activityRing.opacity = 0.9
            if !shouldReduceMotion {
                let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
                rotation.fromValue = 0
                rotation.toValue = Double.pi * 2
                rotation.duration = 1.5
                rotation.repeatCount = .infinity
                activityRing.add(rotation, forKey: "syncRotation")
            }
        } else if didFinish {
            playCompletionFeedback()
        } else if !isShowingCompletion {
            activityRing.opacity = upcomingCourseID == nil ? 0 : 0.65
        }
        setAccessibilityLabel("教务悬浮助手，\(state.message)，单击查看课表")
        toolTip = "单击查看课表 · 拖到边缘收纳\n\(state.message)"
    }

    func updateUpcomingCourse(_ occurrence: CourseOccurrence?, at date: Date) {
        guard let occurrence else {
            upcomingCourseID = nil
            if !isSyncing, !isShowingCompletion { activityRing.opacity = 0 }
            return
        }
        let minutes = Int(ceil(occurrence.startDate.timeIntervalSince(date) / 60))
        let approaching = minutes > 0 && minutes <= 10
        let isNew = upcomingCourseID != occurrence.course.id
        upcomingCourseID = approaching ? occurrence.course.id : nil
        toolTip = "单击查看课表 · 拖到边缘收纳\n\(occurrence.course.name) · \(occurrence.course.timeText)\n\(occurrence.course.location)"
        guard !isSyncing, !isShowingCompletion else { return }
        activityRing.strokeColor = NSColor.systemOrange.withAlphaComponent(0.8).cgColor
        activityRing.strokeEnd = 1
        activityRing.opacity = approaching ? 0.65 : 0
        if approaching, isNew, !shouldReduceMotion {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.15
            pulse.toValue = 0.8
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = 2
            activityRing.add(pulse, forKey: "upcomingCourse")
        }
    }

    private func playCompletionFeedback() {
        completionResetWorkItem?.cancel()
        isShowingCompletion = true
        iconView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "同步完成")
        activityRing.strokeColor = accentColor.cgColor
        activityRing.strokeEnd = 1
        activityRing.opacity = 0.85
        if !shouldReduceMotion {
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.duration = 0.4
            draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
            activityRing.add(draw, forKey: "completionDraw")
            playScaleKeyframes(values: [0.8, 1.08, 1], duration: 0.34, key: "completion")
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isSyncing else { return }
            self.isShowingCompletion = false
            self.iconView.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)
            CATransaction.begin()
            CATransaction.setAnimationDuration(self.shouldReduceMotion ? 0 : 0.2)
            self.activityRing.opacity = self.upcomingCourseID == nil ? 0 : 0.65
            self.activityRing.strokeColor = NSColor.systemOrange.cgColor
            CATransaction.commit()
        }
        completionResetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private var shouldReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var currentScale: CGFloat {
        if let value = iconView.layer?.presentation()?.value(forKeyPath: "transform.scale") as? NSNumber {
            return CGFloat(value.doubleValue)
        }
        return isHovered ? 1.045 : 1
    }

    private func playTapFeedback() {
        playScaleKeyframes(values: [currentScale, 0.92, isHovered ? 1.045 : 1], duration: 0.13, key: "tap")
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
        CATransaction.begin()
        CATransaction.setAnimationDuration(shouldReduceMotion ? 0 : 0.14)
        surfaceTint.backgroundColor = color.cgColor
        CATransaction.commit()
    }
}

@MainActor
final class FloatingEdgeHandle: NSView {
    enum Side: String { case left, right }

    weak var delegate: FloatingBallControlDelegate?
    let side: Side
    var isHoverArmed = false
    private let glassView = AcademicGlassEffectView(frame: .zero)
    private var isHovered = false
    private var hoverRevealWorkItem: DispatchWorkItem?
    private let hoverRevealDelay: TimeInterval = 0.18

    override var isOpaque: Bool { false }

    init(side: Side) {
        self.side = side
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        glassView.layer?.borderWidth = 0.8
        addSubview(glassView)
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

    override func layout() {
        super.layout()
        let width: CGFloat = isHovered ? 10 : 8
        let x = side == .left ? 0 : bounds.maxX - width
        glassView.frame = NSRect(x: x, y: 4, width: width, height: max(bounds.height - 8, 0))
        glassView.layer?.cornerRadius = width / 2
        glassView.layer?.borderColor = NSColor.white.withAlphaComponent(isHovered ? 0.50 : 0.32).cgColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsLayout = true
        guard isHoverArmed else { return }
        hoverRevealWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isHovered, self.isHoverArmed else { return }
            self.hoverRevealWorkItem = nil
            self.delegate?.floatingEdgeHandleEntered()
        }
        hoverRevealWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverRevealDelay, execute: workItem)
    }

    override func mouseExited(with event: NSEvent) {
        hoverRevealWorkItem?.cancel()
        hoverRevealWorkItem = nil
        isHovered = false
        isHoverArmed = true
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        hoverRevealWorkItem?.cancel()
        hoverRevealWorkItem = nil
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        delegate?.floatingEdgeHandleClicked()
    }

    override func accessibilityPerformPress() -> Bool {
        hoverRevealWorkItem?.cancel()
        hoverRevealWorkItem = nil
        delegate?.floatingEdgeHandleClicked()
        return true
    }
}
