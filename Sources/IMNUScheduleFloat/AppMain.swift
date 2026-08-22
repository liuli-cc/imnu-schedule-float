import AppKit

@main
@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private let store = ScheduleStore()
    private let webSession = WebSession()
    private var authorizationWindow: AuthorizationWindowController?
    private var floatingController: FloatingPanelController?
    private var statusItem: NSStatusItem?
    private var wakeObserver: NSObjectProtocol?

    static func main() {
        let app = NSApplication.shared
        let delegate = ApplicationDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        webSession.attach(scheduleStore: store)
        webSession.onNetworkRestored = { [weak self] in
            self?.webSession.openPortal()
        }
        let controller = FloatingPanelController(
            store: store,
            onAuthorize: { [weak self] in self?.showAuthorization() },
            onSync: { [weak self] in self?.syncNow() },
            onQuit: { NSApp.terminate(nil) }
        )
        floatingController = controller
        controller.start()
        installStatusItem()
        store.startAutomaticRefresh(with: webSession)
        installWakeRefresh()
        Task { [weak self] in
            guard let self else { return }
            await self.webSession.restorePersistedCookies()
            self.webSession.openPortal()
            if case .sample = self.store.syncState {
                // A first-time user should see the official QR page right
                // away, rather than needing to discover the small floating
                // control before authorization can begin.
                self.showAuthorization()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stopAutomaticRefresh()
        floatingController?.stop()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    private func showAuthorization() {
        if authorizationWindow == nil {
            authorizationWindow = AuthorizationWindowController(store: store, webSession: webSession)
        }
        authorizationWindow?.show()
    }

    private func syncNow() {
        Task { await store.sync(using: webSession) }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "calendar.badge.clock", accessibilityDescription: "教务悬浮助手")
        let menu = NSMenu()
        menu.addItem(withTitle: "显示 / 收起课表", action: #selector(toggleSchedule), keyEquivalent: "")
        menu.addItem(withTitle: "立即同步", action: #selector(syncMenuItem), keyEquivalent: "r")
        menu.addItem(withTitle: "首次授权或重新登录", action: #selector(authorizeMenuItem), keyEquivalent: "l")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出教务悬浮助手", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        item.menu = menu
        statusItem = item
    }

    private func installWakeRefresh() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.store.sync(using: self.webSession)
            }
        }
    }

    @objc private func toggleSchedule() { floatingController?.toggleSchedule() }
    @objc private func syncMenuItem() { syncNow() }
    @objc private func authorizeMenuItem() { showAuthorization() }
    @objc private func quit() { NSApp.terminate(nil) }
}
