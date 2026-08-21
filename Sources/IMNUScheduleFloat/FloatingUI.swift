import AppKit
import Combine
import SwiftUI

@MainActor
final class FloatingPanelController: NSObject, FloatingBallControlDelegate {
    private let store: ScheduleStore
    private let onAuthorize: () -> Void
    private let onSync: () -> Void
    private let onQuit: () -> Void
    private let ball: NSPanel
    private let schedulePanel: NSPanel
    private let ballControl = FloatingBallControl(frame: NSRect(x: 0, y: 0, width: 58, height: 58))
    private var edgeHandle: FloatingEdgeHandle?
    private var stateObservation: AnyCancellable?
    private var ballOrigin = NSPoint.zero
    private var pointerOrigin = NSPoint.zero
    private var isScheduleShown = false
    private var hiddenSide: FloatingEdgeHandle.Side?
    private let savedXKey = "floatingBallX"
    private let savedYKey = "floatingBallY"
    private let savedEdgeKey = "floatingBallEdge"
    private let ballSize = NSSize(width: 58, height: 58)
    private let edgeHandleSize = NSSize(width: 12, height: 48)

    init(store: ScheduleStore, onAuthorize: @escaping () -> Void, onSync: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.store = store
        self.onAuthorize = onAuthorize
        self.onSync = onSync
        self.onQuit = onQuit
        ball = FloatingPanelController.makePanel(size: NSSize(width: 58, height: 58), keyable: true)
        schedulePanel = FloatingPanelController.makePanel(size: NSSize(width: 382, height: 545), keyable: true)
        super.init()

        ball.hasShadow = false
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
            onQuit: onQuit
        ))
    }

    func start() {
        positionInitially()
        ball.orderFrontRegardless()
    }

    func stop() {
        ball.orderOut(nil)
        schedulePanel.orderOut(nil)
        isScheduleShown = false
    }

    func toggleSchedule() {
        if hiddenSide != nil { revealBall(); return }
        isScheduleShown ? hideSchedule() : showSchedule()
    }

    func showSchedule() {
        let screen = ball.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let panelSize = schedulePanel.frame.size
        var x = ball.frame.minX - panelSize.width + ball.frame.width
        if x < screen.visibleFrame.minX + 8 { x = ball.frame.maxX + 8 }
        var y = ball.frame.midY - panelSize.height / 2
        y = min(max(y, screen.visibleFrame.minY + 8), screen.visibleFrame.maxY - panelSize.height - 8)
        schedulePanel.setFrameOrigin(NSPoint(x: x, y: y))
        schedulePanel.orderFrontRegardless()
        isScheduleShown = true
    }

    func hideSchedule() {
        schedulePanel.orderOut(nil)
        isScheduleShown = false
    }

    func floatingBallTapped() {
        toggleSchedule()
    }

    func floatingBallDragBegan(at screenPoint: NSPoint) {
        pointerOrigin = screenPoint
        ballOrigin = ball.frame.origin
    }

    func floatingBallDragged(to screenPoint: NSPoint) {
        let delta = NSSize(width: screenPoint.x - pointerOrigin.x, height: screenPoint.y - pointerOrigin.y)
        ball.setFrameOrigin(NSPoint(x: ballOrigin.x + delta.width, y: ballOrigin.y + delta.height))
        if isScheduleShown { showSchedule() }
    }

    func floatingBallDragEnded() {
        finishDrag()
    }

    func floatingEdgeHandleEntered() {
        revealBall()
    }

    private func positionInitially() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: savedXKey) != nil, defaults.object(forKey: savedYKey) != nil {
            ball.setFrameOrigin(NSPoint(x: defaults.double(forKey: savedXKey), y: defaults.double(forKey: savedYKey)))
            if let raw = defaults.string(forKey: savedEdgeKey), let side = FloatingEdgeHandle.Side(rawValue: raw) {
                attachBall(to: side)
            }
            return
        }
        ball.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - ball.frame.width - 22, y: screen.visibleFrame.midY))
    }

    private func finishDrag() {
        guard let screen = ball.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 8
        var origin = ball.frame.origin
        origin.x = min(max(origin.x, visible.minX + margin), visible.maxX - ball.frame.width - margin)
        origin.y = min(max(origin.y, visible.minY + margin), visible.maxY - ball.frame.height - margin)
        ball.setFrameOrigin(origin)
        let distanceToLeft = origin.x - visible.minX
        let distanceToRight = visible.maxX - (origin.x + ball.frame.width)
        if distanceToLeft < 28 {
            attachBall(to: .left)
        } else if distanceToRight < 28 {
            attachBall(to: .right)
        } else {
            UserDefaults.standard.removeObject(forKey: savedEdgeKey)
            saveBallPosition()
        }
    }

    private func saveBallPosition() {
        UserDefaults.standard.set(ball.frame.origin.x, forKey: savedXKey)
        UserDefaults.standard.set(ball.frame.origin.y, forKey: savedYKey)
    }

    private func attachBall(to side: FloatingEdgeHandle.Side) {
        guard let screen = ball.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        hideSchedule()
        let handle = FloatingEdgeHandle(side: side)
        handle.delegate = self
        edgeHandle = handle
        hiddenSide = side
        let visible = screen.visibleFrame
        let y = min(max(ball.frame.midY - edgeHandleSize.height / 2, visible.minY + 8), visible.maxY - edgeHandleSize.height - 8)
        let x = side == .left ? visible.minX : visible.maxX - edgeHandleSize.width
        ball.contentView = handle
        ball.setFrame(NSRect(x: x, y: y, width: edgeHandleSize.width, height: edgeHandleSize.height), display: true)
        UserDefaults.standard.set(side.rawValue, forKey: savedEdgeKey)
        saveBallPosition()
    }

    private func revealBall() {
        guard let side = hiddenSide,
              let screen = ball.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let y = min(max(ball.frame.midY - ballSize.height / 2, visible.minY + 8), visible.maxY - ballSize.height - 8)
        let x = side == .left ? visible.minX + 8 : visible.maxX - ballSize.width - 8
        ball.contentView = ballControl
        ball.setFrame(NSRect(x: x, y: y, width: ballSize.width, height: ballSize.height), display: true)
        edgeHandle = nil
        hiddenSide = nil
        UserDefaults.standard.removeObject(forKey: savedEdgeKey)
        saveBallPosition()
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
        case .syncing: return .orange
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
    let onQuit: () -> Void
    @State private var selection = 0
    @State private var selectedSemesterWeek = 1

    private let weekdayLabels = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("视图", selection: $selection) {
                Text("今天").tag(0)
                Text("本周").tag(1)
                Text("本学期").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Group {
                if selection == 0 {
                    todayView
                } else if selection == 1 {
                    currentWeekView
                } else {
                    semesterView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .frame(width: 382, height: 545)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.22), lineWidth: 1))
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
                VStack(alignment: .trailing, spacing: 3) {
                    Text([store.profile.name, store.profile.studentNumber].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text("绩点 \(store.profile.gpa.isEmpty ? "—" : store.profile.gpa)")
                    }
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .frame(maxWidth: 155, alignment: .trailing)
            }
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
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
                        }
                        .buttonStyle(.plain)
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
        case .syncing: return .orange
        case .needsAuthorization, .failed: return .red
        case .sample: return .secondary
        }
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
                    Text(course.sectionText).font(.caption.weight(.medium)).foregroundStyle(.secondary)
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
    }
}
