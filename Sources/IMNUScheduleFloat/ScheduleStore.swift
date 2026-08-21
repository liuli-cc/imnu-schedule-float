import Foundation
import WebKit

@MainActor
final class ScheduleStore: ObservableObject {
    @Published private(set) var courses: [Course] = []
    @Published private(set) var syncState: SyncState = .sample
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var profile: StudentProfile = .empty
    @Published private(set) var currentTerm = ""
    @Published private(set) var maxWeek = 19
    @Published private(set) var currentWeek: Int?

    private let cacheURL: URL
    private var refreshTimer: Timer?

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IMNUScheduleFloat", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cacheURL = directory.appendingPathComponent("schedule-cache.json")
        loadCache()
    }

    func startAutomaticRefresh(with webSession: WebSession) {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 45 * 60, target: self, selector: #selector(refreshTimerFired(_:)), userInfo: webSession, repeats: true)
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopAutomaticRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    @objc private func refreshTimerFired(_ timer: Timer) {
        guard let session = timer.userInfo as? WebSession else { return }
        Task { await sync(using: session) }
    }

    func sync(using webSession: WebSession) async {
        syncState = .syncing
        do {
            let snapshot = try await webSession.fetchPortalSnapshot()
            let sectionRows = snapshot.courses.enumerated().compactMap { index, payload in
                Self.course(from: payload, colorIndex: index)
            }
            let parsed = Self.mergeConsecutiveSections(sectionRows)
            guard !parsed.isEmpty else { throw SyncError.noRecognizedCourses }
            courses = parsed
            profile = snapshot.profile
            currentTerm = snapshot.term
            maxWeek = max(snapshot.maxWeek, 1)
            currentWeek = snapshot.currentWeek
            lastUpdated = Date()
            syncState = .ready(Date())
            webSession.pageStatus = "本学期课表与个人信息已保存到本机"
            saveCache(source: "教务系统学期课表")
        } catch PortalError.authorizationRequired {
            syncState = .needsAuthorization
        } catch {
            syncState = .failed(error.localizedDescription)
        }
    }

    func setEndpoint(_ endpoint: String) throws {
        guard let url = URL(string: endpoint), url.scheme == "https", url.host == "jwxt.imnu.edu.cn" else {
            throw SyncError.invalidEndpoint
        }
        try CredentialStore.saveScheduleEndpoint(endpoint)
    }

    /// The authenticated web view reports the actual timetable response. This
    /// stores the discovered endpoint locally and updates the cache without
    /// asking the student to expose or paste a personal URL.
    @discardableResult
    func acceptDiscoveredSchedule(endpoint: String, responseBody: String) -> Bool {
        guard let url = URL(string: endpoint), url.scheme == "https", url.host == "jwxt.imnu.edu.cn",
              let data = responseBody.data(using: .utf8) else { return false }
        do {
            let parsed = try ScheduleParser.parse(data: data)
            guard !parsed.isEmpty else { return false }
            if url.path.contains("/admin/api/getKbxx") {
                try CredentialStore.saveScheduleEndpoint(endpoint)
            }
            courses = parsed
            lastUpdated = Date()
            syncState = .ready(Date())
            saveCache(source: "教务系统自动发现")
            return true
        } catch {
            // Ignore unrelated or partial browser responses. A visible failure
            // is reserved for an explicit scheduled sync request.
            return false
        }
    }

    func clearEndpoint() {
        CredentialStore.deleteScheduleEndpoint()
        courses = []
        profile = .empty
        currentTerm = ""
        currentWeek = nil
        try? FileManager.default.removeItem(at: cacheURL)
        syncState = .sample
    }

    func todayCourses(reference: Date = .now) -> [Course] {
        guard let currentWeek else { return [] }
        let weekday = Calendar.current.component(.weekday, from: reference)
        let normalized = weekday == 1 ? 7 : weekday - 1
        return courses(forWeek: currentWeek)
            .filter { $0.weekday == normalized }
            .sorted { $0.startSection < $1.startSection }
    }

    func courses(forWeek week: Int?) -> [Course] {
        guard let week else { return [] }
        return courses.filter { course in
            guard let activeWeeks = course.activeWeeks, !activeWeeks.isEmpty else { return true }
            return activeWeeks.contains(week)
        }
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(ScheduleCache.self, from: data) else { return }
        courses = cached.courses
        profile = cached.profile ?? .empty
        currentTerm = cached.term ?? ""
        maxWeek = max(cached.maxWeek ?? 19, 1)
        lastUpdated = cached.updatedAt
        syncState = .ready(cached.updatedAt)
    }

    private func saveCache(source: String) {
        guard let lastUpdated else { return }
        let cache = ScheduleCache(
            courses: courses,
            updatedAt: lastUpdated,
            source: source,
            profile: profile,
            term: currentTerm,
            maxWeek: maxWeek
        )
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static func course(from payload: PortalCoursePayload, colorIndex: Int) -> Course? {
        let name = payload.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, (1...7).contains(payload.weekday) else { return nil }
        let sections = sectionRange(payload.section)
        return Course(
            name: name,
            teacher: payload.teacher,
            location: payload.location,
            weekday: payload.weekday,
            startSection: sections.0,
            endSection: sections.1,
            weeks: payload.weeks,
            activeWeeks: weekNumbers(payload.weeks),
            colorIndex: colorIndex % 6
        )
    }

    private static func sectionRange(_ raw: String) -> (Int, Int) {
        let numbers = raw.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        if numbers.count >= 2 { return (numbers[0], numbers[1]) }
        if let section = numbers.first ?? Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return (section, section)
        }
        return (1, 2)
    }

    private static func mergeConsecutiveSections(_ rows: [Course]) -> [Course] {
        let sorted = rows.sorted {
            let lhs = [$0.name, $0.teacher, $0.location, String($0.weekday), $0.weeks, String(format: "%03d", $0.startSection)].joined(separator: "|")
            let rhs = [$1.name, $1.teacher, $1.location, String($1.weekday), $1.weeks, String(format: "%03d", $1.startSection)].joined(separator: "|")
            return lhs < rhs
        }
        var merged: [Course] = []
        for row in sorted {
            if let lastIndex = merged.indices.last {
                let previous = merged[lastIndex]
                let sameClass = previous.name == row.name
                    && previous.teacher == row.teacher
                    && previous.location == row.location
                    && previous.weekday == row.weekday
                    && previous.weeks == row.weeks
                if sameClass && row.startSection <= previous.endSection + 1 {
                    merged[lastIndex].endSection = max(previous.endSection, row.endSection)
                    continue
                }
            }
            var course = row
            course.colorIndex = merged.count % 6
            merged.append(course)
        }
        return merged
    }

    private static func weekNumbers(_ raw: String) -> [Int]? {
        let text = raw.replacingOccurrences(of: "，", with: ",")
        let isOdd = text.contains("单")
        let isEven = text.contains("双")
        var result = Set<Int>()
        for part in text.split(separator: ",") {
            let values = part.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if values.count >= 2 {
                let lower = min(values[0], values[1])
                let upper = max(values[0], values[1])
                for week in lower...upper where (!isOdd || week.isMultiple(of: 2) == false) && (!isEven || week.isMultiple(of: 2)) {
                    result.insert(week)
                }
            } else if let week = values.first {
                result.insert(week)
            }
        }
        return result.isEmpty ? nil : result.sorted()
    }
}

