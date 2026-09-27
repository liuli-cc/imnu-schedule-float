import AppKit
import Combine
import Network
import SwiftUI
import WebKit

@MainActor
final class WebSession: NSObject, ObservableObject {
    let webView: WKWebView
    @Published var pageStatus = "尚未打开授权页面"
    @Published private(set) var isLoggedIn = false
    @Published private(set) var isNetworkAvailable = true
    var onNetworkRestored: (() -> Void)?
    private weak var scheduleStore: ScheduleStore?
    private var hasTriggeredAuthenticatedSync = false
    private let networkMonitor = NWPathMonitor()
    private var cookieSaveTask: Task<Void, Never>?
    private var isRestoringCookies = false
    private var isClearingLogin = false
    private var sessionGeneration = 0
    private var persistenceRevision = 0
    @Published private(set) var sessionIsSavedSecurely = false
    @Published private(set) var isRequestingSessionPermission = false
    @Published private(set) var sessionPermissionStatus = ""

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.configuration.websiteDataStore.httpCookieStore.add(self)
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let available = path.status == .satisfied
                let restored = !self.isNetworkAvailable && available
                self.isNetworkAvailable = available
                if !available {
                    self.scheduleStore?.markOffline()
                    self.pageStatus = "网络不可用，已保留本机登录与课表缓存"
                } else if restored {
                    self.pageStatus = "网络已恢复，正在重新连接教务系统…"
                    self.onNetworkRestored?()
                }
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "IMNUScheduleFloat.Network"))
    }

    deinit {
        networkMonitor.cancel()
        cookieSaveTask?.cancel()
    }

    func attach(scheduleStore: ScheduleStore) {
        self.scheduleStore = scheduleStore
    }

    func openPortal() {
        guard let url = URL(string: "https://jwxt.imnu.edu.cn") else { return }
        guard isNetworkAvailable else {
            pageStatus = "网络不可用，正在使用本机课表缓存"
            return
        }
        pageStatus = "正在打开教务系统…"
        webView.load(URLRequest(url: url))
    }

    /// Wake/reconnect can reuse the loaded authenticated page without throwing
    /// away its state. A login page remains available for explicit authorization.
    func resume() async {
        guard isNetworkAvailable else { return }
        if webView.url?.host == "jwxt.imnu.edu.cn", isLoggedIn, !webView.isLoading {
            await scheduleStore?.sync(using: self)
        } else if !webView.isLoading {
            hasTriggeredAuthenticatedSync = false
            openPortal()
        }
    }

    func cookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    /// Reads the fixed desktop timetable page directly. The school homepage
    /// derives its week from today's date and returns an empty timetable during
    /// vacations; this route instead asks for the selected semester once and
    /// returns every scheduled teaching block.
    func fetchPortalSnapshot() async throws -> PortalSnapshot {
        let generation = sessionGeneration
        guard isNetworkAvailable else { throw PortalError.networkUnavailable }
        if webView.url == nil { openPortal() }
        let deadline = Date().addingTimeInterval(25)
        while webView.isLoading, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !webView.isLoading else { throw PortalError.remote("连接超时，请稍后重试") }
        guard webView.url?.host == "jwxt.imnu.edu.cn" else {
            markAuthorizationRequired()
            throw PortalError.authorizationRequired
        }
        let script = #"""
        (async () => {
          const timedFetch = async (url, options = {}) => {
            const controller = new AbortController();
            const timeout = setTimeout(() => controller.abort(), 20000);
            try { return await fetch(url, {...options, signal: controller.signal}); }
            catch (error) {
              if (error.name === 'AbortError') throw new Error('NETWORK_TIMED_OUT');
              throw error;
            } finally { clearTimeout(timeout); }
          };
          const isLogin = response => response &&
            ([401,403].includes(response.status) || /\/login|caslogin|\/cas\//i.test(response.url));
          const optionalJSON = async response => response && response.ok && !isLogin(response)
            ? await response.json().catch(() => null) : null;
          const text = value => {
            if (value == null) return '';
            if (Array.isArray(value)) return value.map(text).filter(Boolean).join('、');
            if (typeof value === 'object') return text(value.xm || value.name || value.jsmc || value.tmc || '');
            const output = String(value).trim();
            return output === '-' ? '' : output;
          };
          const plain = value => {
            const raw = text(value);
            if (!raw.includes('<') && !raw.includes('&lt;')) return raw;
            const holder = document.createElement('div');
            holder.innerHTML = raw;
            return (holder.textContent || '').replace(/\s+/g, ' ').trim();
          };
          const weekday = value => {
            const raw = text(value);
            const names = {'星期一':1,'星期二':2,'星期三':3,'星期四':4,'星期五':5,'星期六':6,'星期日':7,'周一':1,'周二':2,'周三':3,'周四':4,'周五':5,'周六':6,'周日':7};
            return names[raw] || Number.parseInt(raw, 10) || 0;
          };
          const pageResponse = await timedFetch('/admin/xsd/pkgl/xskb/queryKbForXsd', {credentials:'include'});
          if (isLogin(pageResponse)) throw new Error('AUTH_REQUIRED');
          if (!pageResponse.ok) throw new Error('课表页面暂时不可用（HTTP ' + pageResponse.status + '）');
          const pageHTML = await pageResponse.text();
          const page = new DOMParser().parseFromString(pageHTML, 'text/html');
          const field = id => page.querySelector(`#${id}`)?.getAttribute('value') || page.querySelector(`#${id}`)?.textContent?.trim() || '';
          const term = field('xnxq');
          const xhid = field('xhid');
          const campus = field('xqdm');
          if (!term) {
            if (page.querySelector('input[type="password"], #loginForm, .login-form') || /扫码登录|统一身份认证/.test(page.title)) throw new Error('AUTH_REQUIRED');
            throw new Error('课表页面缺少学期信息，请稍后重试');
          }

          const form = new URLSearchParams({xnxq:term, xhid, xqdm:campus, zdzc:'', zxzc:'', xskbxslx:'0'});
          const gradeCategories = [{value:'0', label:'主修'}, {value:'1', label:'辅修'}, {value:'9', label:'微专业'}];
          const gradeRequests = gradeCategories.map(item => timedFetch(
            '/admin/xsd/xsdcjcx/xsdQueryXscjList?fxbz=' + item.value + '&gridtype=jqgrid&_search=false&page.size=500&page.pn=1&sort=xnxq&order=desc&startXnxq=001&endXnxq=001',
            {credentials:'include', headers:{'X-Requested-With':'XMLHttpRequest', 'Accept':'application/json, text/javascript, */*; q=0.01'}}
          ).catch(() => null));
          const [courseResponse, profileResponse, gpaResponse, weeksResponse, currentWeekResponse, gradeResponses] = await Promise.all([
            timedFetch('/admin/xsd/pkgl/xskb/sdpkkbList', {method:'POST', credentials:'include', headers:{'Content-Type':'application/x-www-form-urlencoded;charset=UTF-8'}, body:form}),
            timedFetch('/admin/xsd/xskp/xskp?xhid=' + encodeURIComponent(xhid), {credentials:'include'}).catch(() => null),
            timedFetch('/admin/xsd/xsdzgcjcx/getXspjxfjd', {credentials:'include'}).catch(() => null),
            timedFetch('/admin/getCurrentPkZc', {credentials:'include'}).catch(() => null),
            timedFetch('/admin/api/getXlzc', {credentials:'include'}).catch(() => null),
            Promise.all(gradeRequests)
          ]);
          if (isLogin(courseResponse)) throw new Error('AUTH_REQUIRED');
          if (!courseResponse.ok) throw new Error('课表请求暂时失败（HTTP ' + courseResponse.status + '）');
          const [courseJSON, profileJSON, gpaJSON, weeksJSON, currentWeekJSON, gradeJSONs] = await Promise.all([
            courseResponse.json(), optionalJSON(profileResponse), optionalJSON(gpaResponse),
            optionalJSON(weeksResponse), optionalJSON(currentWeekResponse),
            Promise.all(gradeResponses.map(optionalJSON))
          ]);
          if (courseJSON.ret !== 0) throw new Error(courseJSON.msg || 'COURSE_RESPONSE');
          if (!Array.isArray(courseJSON.data)) throw new Error('课表数据格式已变化，请稍后重试');
          const rawProfile = profileJSON && profileJSON.data || {};
          const identityRow = Array.from(document.querySelectorAll('.header_left li')).find(node => /姓名\s*\/\s*学号/.test(node.textContent || ''));
          const identity = text(identityRow?.querySelector('.value')?.textContent).split('/');
          const profileName = text(rawProfile.xm) || text(identity[0]);
          const profileNumber = text(rawProfile.xh) || text(identity[1]);
          const profileGPA = text(gpaJSON && gpaJSON.data) || text(document.querySelector('#pjxfjd')?.textContent);
          const rawCourses = Array.isArray(courseJSON.data) ? courseJSON.data : [];
          const courses = rawCourses.map(item => {
            const building = plain(item.jxlmc);
            const room = plain(item.croommc || item.croombh);
            return {
              name: plain(item.kcmc),
              teacher: plain(item.tmc || item.jsmc || item.teacher || item.jsxq),
              location: Array.from(new Set([building, room].filter(Boolean))).join(' · '),
              weekday: weekday(item.xingqi || item.xq),
              section: text(item.djc || item.djs || item.jc),
              weeks: text(item.zcstr || item.zc)
            };
          }).filter(item => item.name && item.weekday > 0);
          const allWeeks = Array.isArray(weeksJSON?.data) ? weeksJSON.data.map(Number).filter(value => Number.isInteger(value) && value > 0 && value <= 60) : [];
          const weekValue = currentWeekJSON?.data?.xlzc ?? currentWeekJSON?.data?.zc;
          const currentWeekResolved = weekValue != null && Number.isFinite(Number(weekValue));
          const currentWeek = currentWeekResolved && Number(weekValue) > 0 ? Number(weekValue) : null;
          const successfulGradeResponses = gradeJSONs
            .map((payload, categoryIndex) => ({payload, categoryIndex}))
            .filter(item => item.payload && item.payload.ret === 0 && Array.isArray(item.payload.results));
          const grades = successfulGradeResponses.length ? successfulGradeResponses.flatMap(({payload, categoryIndex}) => {
            const records = Array.isArray(payload.results) ? payload.results : [];
            const category = gradeCategories[categoryIndex]?.label || '主修';
            return records.map((item, index) => ({
              id: category + '|' + (text(item.id) || [text(item.xnxq), text(item.kcbh), index].join('|')),
              term: text(item.xnxq),
              courseName: plain(item.kcmc).replace(/^\[[^\]]+\]\s*/, ''),
              score: text(item.zhcj ?? item.yscj),
              credit: text(item.xf),
              gradePoint: text(item.jd),
              courseNature: text(item.kcxzmc || item.kcxz),
              examType: text(item.ksxs),
              category
            })).filter(item => item.courseName);
          }) : null;
          const gradeCategoriesSynced = successfulGradeResponses.map(({categoryIndex}) => gradeCategories[categoryIndex].label);
          const syncWarnings = [];
          if (gradeCategoriesSynced.length !== gradeCategories.length) syncWarnings.push('部分成绩暂未更新，保留已有缓存');
          if (!currentWeekResolved) syncWarnings.push('本次未获取官方教学周');
          if (!profileJSON || !gpaJSON) syncWarnings.push('部分个人信息暂未更新，保留已有缓存');
          return JSON.stringify({
            term,
            maxWeek: allWeeks.length ? Math.max(...allWeeks) : 19,
            currentWeek,
            currentWeekResolved,
            profile: {
              studentNumber: profileNumber,
              name: profileName,
              gpa: profileGPA
            },
            courses,
            grades,
            gradeCategoriesSynced,
            syncWarnings
          });
        })().catch(error => JSON.stringify({__error:String(error && error.message || error)}))
        """#
        let result = try await webView.callAsyncJavaScript(
            "return await " + script,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        guard generation == sessionGeneration else { throw PortalError.authorizationRequired }
        guard let json = result as? String,
              let data = json.data(using: .utf8) else { throw PortalError.invalidResponse }
        if let failure = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = failure["__error"] as? String {
            if message.contains("AUTH_REQUIRED") {
                markAuthorizationRequired()
                throw PortalError.authorizationRequired
            }
            if PortalError.isNetworkMessage(message) { throw PortalError.networkUnavailable }
            throw PortalError.remote(message)
        }
        do {
            let snapshot = try JSONDecoder().decode(PortalSnapshot.self, from: data)
            isLoggedIn = true
            await persistCookies()
            return snapshot
        }
        catch { throw PortalError.invalidResponse }
    }

    func restorePersistedCookies() async {
        guard !isRestoringCookies else { return }
        isRestoringCookies = true
        defer { isRestoringCookies = false }
        let generation = sessionGeneration
        let restored = await CookieVault.load()
        guard generation == sessionGeneration, !isClearingLogin else { return }
        let existing = await cookies()
        func key(_ cookie: HTTPCookie) -> String { [cookie.domain, cookie.path, cookie.name].joined(separator: "|") }
        let liveKeys = Set(existing.filter { $0.expiresDate.map { $0 > Date() } ?? true }.map(key))
        for cookie in restored.cookies where !liveKeys.contains(key(cookie)) {
            await withCheckedContinuation { continuation in
                webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { continuation.resume() }
            }
        }
        sessionIsSavedSecurely = restored.isSavedSecurely
    }

    func persistCookies() async {
        guard isLoggedIn, !isRestoringCookies, !isClearingLogin, !isRequestingSessionPermission else { return }
        let current = await cookies()
        guard !isClearingLogin, !Task.isCancelled else { return }
        let generation = sessionGeneration
        let revision = persistenceRevision
        let saved = await CookieVault.save(current)
        guard generation == sessionGeneration, revision == persistenceRevision,
              !isClearingLogin, !isRequestingSessionPermission else { return }
        sessionIsSavedSecurely = saved
    }

    func requestSecureSessionPersistence() async {
        guard !isRequestingSessionPermission else { return }
        guard isLoggedIn, !isClearingLogin else {
            sessionPermissionStatus = "请先完成官网登录，再保存登录会话。"
            return
        }
        isRequestingSessionPermission = true
        persistenceRevision += 1
        defer { isRequestingSessionPermission = false }
        cookieSaveTask?.cancel()
        let generation = sessionGeneration
        let current = await cookies()
        guard generation == sessionGeneration, isLoggedIn, !isClearingLogin else { return }
        guard current.contains(where: { CookieVault.isSchoolDomain($0.domain) && ($0.expiresDate.map { $0 > Date() } ?? true) }) else {
            sessionIsSavedSecurely = false
            sessionPermissionStatus = "暂未获取到官网会话，请完成登录后重试。"
            return
        }
        sessionPermissionStatus = "若系统要求“登录钥匙串”密码，通常是解锁 Mac 的登录密码。"
        let saved = await CookieVault.requestPermissionAndSave(current)
        guard generation == sessionGeneration, isLoggedIn, !isClearingLogin else { return }
        sessionIsSavedSecurely = saved
        sessionPermissionStatus = saved
            ? "已保存。授权仍有效时，重启后可直接复用；官网过期后仍需重新登录。"
            : (CredentialStore.isSessionStorageUnavailable
                ? "钥匙串暂不可用，请重启助手后再试；当前继续使用浏览器会话。"
                : "本次未获钥匙串访问许可，继续使用浏览器会话；可再次点击重试。")
    }

    func clearLogin() async {
        sessionGeneration += 1
        isClearingLogin = true
        defer { isClearingLogin = false }
        cookieSaveTask?.cancel()
        webView.stopLoading()
        isLoggedIn = false
        hasTriggeredAuthenticatedSync = false
        scheduleStore?.markNeedsAuthorization(invalidatePendingSync: true)
        let store = webView.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            store.removeData(ofTypes: types, modifiedSince: .distantPast) { continuation.resume() }
        }
        await CookieVault.clear()
        sessionIsSavedSecurely = false
        pageStatus = "已清除内嵌浏览器登录状态"
    }

    private func markAuthorizationRequired() {
        isLoggedIn = false
        hasTriggeredAuthenticatedSync = false
        pageStatus = "官网会话已失效；本机课表与成绩仍可查看，重新授权后恢复同步"
    }

}

extension WebSession: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let path = webView.url?.path.lowercased() ?? ""
            let isAuthorizationPage = path.contains("/login") || path.contains("caslogin") || path.contains("/cas/")
            let isPortalHome = !isAuthorizationPage && webView.url?.host == "jwxt.imnu.edu.cn" && (path == "/admin" || path.hasPrefix("/admin/"))
            self.isLoggedIn = isPortalHome
            if !isPortalHome { self.hasTriggeredAuthenticatedSync = false }
            self.pageStatus = isPortalHome
                ? "官网登录已恢复，正在读取本学期课表…"
                : (webView.url?.host.map { "已打开 \($0)，可在官网登录" } ?? "页面已加载")
            if isAuthorizationPage {
                self.markAuthorizationRequired()
                self.scheduleStore?.markNeedsAuthorization()
            }
            if webView.url?.host.map(CookieVault.isSchoolDomain) == true {
                Task { @MainActor [weak self] in await self?.persistCookies() }
            }
            let shouldRetryAfterOffline: Bool
            if case .offline = self.scheduleStore?.syncState {
                shouldRetryAfterOffline = true
            } else {
                shouldRetryAfterOffline = false
            }
            if isPortalHome, (!self.hasTriggeredAuthenticatedSync || shouldRetryAfterOffline) {
                self.hasTriggeredAuthenticatedSync = true
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.scheduleStore?.sync(using: self)
                }
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in self?.handleLoadFailure(error) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in self?.handleLoadFailure(error) }
    }
}

extension WebSession: WKHTTPCookieStoreObserver {
    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in
            guard let self, !self.isRestoringCookies, !self.isClearingLogin else { return }
            self.cookieSaveTask?.cancel()
            self.cookieSaveTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                await self?.persistCookies()
            }
        }
    }
}

private extension WebSession {
    func handleLoadFailure(_ error: Error) {
        if (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled { return }
        if PortalError.isNetworkError(error) {
            scheduleStore?.markOffline()
            pageStatus = "网络不可用，已保留本机登录与课表缓存"
        } else {
            pageStatus = "页面加载失败：\(error.localizedDescription)"
        }
    }
}

enum PortalError: LocalizedError {
    case authorizationRequired
    case networkUnavailable
    case invalidResponse
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .authorizationRequired: return "教务登录已失效，请重新扫码授权"
        case .networkUnavailable: return "网络不可用，正在使用已缓存的课表"
        case .invalidResponse: return "教务系统返回了无法识别的数据"
        case .remote(let message): return "读取教务数据失败：\(message)"
        }
    }

    static func isNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                    NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
                    NSURLErrorDNSLookupFailed, NSURLErrorTimedOut].contains(nsError.code)
        }
        return isNetworkMessage(error.localizedDescription)
    }

    static func isNetworkMessage(_ message: String) -> Bool {
        let value = message.lowercased()
        return [
            "failed to fetch", "networkerror", "network connection was lost",
            "not connected to the internet", "internet connection appears to be offline",
            "could not connect", "timed out", "network_timed_out", "offline"
        ].contains { value.contains($0) }
    }
}

struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

@MainActor
final class AuthorizationWindowController: NSWindowController {
    private let store: ScheduleStore
    private let webSession: WebSession
    private var syncObservation: AnyCancellable?
    private let navigation = PortalWindowNavigation()

    init(store: ScheduleStore, webSession: WebSession) {
        self.store = store
        self.webSession = webSession
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "教务悬浮助手"
        window.minSize = NSSize(width: 700, height: 520)
        super.init(window: window)
        window.center()
        window.contentView = NSHostingView(rootView: AuthorizationView(store: store, webSession: webSession, navigation: navigation))
        syncObservation = store.$syncState.dropFirst().sink { [weak self, weak window] state in
            if case .ready = state, self?.navigation.destination == .authorization,
               self?.webSession.sessionIsSavedSecurely == true,
               self?.webSession.isRequestingSessionPermission == false { window?.orderOut(nil) }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("AuthorizationWindowController must be created programmatically")
    }

    func showAuthorization() {
        navigation.destination = webSession.isLoggedIn ? .sessionManagement : .authorization
        window?.title = webSession.isLoggedIn ? "教务悬浮助手 · 登录会话管理" : "教务悬浮助手 · 授权登录"
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if webSession.webView.url == nil || !webSession.isLoggedIn { webSession.openPortal() }
    }

    func showPortalHome() {
        navigation.destination = .portalHome
        window?.title = "教务悬浮助手 · 教务系统首页"
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        webSession.openPortal()
    }
}

@MainActor
private final class PortalWindowNavigation: ObservableObject {
    enum Destination { case authorization, portalHome, sessionManagement }
    @Published var destination: Destination = .authorization
}

private struct AuthorizationView: View {
    @ObservedObject var store: ScheduleStore
    @ObservedObject var webSession: WebSession
    @ObservedObject var navigation: PortalWindowNavigation

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.title2)
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 4) {
                    Text(navigation.destination == .portalHome ? "教务系统首页" : (navigation.destination == .sessionManagement ? "登录会话管理" : "授权后自动记住官网会话"))
                        .font(.headline)
                    Text(headerDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(navigation.destination == .portalHome ? "重新打开首页" : "重新打开官网") {
                    webSession.openPortal()
                }
            }
            .padding(16)

            Divider()

            WebViewContainer(webView: webSession.webView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
              HStack {
                Text(webSession.pageStatus)
                Spacer()
                if case .ready = store.syncState {
                    Label("课表已自动同步", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.purple)
                } else if case .offline = store.syncState {
                    Label("离线模式：正在使用本机课表", systemImage: "wifi.slash")
                        .foregroundStyle(.orange)
                } else if webSession.isLoggedIn {
                    Label("官网已登录，正在读取课表", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                } else {
                    Label("等待扫码授权", systemImage: "qrcode")
                        .foregroundStyle(.secondary)
                }
              }
              HStack(spacing: 12) {
                Label(webSession.sessionIsSavedSecurely ? "会话已存钥匙串" : "使用浏览器会话", systemImage: webSession.sessionIsSavedSecurely ? "lock.shield" : "globe")
                Button(webSession.isRequestingSessionPermission ? "等待系统授权…" : "允许钥匙串保存登录") {
                    Task { await webSession.requestSecureSessionPersistence() }
                }
                .disabled(!webSession.isLoggedIn || webSession.isRequestingSessionPermission)
                .help("由 macOS 确认钥匙串访问权限；若要求密码，通常是解锁 Mac 的登录密码。会话有效时可在重启后复用。")
                Text(webSession.sessionPermissionStatus.isEmpty
                    ? (webSession.isLoggedIn ? "会话有效时，重启后无需重复登录。" : "完成官网登录后可保存会话。")
                    : webSession.sessionPermissionStatus)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
              }
            }
            .font(.caption)
            .padding(14)
        }
        .frame(minWidth: 700, minHeight: 520)
    }

    private var headerDescription: String {
        if navigation.destination == .portalHome {
            return "此页直接使用悬浮助手已保存的官方登录会话。授权仍有效时会直接显示教务系统首页，不需要再次扫码。"
        }
        return "请按官网页面完成登录。助手会自动保存可复用的授权会话，并同步课表、成绩和个人信息；仅在学校使会话失效后需要重新授权。"
    }
}
