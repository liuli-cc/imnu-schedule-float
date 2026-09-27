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
    private var loginItemMenuItem: NSMenuItem?

    static func main() {
        let app = NSApplication.shared
        let delegate = ApplicationDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A login launch and a Finder launch may arrive together. Keep one ball.
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                && $0.launchDate.map { $0 < (NSRunningApplication.current.launchDate ?? .now) } == true }) {
            NSApp.terminate(nil)
            return
        }
        webSession.attach(scheduleStore: store)
        webSession.onNetworkRestored = { [weak self] in
            Task { @MainActor [weak self] in await self?.webSession.resume() }
        }
        let controller = FloatingPanelController(
            store: store,
            onAuthorize: { [weak self] in self?.showAuthorization() },
            onSync: { [weak self] in self?.syncNow() },
            onPortalHome: { [weak self] in self?.showPortalHome() },
            onQuit: { NSApp.terminate(nil) }
        )
        floatingController = controller
        controller.start()
        installStatusItem()
        store.startLocalClock()
        store.startAutomaticRefresh(with: webSession)
        installWakeRefresh()
        Task { [weak self] in
            guard let self else { return }
            await self.webSession.restorePersistedCookies()
            self.webSession.openPortal()
            // The ball is available immediately; restore the official session
            // quietly without opening an authorization window at every login.
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        floatingController?.showSchedule()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stopAutomaticRefresh()
        store.stopLocalClock()
        floatingController?.stop()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    private func showAuthorization() {
        if authorizationWindow == nil {
            authorizationWindow = AuthorizationWindowController(store: store, webSession: webSession)
        }
        authorizationWindow?.showAuthorization()
    }

    private func showPortalHome() {
        if authorizationWindow == nil {
            authorizationWindow = AuthorizationWindowController(store: store, webSession: webSession)
        }
        authorizationWindow?.showPortalHome()
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
        menu.addItem(withTitle: "打开教务系统首页", action: #selector(portalHomeMenuItem), keyEquivalent: "i")
        menu.addItem(.separator())
        let loginItem = menu.addItem(withTitle: "登录后自动显示悬浮球", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.state = LoginItemController.isEnabled ? .on : .off
        loginItemMenuItem = loginItem
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
                await self.webSession.resume()
            }
        }
    }

    @objc private func toggleLoginItem() {
        do {
            try LoginItemController.setEnabled(!LoginItemController.isEnabled)
            loginItemMenuItem?.state = LoginItemController.isEnabled ? .on : .off
        } catch {
            let alert = NSAlert()
            alert.messageText = "未能更改自动启动"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func toggleSchedule() { floatingController?.toggleSchedule() }
    @objc private func syncMenuItem() { syncNow() }
    @objc private func authorizeMenuItem() { showAuthorization() }
    @objc private func portalHomeMenuItem() { showPortalHome() }
    @objc private func quit() { NSApp.terminate(nil) }
}