enum SyncError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case http(Int)
    case noRecognizedCourses

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: return "课表接口必须是 jwxt.imnu.edu.cn 的 HTTPS 地址"
        case .invalidResponse: return "教务系统返回了无效响应"
        case .http(let status): return "教务系统请求失败（HTTP \(status)）"
        case .noRecognizedCourses: return "已获取数据，但暂未识别出课程字段"
        }
    }
}

enum ScheduleParser {
    static func parse(data: Data) throws -> [Course] {
        let object = try JSONSerialization.jsonObject(with: normalizedJSONData(from: data))
        guard let items = findCandidateArray(in: object) else { return [] }
        return items.enumerated().compactMap { index, item in
            guard let item = item as? [String: Any] else { return nil }
            let name = value(item, keys: ["kcmc", "KCMC", "kcm", "courseName", "course_name", "course", "name"])
            guard !name.isEmpty else { return nil }
            let weekday = weekdayValue(value(item, keys: ["xqj", "XQJ", "weekday", "weekDay", "xq", "xqjmc"])); guard weekday > 0 else { return nil }
            let sections = sectionRange(value(item, keys: ["jcs", "JCS", "section", "sections", "classSection", "skjc", "ksjc", "kssj"]))
            return Course(
                name: name,
                teacher: value(item, keys: ["jsmc", "JSMC", "teacher", "teacherName", "skjs", "jsxm"]),
                location: value(item, keys: ["jxcdmc", "JXCDMC", "classroom", "location", "cdmc", "skdd"]),
                weekday: weekday,
                startSection: sections.0,
                endSection: sections.1,
                weeks: value(item, keys: ["zcd", "ZCD", "weeks", "weekRange", "zc", "skzc"]),
                colorIndex: index % 6
            )
        }
    }

