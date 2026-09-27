import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class FloatingPanelController: NSObject, FloatingBallControlDelegate {
    private enum EdgeRevealReason: Equatable { case hover, click }

    private let store: ScheduleStore
    private let onAuthorize: () -> Void
    private let onSync: () -> Void
    private let onPortalHome: () -> Void
    private let onQuit: () -> Void
    private let ball: NSPanel
    private let schedulePanel: NSPanel
    private let ballControl = FloatingBallControl(frame: NSRect(x: 0, y: 0, width: 58, height: 58))
    private var edgeHandle: FloatingEdgeHandle?
    private var stateObservation: AnyCancellable?
    private var panelMoveObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?
    private var localEventMonitor: Any?
    private var pendingPanelVisibility: Bool?
    private var panelOpenedAt: TimeInterval = 0
    private var nextCourseObservation: AnyCancellable?
    private var ballOrigin = NSPoint.zero
    private var pointerOrigin = NSPoint.zero
    private var panelOriginAtBallDrag = NSPoint.zero
    private var panelBallOffset = NSPoint.zero
    private var panelPointerOrigin = NSPoint.zero
    private var panelBallOriginAtDrag = NSPoint.zero
    private var panelDragStartOrigin = NSPoint.zero
    private var isScheduleShown = false
    private var isPanelDragging = false
    private var isPanelAnimating = false
    private var hiddenSide: FloatingEdgeHandle.Side?
    private var edgeAffinity: FloatingEdgeHandle.Side?
    private var edgeReturnWorkItem: DispatchWorkItem?
    private var edgeReturnGeneration = 0
    private var ballTransitionGeneration = 0
    private var ballMovedSinceEdgeReveal = false
    private let savedXKey = "floatingBallX"
    private let savedYKey = "floatingBallY"
    private let savedEdgeKey = "floatingBallEdge"
    private let ballSize = NSSize(width: 58, height: 58)
    private let edgeHandleSize = NSSize(width: 22, height: 48)
    private let panelSize = NSSize(width: 390, height: 590)
    private let edgeSnapDistance: CGFloat = 76
    private let edgeInset: CGFloat = 8
    private let panelBallGap: CGFloat = 8
    private let edgeReturnDelay: TimeInterval = 1

    init(
        store: ScheduleStore,
        onAuthorize: @escaping () -> Void,
        onSync: @escaping () -> Void,
        onPortalHome: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.store = store
        self.onAuthorize = onAuthorize
        self.onSync = onSync
        self.onPortalHome = onPortalHome
        self.onQuit = onQuit
        ball = FloatingPanelController.makePanel(size: NSSize(width: 58, height: 58), keyable: false)
        schedulePanel = FloatingPanelController.makePanel(size: NSSize(width: 390, height: 590), keyable: true)
        super.init()

        ball.hasShadow = false
        ball.level = NSWindow.Level(rawValue: schedulePanel.level.rawValue + 1)
        ballControl.delegate = self
        ball.contentView = ballControl
        stateObservation = store.$syncState.sink { [weak ballControl] state in
            ballControl?.update(state: state)
        }
        nextCourseObservation = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.ballControl.updateUpcomingCourse(self.store.nextCourse(reference: self.store.localDate), at: self.store.localDate)
            }
        }
        schedulePanel.contentView = FirstClickHostingView(rootView: SchedulePanelView(
            store: store,
            onDismiss: { [weak self] in self?.hideSchedule() },
            onAuthorize: onAuthorize,
            onSync: onSync,
            onPortalHome: onPortalHome,
            onQuit: onQuit,
            onPanelDragBegan: { [weak self] point in self?.panelDragBegan(at: point) },
            onPanelDragged: { [weak self] point in self?.panelDragged(to: point) },
            onPanelDragEnded: { [weak self] in self?.panelDragEnded() }
        ))
        panelMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: schedulePanel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.panelDidMove() }
        }
    }

    func start() {
        positionInitially()
        installInteractionMonitors()
        bringBallToFront()
    }

    func stop() {
        cancelEdgeReturn()
        ball.orderOut(nil)
        schedulePanel.orderOut(nil)
        isScheduleShown = false
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        outsideClickMonitor = nil
        localEventMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if let panelMoveObserver {
            NotificationCenter.default.removeObserver(panelMoveObserver)
            self.panelMoveObserver = nil
        }
    }

    func toggleSchedule() {
        if isPanelAnimating {
            pendingPanelVisibility = !(pendingPanelVisibility ?? isScheduleShown)
            return
        }
        if hiddenSide != nil {
            revealBall(reason: .click) { [weak self] in self?.showSchedule() }
            return
        }
        isScheduleShown ? hideSchedule() : showSchedule()
    }

    func showSchedule() {
        if isPanelAnimating {
            pendingPanelVisibility = true
            return
        }
        if hiddenSide != nil {
            revealBall(reason: .click) { [weak self] in self?.showSchedule() }
            return
        }
        guard !isScheduleShown,
              let screen = targetScreen(for: ball.frame) else { return }
        cancelEdgeReturn()
        let targetFrame = panelFrame(anchoredTo: ball.frame, on: screen)
        panelBallOffset = NSPoint(
            x: ball.frame.origin.x - targetFrame.origin.x,
            y: ball.frame.origin.y - targetFrame.origin.y
        )
        let startFrame = targetFrame.insetBy(dx: shouldReduceMotion ? 0 : 10, dy: shouldReduceMotion ? 0 : 12)
        isScheduleShown = true
        panelOpenedAt = ProcessInfo.processInfo.systemUptime
        isPanelAnimating = true
        schedulePanel.alphaValue = shouldReduceMotion ? 1 : 0.08
        schedulePanel.setFrame(startFrame, display: false)
        schedulePanel.orderFrontRegardless()
        bringBallToFront()
        schedulePanel.makeKey()
        ballControl.playOpenFeedback()
        animatePanel(to: targetFrame, alpha: 1, duration: 0.24) { [weak self] in
            guard let self else { return }
            self.isPanelAnimating = false
            self.bringBallToFront()
            self.schedulePanel.makeKey()
            self.applyPendingPanelVisibility()
        }
    }

    func hideSchedule() {
        if isPanelAnimating {
            pendingPanelVisibility = false
            return
        }
        guard isScheduleShown else { return }
        cancelEdgeReturn()
        isScheduleShown = false
        isPanelAnimating = true
        ball.orderFrontRegardless()
        ballControl.playCloseFeedback()
        let endFrame = schedulePanel.frame.insetBy(dx: shouldReduceMotion ? 0 : 8, dy: shouldReduceMotion ? 0 : 10)
        animatePanel(to: endFrame, alpha: shouldReduceMotion ? 1 : 0, duration: 0.16) { [weak self] in
            guard let self else { return }
            self.schedulePanel.orderOut(nil)
            self.schedulePanel.alphaValue = 1
            self.schedulePanel.setFrame(NSRect(origin: self.schedulePanel.frame.origin, size: self.panelSize), display: false)
            self.isPanelAnimating = false
            if let side = self.dockingSide(for: self.ball.frame) {
                self.edgeAffinity = side
                self.ballMovedSinceEdgeReveal = false
                UserDefaults.standard.set(side.rawValue, forKey: self.savedEdgeKey)
                self.saveBallPosition()
                self.scheduleEdgeReturn()
            } else {
                self.edgeAffinity = nil
                UserDefaults.standard.removeObject(forKey: self.savedEdgeKey)
                self.saveBallPosition()
            }
            self.applyPendingPanelVisibility()
        }
    }

    func floatingBallTapped() {
        toggleSchedule()
    }

    func floatingBallDragBegan(at screenPoint: NSPoint) {
        cancelEdgeReturn()
        pointerOrigin = screenPoint
        ballOrigin = ball.frame.origin
        panelOriginAtBallDrag = schedulePanel.frame.origin
    }

    func floatingBallDragged(to screenPoint: NSPoint) {
        ballMovedSinceEdgeReveal = true
        edgeAffinity = nil
        UserDefaults.standard.removeObject(forKey: savedEdgeKey)
        let delta = NSSize(width: screenPoint.x - pointerOrigin.x, height: screenPoint.y - pointerOrigin.y)
        ball.setFrameOrigin(NSPoint(x: ballOrigin.x + delta.width, y: ballOrigin.y + delta.height))
        if isScheduleShown {
            schedulePanel.setFrameOrigin(NSPoint(
                x: panelOriginAtBallDrag.x + delta.width,
                y: panelOriginAtBallDrag.y + delta.height
            ))
            ball.orderFrontRegardless()
        }
    }

    func floatingBallDragEnded() {
        finishDrag()
    }

    func floatingEdgeHandleEntered() {
        revealBall(reason: .hover)
    }

    func floatingEdgeHandleClicked() {
        revealBall(reason: .click) { [weak self] in self?.showSchedule() }
    }

    private func positionInitially() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: savedXKey) != nil, defaults.object(forKey: savedYKey) != nil {
            ball.setFrameOrigin(NSPoint(x: defaults.double(forKey: savedXKey), y: defaults.double(forKey: savedYKey)))
            if let raw = defaults.string(forKey: savedEdgeKey), let side = FloatingEdgeHandle.Side(rawValue: raw) {
                edgeAffinity = side
                attachBall(to: side, animated: false)
            } else {
                // Re-evaluate older saved positions so a ball that previously
                // stopped at the screen edge is repaired into the edge handle.
                finishDrag()
            }
            return
        }
        ball.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - ball.frame.width - 22, y: screen.visibleFrame.midY))
    }

    private func finishDrag() {
        guard let screen = targetScreen(for: ball.frame) else { return }
        if let side = dockingSide(for: ball.frame, on: screen) {
            alignVisibleBall(to: side, on: screen, movingPanel: isScheduleShown)
            edgeAffinity = side
            ballMovedSinceEdgeReveal = false
            UserDefaults.standard.set(side.rawValue, forKey: savedEdgeKey)
            if isScheduleShown {
                saveBallPosition()
            } else {
                attachBall(to: side, on: screen)
            }
            return
        }

        edgeAffinity = nil
        ballMovedSinceEdgeReveal = true
        UserDefaults.standard.removeObject(forKey: savedEdgeKey)
        if isScheduleShown {
            clampVisiblePair(on: screen)
        } else {
            clampVisibleBall(on: screen)
        }
        saveBallPosition()
    }

    private func saveBallPosition() {
        let origin: NSPoint
        if let side = hiddenSide, let screen = targetScreen(for: ball.frame) {
            let visible = screen.visibleFrame
            origin = NSPoint(
                x: side == .left ? visible.minX + edgeInset : visible.maxX - ballSize.width - edgeInset,
                y: ball.frame.midY - ballSize.height / 2
            )
        } else {
            origin = ball.frame.origin
        }
        UserDefaults.standard.set(origin.x, forKey: savedXKey)
        UserDefaults.standard.set(origin.y, forKey: savedYKey)
    }

    private func attachBall(
        to side: FloatingEdgeHandle.Side,
        on preferredScreen: NSScreen? = nil,
        animated: Bool = true
    ) {
        guard !isScheduleShown, !isPanelAnimating, hiddenSide == nil else { return }
        guard let screen = preferredScreen ?? targetScreen(for: ball.frame) else { return }
        cancelEdgeReturn()
        edgeAffinity = side
        ballMovedSinceEdgeReveal = false
        let handle = FloatingEdgeHandle(side: side)
        handle.delegate = self
        handle.isHoverArmed = false
        edgeHandle = handle
        hiddenSide = side
        let visible = screen.visibleFrame
        let y = min(max(ball.frame.midY - edgeHandleSize.height / 2, visible.minY + 8), visible.maxY - edgeHandleSize.height - 8)
        let x = side == .left ? visible.minX : visible.maxX - edgeHandleSize.width
        let targetFrame = NSRect(x: x, y: y, width: edgeHandleSize.width, height: edgeHandleSize.height)
        ball.contentView = handle
        UserDefaults.standard.set(side.rawValue, forKey: savedEdgeKey)
        animateBall(to: targetFrame, duration: animated ? 0.16 : 0) { [weak self, weak handle] in
            guard let self, let handle, self.hiddenSide == side else { return }
            handle.isHoverArmed = !self.ball.frame.contains(NSEvent.mouseLocation)
            self.saveBallPosition()
        }
    }

    private func targetScreen(for frame: NSRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return NSScreen.main }
        let intersecting = screens.max { lhs, rhs in
            lhs.visibleFrame.intersection(frame).width * lhs.visibleFrame.intersection(frame).height
                < rhs.visibleFrame.intersection(frame).width * rhs.visibleFrame.intersection(frame).height
        }
        if let intersecting,
           intersecting.visibleFrame.intersection(frame).width * intersecting.visibleFrame.intersection(frame).height > 0 {
            return intersecting
        }
        return screens.min { lhs, rhs in
            hypot(lhs.visibleFrame.midX - frame.midX, lhs.visibleFrame.midY - frame.midY)
                < hypot(rhs.visibleFrame.midX - frame.midX, rhs.visibleFrame.midY - frame.midY)
        } ?? NSScreen.main ?? screens.first
    }

    private func revealBall(
        reason: EdgeRevealReason,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        cancelEdgeReturn()
        // A hover can already have revealed the ball before the same pointer's
        // click reaches the edge handle. The click must still open the panel.
        guard let side = hiddenSide else {
            completion?()
            return
        }
        guard let screen = targetScreen(for: ball.frame) else { return }
        edgeAffinity = side
        ballMovedSinceEdgeReveal = false
        let visible = screen.visibleFrame
        let y = min(max(ball.frame.midY - ballSize.height / 2, visible.minY + 8), visible.maxY - ballSize.height - 8)
        // Keep the revealed ball over the edge handle's hit area. When the
        // pointer enters the handle it may reveal before mouseDown arrives;
        // touching the screen edge ensures that the same click is received
        // by the ball instead of landing in the gap between both frames.
        let x = side == .left ? visible.minX : visible.maxX - ballSize.width
        let targetFrame = NSRect(x: x, y: y, width: ballSize.width, height: ballSize.height)
        ball.contentView = ballControl
        edgeHandle = nil
        hiddenSide = nil
        UserDefaults.standard.set(side.rawValue, forKey: savedEdgeKey)
        // Install the full hit target before the next mouse event. Animating
        // the window bounds here can lose a fast click at the screen edge.
        ballTransitionGeneration &+= 1
        ball.setFrame(targetFrame, display: true)
        bringBallToFront()
        ballControl.playRevealFeedback()
        saveBallPosition()
        if reason == .hover { scheduleEdgeReturn() }
        completion?()
    }

    private func bringBallToFront() {
        ball.orderFrontRegardless()
    }

    private func applyPendingPanelVisibility() {
        guard let shouldShow = pendingPanelVisibility else { return }
        pendingPanelVisibility = nil
        shouldShow ? showSchedule() : hideSchedule()
    }

    private func installInteractionMonitors() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            // Capture the event's position now. The system pointer may already
            // be elsewhere when a deferred callback or accessibility click runs.
            let screenPoint: NSPoint
            if let location = event.cgEvent?.location,
               let primary = NSScreen.screens.first {
                screenPoint = NSPoint(x: location.x, y: primary.frame.maxY - location.y)
            } else {
                screenPoint = NSEvent.mouseLocation
            }
            let windowNumber = event.windowNumber
            let timestamp = event.timestamp
            Task { @MainActor [weak self] in
                guard let self,
                      windowNumber != self.schedulePanel.windowNumber,
                      windowNumber != self.ball.windowNumber else { return }
                self.dismissIfOutside(at: screenPoint, eventTimestamp: timestamp)
            }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                // Escape belongs to the panel only while it owns keyboard focus;
                // authorization windows and native menus keep their own Escape.
                let belongsToPanel = event.window === self.schedulePanel
                    || (event.window == nil && self.schedulePanel.isKeyWindow)
                if event.keyCode == 53, self.isScheduleShown, belongsToPanel {
                    self.hideSchedule()
                    return nil
                }
                return event
            }
            guard let window = event.window else { return event }
            if window === self.schedulePanel || window === self.ball
                || window.parent === self.schedulePanel
                || window.level.rawValue >= NSWindow.Level.popUpMenu.rawValue {
                return event
            }
            let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
            self.dismissIfOutside(at: screenPoint, eventTimestamp: event.timestamp)
            return event
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.screensDidChange() }
        }
    }

    private func dismissIfOutside(at point: NSPoint, eventTimestamp: TimeInterval) {
        guard isScheduleShown, !isPanelDragging, eventTimestamp >= panelOpenedAt else { return }
        guard !ball.frame.contains(point), !schedulePanel.frame.contains(point) else { return }
        hideSchedule()
    }

    private func screensDidChange() {
        guard let screen = targetScreen(for: ball.frame) else { return }
        cancelEdgeReturn()
        if let side = hiddenSide {
            hiddenSide = nil
            ball.contentView = ballControl
            ball.setContentSize(ballSize)
            attachBall(to: side, on: screen, animated: false)
        } else {
            clampVisibleBall(on: screen)
            if isScheduleShown {
                schedulePanel.setFrame(panelFrame(anchoredTo: ball.frame, on: screen), display: true)
            }
            saveBallPosition()
        }
    }

    private func dockingSide(for frame: NSRect, on preferredScreen: NSScreen? = nil) -> FloatingEdgeHandle.Side? {
        guard let screen = preferredScreen ?? targetScreen(for: frame) else { return nil }
        let visible = screen.visibleFrame
        let reachesLeft = frame.minX <= visible.minX + edgeSnapDistance
        let reachesRight = frame.maxX >= visible.maxX - edgeSnapDistance
        if reachesLeft && reachesRight { return frame.midX < visible.midX ? .left : .right }
        if reachesLeft { return .left }
        if reachesRight { return .right }
        return nil
    }

    private func alignVisibleBall(to side: FloatingEdgeHandle.Side, on screen: NSScreen, movingPanel: Bool) {
        let visible = screen.visibleFrame
        let target = NSPoint(
            x: side == .left ? visible.minX + edgeInset : visible.maxX - ballSize.width - edgeInset,
            y: min(max(ball.frame.origin.y, visible.minY + edgeInset), visible.maxY - ballSize.height - edgeInset)
        )
        ball.setFrameOrigin(target)
        if movingPanel {
            // Crossing the display changes which side has room for the popover.
            // Re-anchor instead of carrying an off-screen relative offset.
            schedulePanel.setFrame(panelFrame(anchoredTo: ball.frame, on: screen), display: true)
            ball.orderFrontRegardless()
        }
    }

    private func clampVisibleBall(on screen: NSScreen) {
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: min(max(ball.frame.origin.x, visible.minX + edgeInset), visible.maxX - ballSize.width - edgeInset),
            y: min(max(ball.frame.origin.y, visible.minY + edgeInset), visible.maxY - ballSize.height - edgeInset)
        )
        ball.setFrameOrigin(origin)
    }

    private func clampVisiblePair(on screen: NSScreen) {
        let available = screen.visibleFrame.insetBy(dx: edgeInset, dy: edgeInset)
        let union = schedulePanel.frame.union(ball.frame)
        var delta = NSSize.zero
        if union.width <= available.width {
            if union.minX < available.minX { delta.width = available.minX - union.minX }
            if union.maxX + delta.width > available.maxX { delta.width += available.maxX - (union.maxX + delta.width) }
        }
        if union.height <= available.height {
            if union.minY < available.minY { delta.height = available.minY - union.minY }
            if union.maxY + delta.height > available.maxY { delta.height += available.maxY - (union.maxY + delta.height) }
        }
        guard abs(delta.width) > 0.1 || abs(delta.height) > 0.1 else { return }
        schedulePanel.setFrameOrigin(NSPoint(
            x: schedulePanel.frame.origin.x + delta.width,
            y: schedulePanel.frame.origin.y + delta.height
        ))
        ball.setFrameOrigin(NSPoint(
            x: ball.frame.origin.x + delta.width,
            y: ball.frame.origin.y + delta.height
        ))
        ball.orderFrontRegardless()
    }

    private func panelFrame(anchoredTo ballFrame: NSRect, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let proposedX = ballFrame.midX < visible.midX
            ? ballFrame.maxX + panelBallGap
            : ballFrame.minX - panelSize.width - panelBallGap
        let minX = visible.minX + edgeInset
        let maxX = max(minX, visible.maxX - panelSize.width - edgeInset)
        let minY = visible.minY + edgeInset
        let maxY = max(minY, visible.maxY - panelSize.height - edgeInset)
        return NSRect(
            x: min(max(proposedX, minX), maxX),
            y: min(max(ballFrame.midY - panelSize.height / 2, minY), maxY),
            width: panelSize.width,
            height: panelSize.height
        )
    }

    private func panelDragBegan(at screenPoint: NSPoint) {
        guard isScheduleShown, !isPanelAnimating else { return }
        cancelEdgeReturn()
        isPanelDragging = true
        panelPointerOrigin = screenPoint
        panelDragStartOrigin = schedulePanel.frame.origin
        panelBallOriginAtDrag = ball.frame.origin
        panelBallOffset = NSPoint(
            x: ball.frame.origin.x - schedulePanel.frame.origin.x,
            y: ball.frame.origin.y - schedulePanel.frame.origin.y
        )
    }

    private func panelDragged(to screenPoint: NSPoint) {
        guard isPanelDragging, !isPanelAnimating else { return }
        let delta = NSSize(
            width: screenPoint.x - panelPointerOrigin.x,
            height: screenPoint.y - panelPointerOrigin.y
        )
        schedulePanel.setFrameOrigin(NSPoint(
            x: panelDragStartOrigin.x + delta.width,
            y: panelDragStartOrigin.y + delta.height
        ))
        ball.setFrameOrigin(NSPoint(
            x: panelBallOriginAtDrag.x + delta.width,
            y: panelBallOriginAtDrag.y + delta.height
        ))
        ball.orderFrontRegardless()
    }

    private func panelDidMove() {
        guard isPanelDragging, !isPanelAnimating else { return }
        ball.setFrameOrigin(NSPoint(
            x: schedulePanel.frame.origin.x + panelBallOffset.x,
            y: schedulePanel.frame.origin.y + panelBallOffset.y
        ))
        ball.orderFrontRegardless()
    }

    private func panelDragEnded() {
        guard isPanelDragging else { return }
        panelDidMove()
        isPanelDragging = false
        let moved = hypot(
            schedulePanel.frame.origin.x - panelDragStartOrigin.x,
            schedulePanel.frame.origin.y - panelDragStartOrigin.y
        ) > 2
        ballMovedSinceEdgeReveal = moved
        guard let screen = targetScreen(for: ball.frame) else { return }
        let dockSide = dockingSide(for: ball.frame, on: screen)
        if let side = dockSide {
            alignVisibleBall(to: side, on: screen, movingPanel: true)
            edgeAffinity = side
            ballMovedSinceEdgeReveal = false
            UserDefaults.standard.set(side.rawValue, forKey: savedEdgeKey)
        } else {
            clampVisiblePair(on: screen)
            edgeAffinity = nil
            UserDefaults.standard.removeObject(forKey: savedEdgeKey)
        }
        saveBallPosition()
    }

    private func scheduleEdgeReturn() {
        cancelEdgeReturn()
        guard hiddenSide == nil, !isScheduleShown, !isPanelAnimating, !isPanelDragging,
              let side = edgeAffinity, !ballMovedSinceEdgeReveal else { return }
        let generation = edgeReturnGeneration
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.edgeReturnGeneration == generation,
                      self.hiddenSide == nil,
                      !self.isScheduleShown,
                      !self.isPanelAnimating,
                      !self.isPanelDragging,
                      !self.ballMovedSinceEdgeReveal,
                      self.edgeAffinity == side,
                      self.dockingSide(for: self.ball.frame) == side else { return }
                if self.ball.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) {
                    self.scheduleEdgeReturn()
                    return
                }
                self.edgeReturnWorkItem = nil
                self.attachBall(to: side)
            }
        }
        edgeReturnWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + edgeReturnDelay, execute: workItem)
    }

    private func cancelEdgeReturn() {
        edgeReturnGeneration &+= 1
        edgeReturnWorkItem?.cancel()
        edgeReturnWorkItem = nil
    }

    private var shouldReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func animatePanel(
        to frame: NSRect,
        alpha: CGFloat,
        duration: TimeInterval,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        let actualDuration = shouldReduceMotion ? 0 : duration
        guard actualDuration > 0 else {
            schedulePanel.setFrame(frame, display: true)
            schedulePanel.alphaValue = alpha
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = actualDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            schedulePanel.animator().setFrame(frame, display: true)
            schedulePanel.animator().alphaValue = alpha
        } completionHandler: {
            Task { @MainActor in completion() }
        }
    }

    private func animateBall(
        to frame: NSRect,
        duration: TimeInterval,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        ballTransitionGeneration &+= 1
        let generation = ballTransitionGeneration
        let actualDuration = shouldReduceMotion ? 0 : duration
        guard actualDuration > 0 else {
            ball.setFrame(frame, display: true)
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = actualDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ball.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.ballTransitionGeneration == generation else { return }
                completion()
            }
        }
    }

    private static func makePanel(size: NSSize, keyable: Bool) -> NSPanel {
        let panel = InteractivePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.allowsKey = keyable
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}

