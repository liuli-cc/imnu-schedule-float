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

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
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

    deinit { networkMonitor.cancel() }

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
        guard isNetworkAvailable else { throw PortalError.networkUnavailable }
        guard webView.url?.host == "jwxt.imnu.edu.cn" else { throw PortalError.authorizationRequired }
        let script = #"""
        (async () => {
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
          const pageResponse = await fetch('/admin/xsd/pkgl/xskb/queryKbForXsd', {credentials:'include'});
          if (!pageResponse.ok || /\/login|caslogin/.test(pageResponse.url)) throw new Error('AUTH_REQUIRED');
          const pageHTML = await pageResponse.text();
          const page = new DOMParser().parseFromString(pageHTML, 'text/html');
          const field = id => page.querySelector(`#${id}`)?.getAttribute('value') || page.querySelector(`#${id}`)?.textContent?.trim() || '';
          const term = field('xnxq');
          const xhid = field('xhid');
          const campus = field('xqdm');
          if (!term) throw new Error('AUTH_REQUIRED');

          const form = new URLSearchParams({xnxq:term, xhid, xqdm:campus, zdzc:'', zxzc:'', xskbxslx:'0'});
          const gradeCategories = [{value:'0', label:'主修'}, {value:'1', label:'辅修'}, {value:'9', label:'微专业'}];
          const gradeRequests = gradeCategories.map(item => fetch(
            '/admin/xsd/xsdcjcx/xsdQueryXscjList?fxbz=' + item.value + '&gridtype=jqgrid&_search=false&page.size=500&page.pn=1&sort=xnxq&order=desc&startXnxq=001&endXnxq=001',
            {credentials:'include', headers:{'X-Requested-With':'XMLHttpRequest', 'Accept':'application/json, text/javascript, */*; q=0.01'}}
          ));
          const [courseResponse, profileResponse, gpaResponse, weeksResponse, currentWeekResponse, gradeResponses] = await Promise.all([
            fetch('/admin/xsd/pkgl/xskb/sdpkkbList', {method:'POST', credentials:'include', headers:{'Content-Type':'application/x-www-form-urlencoded;charset=UTF-8'}, body:form}),
            fetch('/admin/xsd/xskp/xskp?xhid=' + encodeURIComponent(xhid), {credentials:'include'}),
            fetch('/admin/xsd/xsdzgcjcx/getXspjxfjd', {credentials:'include'}),
            fetch('/admin/getCurrentPkZc', {credentials:'include'}),
            fetch('/admin/api/getXlzc', {credentials:'include'}),
            Promise.all(gradeRequests)
          ]);
          if (!courseResponse.ok) throw new Error('COURSE_HTTP_' + courseResponse.status);
          if (gradeResponses.some(response => /\/login|caslogin/.test(response.url))) throw new Error('AUTH_REQUIRED');
          const [courseJSON, profileJSON, gpaJSON, weeksJSON, currentWeekJSON, gradeJSONs] = await Promise.all([
            courseResponse.json(), profileResponse.json().catch(() => ({})), gpaResponse.json().catch(() => ({})),
            weeksResponse.json().catch(() => ({})), currentWeekResponse.json().catch(() => ({})),
            Promise.all(gradeResponses.map(response => response.json().catch(() => null)))
          ]);
          if (courseJSON.ret !== 0) throw new Error(courseJSON.msg || 'COURSE_RESPONSE');
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
          const allWeeks = Array.isArray(weeksJSON.data) ? weeksJSON.data.map(Number).filter(Number.isFinite) : [];
          const currentWeek = Number(currentWeekJSON?.data?.xlzc || currentWeekJSON?.data?.zc || 0) || null;
          const successfulGradeResponses = gradeJSONs
            .map((payload, categoryIndex) => ({payload, categoryIndex}))
            .filter(item => item.payload && item.payload.ret === 0);
          const grades = successfulGradeResponses.length ? successfulGradeResponses.flatMap(({payload, categoryIndex}) => {
            const records = Array.isArray(payload.results) ? payload.results : [];
            const category = gradeCategories[categoryIndex]?.label || '主修';
            return records.map((item, index) => ({
              id: text(item.id) || [text(item.xnxq), text(item.kcbh), category, index].join('|'),
              term: text(item.xnxq),
              courseName: plain(item.kcmc).replace(/^\[[^\]]+\]\s*/, ''),
              score: text(item.zhcj || item.yscj),
              credit: text(item.xf),
              gradePoint: text(item.jd),
              courseNature: text(item.kcxzmc || item.kcxz),
              examType: text(item.ksxs),
              category
            })).filter(item => item.courseName);
          }) : null;
          return JSON.stringify({
            term,
            maxWeek: allWeeks.length ? Math.max(...allWeeks) : 19,
            currentWeek,
            profile: {
              studentNumber: profileNumber,
              name: profileName,
              gpa: profileGPA
            },
            courses,
            grades
          });
        })().catch(error => JSON.stringify({__error:String(error && error.message || error)}))
        """#
        let result = try await webView.callAsyncJavaScript(
            "return await " + script,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        guard let json = result as? String,
              let data = json.data(using: .utf8) else { throw PortalError.invalidResponse }
        if let failure = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = failure["__error"] as? String {
            if message.contains("AUTH_REQUIRED") { throw PortalError.authorizationRequired }
            if PortalError.isNetworkMessage(message) { throw PortalError.networkUnavailable }
            throw PortalError.remote(message)
        }
        do { return try JSONDecoder().decode(PortalSnapshot.self, from: data) }
        catch { throw PortalError.invalidResponse }
    }

    func restorePersistedCookies() async {
        for cookie in CookieVault.load() {
            await withCheckedContinuation { continuation in
                webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { continuation.resume() }
            }
        }
    }

    func persistCookies() async {
        CookieVault.save(await cookies())
    }

    func clearLogin() async {
        let store = webView.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            store.removeData(ofTypes: types, modifiedSince: .distantPast) { continuation.resume() }
        }
        CookieVault.clear()
        pageStatus = "已清除内嵌浏览器登录状态"
    }

}

extension WebSession: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let isPortalHome = webView.url?.host == "jwxt.imnu.edu.cn" && (webView.url?.path == "/admin" || webView.url?.path.hasPrefix("/admin/") == true)
            self.isLoggedIn = isPortalHome
            self.pageStatus = isPortalHome
                ? "官网登录已恢复，正在读取本学期课表…"
                : (webView.url?.host.map { "已打开 \($0)，请完成扫码授权" } ?? "页面已加载")
            if webView.url?.host?.hasSuffix("imnu.edu.cn") == true {
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

private extension WebSession {
    func handleLoadFailure(_ error: Error) {
        if PortalError.isNetworkError(error) {
            isNetworkAvailable = false
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
            return true
        }
        return isNetworkMessage(error.localizedDescription)
    }

    static func isNetworkMessage(_ message: String) -> Bool {
        let value = message.lowercased()
        return [
            "failed to fetch", "networkerror", "network connection was lost",
            "not connected to the internet", "internet connection appears to be offline",
            "could not connect", "timed out", "offline"
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
        syncObservation = store.$syncState.sink { [weak self, weak window] state in
            if case .ready = state, self?.navigation.destination == .authorization { window?.orderOut(nil) }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("AuthorizationWindowController must be created programmatically")
    }

    func showAuthorization() {
        navigation.destination = .authorization
        window?.title = "教务悬浮助手 · 授权登录"
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if webSession.webView.url == nil { webSession.openPortal() }
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
    enum Destination { case authorization, portalHome }
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
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(navigation.destination == .portalHome ? "教务系统首页" : "首次授权只需完成一次")
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

            HStack {
                Text(webSession.pageStatus)
                Spacer()
                if case .ready = store.syncState {
                    Label("课表已自动同步", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
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
            .font(.caption)
            .padding(14)
        }
        .frame(minWidth: 700, minHeight: 520)
    }

    private var headerDescription: String {
        if navigation.destination == .portalHome {
            return "此页直接使用悬浮助手已保存的官方登录会话。授权仍有效时会直接显示教务系统首页，不需要再次扫码。"
        }
        return "请使用微信扫描页面二维码。扫码成功后，程序会自动读取课表、成绩和个人信息并缓存到本机，无需粘贴任何链接。"
    }
}
