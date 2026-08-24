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
    private let panelSize = NSSize(width: 382, height: 545)
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
        ball = FloatingPanelController.makePanel(size: NSSize(width: 58, height: 58), keyable: true)
        schedulePanel = FloatingPanelController.makePanel(size: NSSize(width: 382, height: 545), keyable: true)
        super.init()

        ball.hasShadow = false
        ball.level = NSWindow.Level(rawValue: schedulePanel.level.rawValue + 1)
        ballControl.delegate = self
        ball.contentView = ballControl
        stateObservation = store.$syncState.sink { [weak ballControl] state in
            ballControl?.update(state: state)
        }
        schedulePanel.contentView = NSHostingView(rootView: SchedulePanelView(
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
        ball.orderFrontRegardless()
    }

    func stop() {
        cancelEdgeReturn()
        ball.orderOut(nil)
        schedulePanel.orderOut(nil)
        isScheduleShown = false
        if let panelMoveObserver {
            NotificationCenter.default.removeObserver(panelMoveObserver)
            self.panelMoveObserver = nil
        }
    }

    func toggleSchedule() {
        if hiddenSide != nil {
            revealBall(reason: .click) { [weak self] in self?.showSchedule() }
            return
        }
        isScheduleShown ? hideSchedule() : showSchedule()
    }

    func showSchedule() {
        guard !isScheduleShown, !isPanelAnimating,
              let screen = targetScreen(for: ball.frame) else { return }
        cancelEdgeReturn()
        let targetFrame = panelFrame(anchoredTo: ball.frame, on: screen)
        panelBallOffset = NSPoint(
            x: ball.frame.origin.x - targetFrame.origin.x,
            y: ball.frame.origin.y - targetFrame.origin.y
        )
        let startFrame = ball.frame
        isScheduleShown = true
        isPanelAnimating = true
        schedulePanel.alphaValue = shouldReduceMotion ? 1 : 0.08
        schedulePanel.setFrame(startFrame, display: false)
        schedulePanel.orderFrontRegardless()
        ball.orderFrontRegardless()
        schedulePanel.makeKey()
        ballControl.playOpenFeedback()
        animatePanel(to: targetFrame, alpha: 1, duration: 0.24) { [weak self] in
            guard let self else { return }
            self.isPanelAnimating = false
            self.ball.orderFrontRegardless()
            self.schedulePanel.makeKey()
        }
    }

    func hideSchedule() {
        guard isScheduleShown, !isPanelAnimating else { return }
        cancelEdgeReturn()
        isScheduleShown = false
        isPanelAnimating = true
        ball.orderFrontRegardless()
        ballControl.playCloseFeedback()
        animatePanel(to: ball.frame, alpha: shouldReduceMotion ? 1 : 0.04, duration: 0.20) { [weak self] in
            guard let self else { return }
            self.schedulePanel.orderOut(nil)
            self.ball.makeKey()
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
        guard let side = hiddenSide,
              let screen = targetScreen(for: ball.frame) else { return }
        cancelEdgeReturn()
        edgeAffinity = side
        ballMovedSinceEdgeReveal = false
        let visible = screen.visibleFrame
        let y = min(max(ball.frame.midY - ballSize.height / 2, visible.minY + 8), visible.maxY - ballSize.height - 8)
        let x = side == .left ? visible.minX + edgeInset : visible.maxX - ballSize.width - edgeInset
        let targetFrame = NSRect(x: x, y: y, width: ballSize.width, height: ballSize.height)
        ball.contentView = ballControl
        edgeHandle = nil
        hiddenSide = nil
        UserDefaults.standard.set(side.rawValue, forKey: savedEdgeKey)
        ballControl.playRevealFeedback()
        animateBall(to: targetFrame, duration: 0.18) { [weak self] in
            guard let self, self.hiddenSide == nil, self.edgeAffinity == side else { return }
            self.saveBallPosition()
            if reason == .hover { self.scheduleEdgeReturn() }
            completion?()
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
        let delta = NSSize(width: target.x - ball.frame.origin.x, height: target.y - ball.frame.origin.y)
        ball.setFrameOrigin(target)
        if movingPanel {
            schedulePanel.setFrameOrigin(NSPoint(
                x: schedulePanel.frame.origin.x + delta.width,
                y: schedulePanel.frame.origin.y + delta.height
            ))
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
        clampVisiblePair(on: screen)
        if let side = dockingSide(for: ball.frame, on: screen) {
            alignVisibleBall(to: side, on: screen, movingPanel: true)
            edgeAffinity = side
            ballMovedSinceEdgeReveal = false
            UserDefaults.standard.set(side.rawValue, forKey: savedEdgeKey)
        } else {
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
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.allowsKey = keyable
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        panel.isFloatingPanel = true
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

private struct FloatingBallView: View {
    @ObservedObject var store: ScheduleStore

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 9, y: 4)
            Image(systemName: icon)
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                .offset(x: 18, y: 18)
        }
        .frame(width: 58, height: 58)
        .accessibilityLabel("教务悬浮助手，\(store.syncState.message)")
        .accessibilityAddTraits(.isButton)
    }

    private var icon: String { store.todayCourses().isEmpty ? "calendar" : "calendar.badge.clock" }
    private var statusColor: Color {
        switch store.syncState {
        case .ready: return .green
        case .syncing, .offline: return .orange
        case .needsAuthorization, .failed: return .red
        case .sample: return .blue
        }
    }
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
    @AppStorage("schedulePanelSelection") private var selection = 0
    @AppStorage("gradeTermFilter") private var selectedGradeTerm = "all"
    @State private var selectedSemesterWeek = 1

    private let weekdayLabels = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("课表与成绩", selection: $selection) {
                Text("今天").tag(0)
                Text("本周").tag(1)
                Text("本学期").tag(2)
                Text("成绩查询").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Group {
                if selection == 0 {
                    todayView
                } else if selection == 1 {
                    currentWeekView
                } else if selection == 2 {
                    semesterView
                } else {
                    gradesView
                }
            }
            .id(selection)
            .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.985)))
            .animation(reduceMotion ? .linear(duration: 0.10) : .easeOut(duration: 0.18), value: selection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .frame(width: 382, height: 545)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.22), lineWidth: 1))
        .overlay(alignment: .top) {
            PanelDragHandle(
                onDragBegan: onPanelDragBegan,
                onDragged: onPanelDragged,
                onDragEnded: onPanelDragEnded
            )
                .frame(width: 150, height: 18)
                .padding(.top, 2)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "graduationcap.fill")
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 31, height: 31)
                .background(.blue.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text("教务悬浮助手")
                    .font(.headline)
                Text(store.syncState.message)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !store.profile.name.isEmpty || !store.profile.studentNumber.isEmpty {
                Button(action: onPortalHome) {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text([store.profile.name, store.profile.studentNumber].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                        Text("绩点 \(store.profile.gpa.isEmpty ? "-" : store.profile.gpa)")
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: 155, alignment: .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ResponsiveButtonStyle())
                .help("使用已授权会话打开教务系统首页")
            }
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(PanelIconButtonStyle())
                .help("收起")
        }
        .padding(16)
    }

    private var todayView: some View {
        let courses = store.todayCourses()
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("今天 · \(Date.now.formatted(.dateTime.month().day().weekday(.wide)))")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                if courses.isEmpty {
                    ContentUnavailableView("今天没有课程", systemImage: "sun.max", description: Text("可切换到“本学期”并选择教学周。"))
                        .padding(.top, 56)
                } else {
                    ForEach(courses) { CourseCard(course: $0) }
                        .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 14)
        }
    }

    @ViewBuilder
    private var currentWeekView: some View {
        if let week = store.currentWeek {
            weeklyList(courses: store.courses(forWeek: week), title: "本周 · 第 \(week) 周")
        } else {
            ContentUnavailableView(
                "当前不在教学周",
                systemImage: "calendar.badge.exclamationmark",
                description: Text("请切换到“本学期”选择第 1–\(store.maxWeek) 周查看。")
            )
        }
    }

    private var semesterView: some View {
        VStack(spacing: 8) {
            HStack {
                Text(store.currentTerm.isEmpty ? "本学期课表" : store.currentTerm)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
                Spacer()
                Text("第 \(selectedSemesterWeek) 周")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(1...max(store.maxWeek, 1), id: \.self) { week in
                        Button {
                            selectedSemesterWeek = week
                        } label: {
                            Text("\(week)")
                                .font(.caption.weight(.semibold))
                                .frame(minWidth: 25, minHeight: 24)
                                .background(
                                    selectedSemesterWeek == week ? Color.accentColor : Color.white.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                                .foregroundStyle(selectedSemesterWeek == week ? Color.white : Color.primary)
                                .animation(
                                    reduceMotion ? .linear(duration: 0.08) : .easeOut(duration: 0.15),
                                    value: selectedSemesterWeek
                                )
                        }
                        .buttonStyle(ResponsiveButtonStyle(compact: true))
                        .help("查看第 \(week) 周")
                    }
                }
                .padding(.horizontal, 16)
            }

            weeklyList(courses: store.courses(forWeek: selectedSemesterWeek), title: nil)
        }
        .onAppear {
            selectedSemesterWeek = min(max(store.currentWeek ?? 1, 1), max(store.maxWeek, 1))
        }
    }

    private var gradesView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12, pinnedViews: .sectionHeaders) {
                gradeTermMenu
                gradeSummary
                if store.grades.isEmpty {
                    ContentUnavailableView(
                        "暂无成绩缓存",
                        systemImage: "chart.bar.doc.horizontal",
                        description: Text("联网后点击“立即同步”读取官网全部成绩。")
                    )
                    .padding(.top, 36)
                } else {
                    ForEach(displayedGradeTerms, id: \.self) { term in
                        Section {
                            ForEach(store.grades(forTerm: term)) { grade in
                                GradeRow(grade: grade)
                            }
                        } header: {
                            Text(store.grades(forTerm: term).first?.termLabel ?? term)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .background(.regularMaterial)
                        }
                    }
                }
            }
            .padding(.bottom, 10)
        }
    }

    private var gradeTermMenu: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("成绩范围")
                    .font(.caption.weight(.semibold))
                Text(normalizedGradeTerm == "all" ? "已显示入学以来全部成绩" : "已按学期筛选")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button {
                    selectedGradeTerm = "all"
                } label: {
                    Label("全部学期", systemImage: selectedGradeTerm == "all" ? "checkmark" : "calendar")
                }
                Divider()
                Menu("按学期查看") {
                    ForEach(Array(store.gradeTerms.enumerated()), id: \.element) { index, term in
                        Button {
                            selectedGradeTerm = term
                        } label: {
                            Label(
                                index == 0 ? "最近学期  \(termLabel(term))" : termLabel(term),
                                systemImage: selectedGradeTerm == term ? "checkmark" : "calendar"
                            )
                        }
                    }
                }
                .disabled(store.gradeTerms.isEmpty)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "calendar")
                    Text(selectedGradeTermLabel)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.caption.weight(.semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 16)
    }

    private var gradeSummary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.profile.gpa.isEmpty ? "-" : store.profile.gpa)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("平均学分绩点")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(displayedGrades.count) 门课程")
                    .font(.subheadline.weight(.semibold))
                Text(gradeCacheStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
    }

    private var gradeCacheStatus: String {
        if case .offline = store.syncState { return "离线缓存" }
        guard let updatedAt = store.gradesUpdatedAt else { return "本机缓存" }
        return updatedAt.formatted(.relative(presentation: .named))
    }

    private var displayedGrades: [GradeRecord] {
        normalizedGradeTerm == "all" ? store.grades : store.grades(forTerm: normalizedGradeTerm)
    }

    private var displayedGradeTerms: [String] {
        normalizedGradeTerm == "all" ? store.gradeTerms : store.gradeTerms.filter { $0 == normalizedGradeTerm }
    }

    private var selectedGradeTermLabel: String {
        normalizedGradeTerm == "all" ? "全部学期" : termLabel(normalizedGradeTerm)
    }

    private var normalizedGradeTerm: String {
        selectedGradeTerm == "all" || store.gradeTerms.contains(selectedGradeTerm) ? selectedGradeTerm : "all"
    }

    private func termLabel(_ term: String) -> String {
        let parts = term.split(separator: "-")
        guard parts.count >= 3 else { return term }
        return "\(parts[0])-\(parts[1]) 第\(parts[2])学期"
    }

    private func weeklyList(courses: [Course], title: String?) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10, pinnedViews: .sectionHeaders) {
                if let title {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                }
                ForEach(1...7, id: \.self) { day in
                    let dayCourses = courses.filter { $0.weekday == day }.sorted { $0.startSection < $1.startSection }
                    if !dayCourses.isEmpty {
                        Section {
                            ForEach(dayCourses) { CourseCard(course: $0) }
                        } header: {
                            Text("星期\(weekdayLabels[day - 1])")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .background(.regularMaterial)
                        }
                    }
                }
                if courses.isEmpty {
                    ContentUnavailableView(
                        "这一周没有课程",
                        systemImage: "calendar",
                        description: Text("可在上方切换其他教学周。")
                    )
                    .padding(.top, 36)
                }
            }
            .padding(.bottom, 10)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("授权登录", action: onAuthorize)
            Button("立即同步", action: onSync)
                .buttonStyle(.borderedProminent)
            Spacer()
            Menu {
                Button("清除本机课表配置") { store.clearEndpoint() }
                Divider()
                Button("退出程序", action: onQuit)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .controlSize(.small)
        .padding(14)
    }

    private var statusColor: Color {
        switch store.syncState {
        case .ready: return .green
        case .syncing, .offline: return .orange
        case .needsAuthorization, .failed: return .red
        case .sample: return .secondary
        }
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

private struct InteractiveRowModifier: ViewModifier {
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered && !reduceMotion ? 1.008 : 1)
            .offset(y: isHovered && !reduceMotion ? -1 : 0)
            .shadow(color: .black.opacity(isHovered ? 0.10 : 0), radius: 5, y: 2)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? .linear(duration: 0.08) : .easeOut(duration: 0.16), value: isHovered)
    }
}

private struct CourseCard: View {
    let course: Course
    private let colors: [Color] = [.blue, .purple, .orange, .green, .pink, .teal]

    var body: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 3)
                .fill(colors[course.colorIndex % colors.count])
                .frame(width: 5)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(course.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(course.sectionText)
                        if !course.timeText.isEmpty {
                            Text(course.timeText)
                        }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Text([course.teacher, course.location].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !course.weeks.isEmpty { Text(course.weeks).font(.caption2).foregroundStyle(.tertiary) }
            }
        }
        .padding(11)
        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .modifier(InteractiveRowModifier())
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
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .modifier(InteractiveRowModifier())
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