private final class InteractivePanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

private struct AcademicGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> AcademicGlassEffectView {
        AcademicGlassEffectView(frame: .zero)
    }
    func updateNSView(_ nsView: AcademicGlassEffectView, context: Context) { }
}

private enum AcademicPalette {
    static let accent = Color(red: 0.77, green: 0.70, blue: 0.96)
    static let courseColors: [Color] = [
        accent.opacity(0.8), .white.opacity(0.48),
        Color(red: 0.66, green: 0.62, blue: 0.78), .white.opacity(0.66),
        Color(red: 0.78, green: 0.73, blue: 0.84), .white.opacity(0.40)
    ]
    static let card = Color.white.opacity(0.065)
    static let separator = Color.white.opacity(0.10)
}

private struct SchedulePanelView: View {
    @ObservedObject var store: ScheduleStore
    let onDismiss: () -> Void
    let onAuthorize: () -> Void
    let onSync: () -> Void
    let onPortalHome: () -> Void
    let onQuit: () -> Void
    let onPanelDragBegan: (NSPoint) -> Void
    let onPanelDragged: (NSPoint) -> Void
    let onPanelDragEnded: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection = 0
    @State private var scheduleScope = 0
    @AppStorage("gradeTermFilter") private var selectedGradeTerm = "all"
    @State private var selectedSemesterWeek = 1
    @State private var gradeSearch = ""
    @State private var showSyncSuccess = false
    @State private var showClearConfirmation = false
    private let weekdayLabels = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 5) {
                navigationButton("课表", icon: "calendar", index: 0)
                navigationButton("成绩", icon: "chart.bar.xaxis", index: 1)
                navigationButton("我的", icon: "person.crop.circle", index: 2)
            }
            .padding(4)
            .background(Color.primary.opacity(0.045), in: Capsule())
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            Group {
                if selection == 0 { scheduleView }
                else if selection == 1 { gradesView }
                else { profileView }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
            footer
        }
        .frame(width: 390, height: 590)
        .background(AcademicGlassBackground().allowsHitTesting(false))
        .preferredColorScheme(.dark)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(
            LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.09)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
        .tint(AcademicPalette.accent)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: selection)
        .overlay(alignment: .top) {
            PanelDragHandle(onDragBegan: onPanelDragBegan, onDragged: onPanelDragged, onDragEnded: onPanelDragEnded)
                .frame(width: 130, height: 16)
        }
        .overlay(alignment: .bottom) {
            if showSyncSuccess {
                Label("课表已更新", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AcademicPalette.accent)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background { AcademicGlassBackground().clipShape(Capsule()).allowsHitTesting(false) }
                    .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                    .padding(.bottom, 62)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: store.syncState) { oldValue, newValue in
            if case .syncing = oldValue, case .ready = newValue {
                withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.8)) { showSyncSuccess = true }
            }
        }
        .task(id: showSyncSuccess) {
            guard showSyncSuccess else { return }
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { showSyncSuccess = false }
        }
        .alert("清除本机课表和成绩缓存？", isPresented: $showClearConfirmation) {
            Button("取消", role: .cancel) { }
            Button("清除缓存", role: .destructive) { store.clearEndpoint() }
        } message: { Text("下一次联网同步会重新读取教务数据。") }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AcademicPalette.accent)
                .frame(width: 36, height: 36)
                .background(AcademicPalette.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text("教务随行").font(.system(size: 17, weight: .bold, design: .rounded))
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 5, height: 5)
                    Text(headerStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let week = store.currentWeek {
                Text("第 \(week) 周").font(.caption.weight(.medium))
                    .foregroundStyle(AcademicPalette.accent)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(AcademicPalette.accent.opacity(0.09), in: Capsule())
            }
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(PanelIconButtonStyle()).help("收起课表 · Esc")
                .accessibilityLabel("收起课表")
        }
        .padding(.horizontal, 16).padding(.top, 21).padding(.bottom, 13)
    }

    private func navigationButton(_ title: String, icon: String, index: Int) -> some View {
        Button { selection = index } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: selection == index ? .semibold : .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .foregroundStyle(selection == index ? AcademicPalette.accent : Color.secondary)
                .background(selection == index ? AcademicPalette.card : .clear, in: Capsule())
        }
        .buttonStyle(ResponsiveButtonStyle())
        .accessibilityAddTraits(selection == index ? .isSelected : [])
    }

    private var scheduleView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                ForEach(Array(["今天", "明天", "本周", "学期"].enumerated()), id: \.offset) { index, title in
                    Button { scheduleScope = index } label: {
                        VStack(spacing: 5) {
                            Text(title).font(.system(size: 12, weight: scheduleScope == index ? .bold : .medium))
                                .foregroundStyle(scheduleScope == index ? Color.primary : .secondary)
                            Capsule().fill(scheduleScope == index ? AcademicPalette.accent : .clear).frame(height: 3)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ResponsiveButtonStyle())
                    .accessibilityAddTraits(scheduleScope == index ? .isSelected : [])
                }
            }.padding(.horizontal, 20)
            Group {
                if scheduleScope < 2 { dayView(isTomorrow: scheduleScope == 1) }
                else if scheduleScope == 2 {
                    if let week = store.currentWeek {
                        weeklyList(courses: store.courses(forWeek: week), title: "本周 · \(store.courses(forWeek: week).count) 次课")
                    } else { teachingWeekUnavailable }
                } else { semesterView }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func dayView(isTomorrow: Bool) -> some View {
        let date = isTomorrow ? Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: store.localDate) ?? store.localDate : store.localDate
        let courses = isTomorrow ? store.tomorrowCourses(reference: store.localDate) : store.todayCourses(reference: store.localDate)
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(date.formatted(.dateTime.month().day().weekday(.wide)))
                    Spacer()
                    if store.currentWeek != nil { Text("\(courses.count) 次课") }
                }.font(.caption).foregroundStyle(.secondary)
                if store.currentWeek == nil { teachingWeekUnavailable }
                else {
                    if !isTomorrow, let next = store.nextCourse(reference: store.localDate) { nextCourseCard(next) }
                    if courses.isEmpty {
                        emptyState(isTomorrow ? "明天没有排课" : "今天没有排课", icon: isTomorrow ? "sunrise" : "sun.max", detail: "课表已留在身边，安心安排自己的时间。")
                    } else {
                        ForEach(courses) { course in
                            CourseCard(course: course, relativeTo: isTomorrow ? nil : store.localDate)
                        }
                    }
                }
            }.padding(.horizontal, 16).padding(.bottom, 12)
        }
    }

    private func nextCourseCard(_ next: CourseOccurrence) -> some View {
        let ongoing = next.isInProgress(at: store.localDate)
        let minutes = max(Int(ceil(next.startDate.timeIntervalSince(store.localDate) / 60)), 0)
        let isToday = Calendar.autoupdatingCurrent.isDate(next.startDate, inSameDayAs: store.localDate)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(ongoing ? "正在上课" : "下一节课", systemImage: ongoing ? "waveform" : "arrow.up.right")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(ongoing ? "\(next.endDate.formatted(.dateTime.hour().minute())) 下课" : (isToday && minutes <= 90 ? "\(minutes) 分钟后" : next.startDate.formatted(.dateTime.weekday(.abbreviated).hour().minute())))
                    .font(.caption.weight(.medium)).monospacedDigit()
            }.foregroundStyle(AcademicPalette.accent)
            Text(next.course.name).font(.system(size: 16, weight: .semibold)).lineLimit(2)
            Label(next.course.location.isEmpty ? "地点待教务更新" : next.course.location, systemImage: "mappin.and.ellipse")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if ongoing {
                ProgressView(value: min(max(store.localDate.timeIntervalSince(next.startDate) / max(next.endDate.timeIntervalSince(next.startDate), 1), 0), 1))
                    .tint(AcademicPalette.accent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AcademicPalette.card, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(AcademicPalette.accent.opacity(0.22), lineWidth: 1))
    }

    private var teachingWeekUnavailable: some View {
        VStack(spacing: 10) {
            emptyState("先确认当前教学周", icon: "calendar.badge.clock", detail: store.courses.isEmpty ? "登录一次，课表、成绩与个人信息便会保存在本机。" : "已保存学期课表；联网同步后显示今天和下一节课，也可先查看“学期”。")
            Button(store.courses.isEmpty ? "登录教务系统" : "同步教学周", action: store.courses.isEmpty ? onAuthorize : onSync)
                .buttonStyle(GlassActionButtonStyle()).disabled(isSyncing)
        }.padding(.bottom, 20)
    }

    private var semesterView: some View {
        VStack(spacing: 10) {
            HStack {
                Text(store.currentTerm.isEmpty ? "本学期课表" : store.currentTerm).lineLimit(1)
                Spacer()
                Picker("教学周", selection: $selectedSemesterWeek) {
                    ForEach(1...max(store.maxWeek, 1), id: \.self) { Text("第 \($0) 周").tag($0) }
                }.labelsHidden().frame(width: 102)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
            weeklyList(courses: store.courses(forWeek: selectedSemesterWeek), title: nil)
        }
        .onAppear { selectedSemesterWeek = min(max(store.currentWeek ?? selectedSemesterWeek, 1), max(store.maxWeek, 1)) }
    }

    private func weeklyList(courses: [Course], title: String?) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 9) {
                if let title { Text(title).font(.caption).foregroundStyle(.secondary) }
                ForEach(1...7, id: \.self) { day in
                    let daily = courses.filter { $0.weekday == day }.sorted { $0.startSection < $1.startSection }
                    if !daily.isEmpty {
                        HStack {
                            Text("星期\(weekdayLabels[day - 1])")
                            Spacer()
                            Text("\(daily.count) 次课").foregroundStyle(.secondary)
                        }.font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 5)
                        ForEach(daily) { CourseCard(course: $0) }
                    }
                }
                if courses.isEmpty { emptyState("这一周没有排课", icon: "calendar", detail: "可以切换教学周，查看已同步的其他课程。") }
            }.padding(.horizontal, 16).padding(.bottom, 12)
        }
    }

    private var gradesView: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索课程名称", text: $gradeSearch).textFieldStyle(.plain)
                if !gradeSearch.isEmpty { Button { gradeSearch = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("清除搜索") }
            }.font(.caption).padding(9).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 16)
            HStack {
                Text("成绩范围").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("成绩范围", selection: $selectedGradeTerm) {
                    Text("全部学期").tag("all")
                    ForEach(store.gradeTerms, id: \.self) { term in Text(shortTerm(term)).tag(term) }
                }.labelsHidden().frame(maxWidth: 185)
            }.padding(.horizontal, 16)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    gradeSummary
                    if store.grades.isEmpty { emptyState("暂无成绩缓存", icon: "chart.bar.doc.horizontal", detail: "联网后同步，便可在这里查询课程成绩与学分。") }
                    else if filteredGrades.isEmpty { emptyState("没有匹配的课程", icon: "magnifyingglass", detail: "试试更短的课程名称，或切换为全部学期。") }
                    else {
                        ForEach(displayedGradeTerms, id: \.self) { term in
                            let rows = filteredGrades.filter { $0.term == term }
                            if !rows.isEmpty {
                                Text(shortTerm(term)).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 5)
                                ForEach(rows) { GradeRow(grade: $0) }
                            }
                        }
                    }
                }.padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
    }

    private var gradeSummary: some View {
        let statistics = store.gradeStatistics(forTerm: normalizedGradeTerm == "all" ? nil : normalizedGradeTerm)
        return HStack(spacing: 0) {
            summaryMetric(store.profile.gpa.isEmpty ? "—" : store.profile.gpa, label: "官网总绩点")
            Divider().frame(height: 30)
            summaryMetric(statistics.earnedCredits.formatted(.number.precision(.fractionLength(0...1))), label: "已获学分")
            Divider().frame(height: 30)
            summaryMetric("\(statistics.courseCount)", label: "成绩记录")
        }
        .padding(.vertical, 12)
        .background(AcademicPalette.card, in: RoundedRectangle(cornerRadius: 15))
    }

    private func summaryMetric(_ value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 21, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    private var profileView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 38)).foregroundStyle(AcademicPalette.accent.opacity(0.75))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.profile.name.isEmpty ? "内师大学生" : store.profile.name).font(.headline)
                        Text(store.profile.studentNumber.isEmpty ? "登录后同步个人信息" : store.profile.studentNumber).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(14).background(AcademicPalette.card, in: RoundedRectangle(cornerRadius: 16))
                VStack(spacing: 12) {
                    profileRow("学期", value: store.currentTerm.isEmpty ? "尚未同步" : store.currentTerm)
                    profileRow("教学周", value: store.currentWeek.map { "第 \($0) 周" } ?? "等待官网确认")
                    profileRow("课表更新", value: store.lastUpdated.map { $0.formatted(.dateTime.month().day().hour().minute()) } ?? "尚未同步")
                    profileRow("成绩更新", value: store.gradesUpdatedAt.map { $0.formatted(.dateTime.month().day().hour().minute()) } ?? "尚未同步")
                }.padding(14).background(AcademicPalette.card, in: RoundedRectangle(cornerRadius: 16))
                if !store.syncWarnings.isEmpty {
                    Label(store.syncWarnings.joined(separator: "\n"), systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Button(action: onPortalHome) { Label("打开教务系统", systemImage: "arrow.up.right.square").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.bordered)
                Button(action: onAuthorize) { Label("登录与会话管理", systemImage: "person.badge.key.fill").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.bordered)
                Text("登录会话保留在本机，课表和成绩支持离线查看。学校要求重新验证时，再到官网完成登录。")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("单击悬浮球查看 · Esc 或点外收起\n拖到屏幕左右边缘即可收纳")
                    .font(.caption2).foregroundStyle(.secondary).lineSpacing(3)
            }.padding(.horizontal, 16).padding(.bottom, 12)
        }
    }

    private func profileRow(_ label: String, value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).lineLimit(1) }.font(.caption)
    }

    private func emptyState(_ title: String, icon: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 29, weight: .light)).foregroundStyle(AcademicPalette.accent.opacity(0.65))
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity).padding(.horizontal, 16).padding(.vertical, 28)
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Button(action: onSync) {
                HStack(spacing: 5) {
                    if isSyncing { ProgressView().controlSize(.mini).scaleEffect(0.75).frame(width: 12, height: 12) }
                    else { Image(systemName: "arrow.clockwise") }
                    Text(isSyncing ? "同步中" : "同步")
                }
            }.buttonStyle(GlassActionButtonStyle()).disabled(isSyncing)
            Text(footerStatus).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            Menu {
                Button("打开教务系统", action: onPortalHome)
                Button("登录与会话管理", action: onAuthorize)
                Divider()
                Button("清除课表与成绩缓存", role: .destructive) { showClearConfirmation = true }
                Button("退出教务悬浮助手", action: onQuit)
            } label: { Image(systemName: "ellipsis").frame(width: 22, height: 20) }
                .menuStyle(.borderlessButton).fixedSize().help("更多操作")
        }
        .controlSize(.small).padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.primary.opacity(0.025))
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1) }
    }

    private var isSyncing: Bool { if case .syncing = store.syncState { return true }; return false }
    private var headerStatus: String {
        switch store.syncState {
        case .ready: return "课表在身边"
        case .syncing: return "正在同步教务数据"
        case .offline: return "离线可查看已保存的数据"
        case .sample: return "登录后，课表触手可及"
        case .needsAuthorization: return "需要重新登录"
        case .failed: return "同步未完成，仍可查看缓存"
        }
    }
    private var footerStatus: String {
        if !store.syncWarnings.isEmpty { return "部分信息待更新 · 详见“我的”" }
        if case .ready = store.syncState, let date = store.lastUpdated { return "更新于 \(date.formatted(.dateTime.hour().minute()))" }
        if case .offline = store.syncState { return "已保留本机缓存" }
        if case .needsAuthorization = store.syncState { return "在“我的”中重新登录" }
        if case .failed = store.syncState { return "同步失败，可重试" }
        return "课表 · 成绩 · 个人信息"
    }
    private var statusColor: Color {
        switch store.syncState {
        case .ready: return .white.opacity(0.72)
        case .syncing: return AcademicPalette.accent
        case .offline: return .orange
        case .needsAuthorization, .failed: return .orange
        case .sample: return .secondary
        }
    }
    private var normalizedGradeTerm: String { selectedGradeTerm == "all" || store.gradeTerms.contains(selectedGradeTerm) ? selectedGradeTerm : "all" }
    private var filteredGrades: [GradeRecord] {
        let rows = normalizedGradeTerm == "all" ? store.grades : store.grades(forTerm: normalizedGradeTerm)
        let query = gradeSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { query.isEmpty || $0.courseName.localizedCaseInsensitiveContains(query) }
    }
    private var displayedGradeTerms: [String] { normalizedGradeTerm == "all" ? store.gradeTerms : [normalizedGradeTerm] }
    private func shortTerm(_ term: String) -> String {
        let parts = term.split(separator: "-")
        return parts.count >= 3 ? "\(parts[0])–\(parts[1]) 第\(parts[2])学期" : term
    }
}