    private static func findCandidateArray(in object: Any) -> [Any]? {
        if let array = object as? [Any], array.contains(where: isCourseDictionary) {
            return array
        }
        if let dictionary = object as? [String: Any] {
            for value in dictionary.values {
                if let candidate = findCandidateArray(in: value) { return candidate }
                if let text = value as? String,
                   let nested = try? JSONSerialization.jsonObject(with: normalizedJSONData(from: Data(text.utf8))),
                   let candidate = findCandidateArray(in: nested) {
                    return candidate
                }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let candidate = findCandidateArray(in: value) { return candidate }
            }
        }
        return nil
    }

    private static func isCourseDictionary(_ value: Any) -> Bool {
        guard let dictionary = value as? [String: Any] else { return false }
        return ["kcmc", "KCMC", "kcm", "courseName", "course_name", "course"].contains { dictionary[$0] != nil }
    }

    private static func normalizedJSONData(from data: Data) throws -> Data {
        let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .unicode)
        guard var text = decoded else { throw ParserError.unsupportedEncoding }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        if text.hasPrefix("<") { throw ParserError.htmlResponse }
        if text.hasPrefix(")]}'") {
            text = String(text.drop { $0 != "\n" }).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard text.first == "{" || text.first == "[" || text.first == "\"" else {
            throw ParserError.unsupportedPayload
        }
        return Data(text.utf8)
    }

    private static func value(_ dictionary: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = dictionary[key] { return String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return ""
    }

    private static func weekdayValue(_ raw: String) -> Int {
        let map = ["星期一": 1, "星期二": 2, "星期三": 3, "星期四": 4, "星期五": 5, "星期六": 6, "星期日": 7, "周日": 7, "周一": 1, "周二": 2, "周三": 3, "周四": 4, "周五": 5, "周六": 6]
        if let mapped = map[raw] { return mapped }
        return Int(raw) ?? 0
    }

    private static func sectionRange(_ raw: String) -> (Int, Int) {
        let digits = raw.compactMap(\.wholeNumberValue)
        if digits.count >= 2 {
            let numbers = raw.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if numbers.count >= 2 { return (numbers[0], numbers[1]) }
            if raw.count >= 4, let first = Int(String(raw.prefix(2))), let last = Int(String(raw.suffix(2))) { return (first, last) }
            return (digits[0], digits[1])
        }
        if let section = Int(raw) { return (section, section) }
        return (1, 2)
    }
}

enum ParserError: LocalizedError {
    case htmlResponse
    case unsupportedEncoding
    case unsupportedPayload

    var errorDescription: String? {
        switch self {
        case .htmlResponse: return "教务系统返回了网页而不是课表数据，请重新授权"
        case .unsupportedEncoding: return "教务系统返回了无法识别的文本编码"
        case .unsupportedPayload: return "教务系统返回了未支持的数据格式"
        }
    }
}