private struct PanelDragHandle: View {
    let onDragBegan: (NSPoint) -> Void
    let onDragged: (NSPoint) -> Void
    let onDragEnded: () -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(isHovered ? 0.48 : 0.26))
                .frame(width: isHovered && !reduceMotion ? 46 : 38, height: 4)
                .animation(reduceMotion ? .linear(duration: 0.08) : .easeOut(duration: 0.14), value: isHovered)
            PanelDragRepresentable(
                onDragBegan: onDragBegan,
                onDragged: onDragged,
                onDragEnded: onDragEnded
            )
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help("拖动悬浮窗")
        .accessibilityLabel("拖动悬浮窗")
    }
}

private struct PanelDragRepresentable: NSViewRepresentable {
    let onDragBegan: (NSPoint) -> Void
    let onDragged: (NSPoint) -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> PanelDragNSView {
        PanelDragNSView(onDragBegan: onDragBegan, onDragged: onDragged, onDragEnded: onDragEnded)
    }

    func updateNSView(_ nsView: PanelDragNSView, context: Context) {
        nsView.onDragBegan = onDragBegan
        nsView.onDragged = onDragged
        nsView.onDragEnded = onDragEnded
    }
}

@MainActor
private final class PanelDragNSView: NSView {
    var onDragBegan: (NSPoint) -> Void
    var onDragged: (NSPoint) -> Void
    var onDragEnded: () -> Void
    private var isTrackingDrag = false

    init(
        onDragBegan: @escaping (NSPoint) -> Void,
        onDragged: @escaping (NSPoint) -> Void,
        onDragEnded: @escaping () -> Void
    ) {
        self.onDragBegan = onDragBegan
        self.onDragged = onDragged
        self.onDragEnded = onDragEnded
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
        setAccessibilityLabel("拖动悬浮窗")
    }

    required init?(coder: NSCoder) { fatalError("PanelDragNSView must be created programmatically") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        isTrackingDrag = true
        onDragBegan(NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTrackingDrag else { return }
        onDragged(NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        guard isTrackingDrag else { return }
        isTrackingDrag = false
        onDragEnded()
    }
}

private struct GlassActionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.white.opacity(isEnabled ? 0.94 : 0.55))
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(Color.white.opacity(configuration.isPressed ? 0.15 : 0.075), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(AcademicPalette.accent.opacity(isEnabled ? 0.40 : 0.18), lineWidth: 0.8))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct ResponsiveButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? (compact ? 0.92 : 0.965) : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(reduceMotion ? .linear(duration: 0.06) : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct PanelIconButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold))
            .frame(width: 25, height: 25)
            .background(Color.primary.opacity(configuration.isPressed ? 0.16 : 0.07), in: Circle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(reduceMotion ? .linear(duration: 0.06) : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct CourseCard: View {
    let course: Course
    var relativeTo: Date? = nil

    var body: some View {
        let tint = AcademicPalette.courseColors[abs(course.colorIndex) % AcademicPalette.courseColors.count]
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(tint).frame(width: 6, height: 6).padding(.top, 5)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 10) {
                    Text(course.name).font(.subheadline.weight(.semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(course.sectionText).font(.caption.weight(.medium))
                        if !course.timeText.isEmpty { Text(course.timeText).font(.system(size: 10, design: .rounded)).monospacedDigit() }
                    }.foregroundStyle(.secondary).fixedSize()
                }
                if !course.location.isEmpty { Label(course.location, systemImage: "mappin.and.ellipse").font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                HStack(spacing: 5) {
                    if !course.teacher.isEmpty { Text(course.teacher).lineLimit(1) }
                    Spacer(minLength: 4)
                    Text(compactWeeks).lineLimit(1)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                if let relativeTo, let interval = SectionTime.interval(startSection: course.startSection, endSection: course.endSection, on: relativeTo) {
                    if relativeTo >= interval.end { Text("已结束").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary) }
                    else if interval.contains(relativeTo) { Text("进行中").font(.system(size: 9, weight: .semibold)).foregroundStyle(AcademicPalette.accent) }
                }
            }
        }
        .padding(12)
        .background(AcademicPalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.04), lineWidth: 1))
        .contextMenu {
            Button("复制课程信息") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString([course.name, course.sectionText, course.timeText, course.location, course.teacher].filter { !$0.isEmpty }.joined(separator: " · "), forType: .string)
            }
        }
    }

    private var compactWeeks: String {
        guard let weeks = course.activeWeeks, !weeks.isEmpty else { return course.weeks }
        let sorted = Array(Set(weeks)).sorted()
        if sorted.count > 2 {
            let differences = zip(sorted.dropFirst(), sorted).map { $0 - $1 }
            if differences.allSatisfy({ $0 == 2 }), let first = sorted.first, let last = sorted.last {
                return "第 \(first)–\(last) 周（\(first.isMultiple(of: 2) ? "双" : "单")）"
            }
        }
        var ranges: [String] = []
        var start = sorted[0]
        var end = start
        for week in sorted.dropFirst() {
            if week == end + 1 { end = week }
            else { ranges.append(start == end ? "\(start)" : "\(start)–\(end)"); start = week; end = week }
        }
        ranges.append(start == end ? "\(start)" : "\(start)–\(end)")
        return "第 " + ranges.joined(separator: "、") + " 周"
    }
}

private struct GradeRow: View {
    let grade: GradeRecord

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(grade.courseName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(metadata)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(grade.score.isEmpty ? "-" : grade.score)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(scoreColor)
                Text("绩点 \(grade.gradePoint.isEmpty ? "-" : grade.gradePoint)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .background(AcademicPalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.04), lineWidth: 1))
    }

    private var metadata: String {
        var parts = [grade.category]
        if !grade.credit.isEmpty { parts.append("\(grade.credit)学分") }
        return parts.joined(separator: " · ")
    }

    private var scoreColor: Color {
        guard let numeric = Double(grade.score) else { return .primary }
        return numeric >= 60 ? .primary : .red
    }
}
