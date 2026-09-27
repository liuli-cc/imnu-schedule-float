import Foundation
import Combine
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
    @Published private(set) var grades: [GradeRecord] = []
    @Published private(set) var gradesUpdatedAt: Date?
    @Published private(set) var syncWarnings: [String] = []
    /// Local wall-clock time. It is deliberately independent of the portal
    /// session so the date and weekday continue working without internet.
    @Published private(set) var localDate = Date()

    private let cacheURL: URL
    private var refreshTimer: Timer?
    private var localClockTimer: Timer?
    private var syncInProgress = false
    private var cacheGeneration = 0
    private var weekAnchor: Int?
    private var weekAnchorDate: Date?

    init(cacheURL suppliedCacheURL: URL? = nil) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IMNUScheduleFloat", isDirectory: true)
        cacheURL = suppliedCacheURL ?? directory.appendingPathComponent("schedule-cache.json")
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
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

    func startLocalClock() {
        localClockTimer?.invalidate()
        localDate = Date()
        updateTeachingWeek()
        let timer = Timer(
            timeInterval: 30,
            target: self,
            selector: #selector(localClockFired(_:)),
            userInfo: nil,
            repeats: true
        )
        localClockTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopLocalClock() {
        localClockTimer?.invalidate()
        localClockTimer = nil
    }

    @objc private func localClockFired(_ timer: Timer) {
        localDate = Date()
        updateTeachingWeek()
    }

    @objc private func refreshTimerFired(_ timer: Timer) {
        guard let session = timer.userInfo as? WebSession else { return }
        Task { await sync(using: session) }
    }

    func sync(using webSession: WebSession) async {
        guard !syncInProgress else { return }
        guard webSession.isNetworkAvailable else {
            markOffline()
            return
        }
        syncInProgress = true
        let generation = cacheGeneration
        defer { syncInProgress = false }
        syncState = .syncing
        do {
            let snapshot = try await webSession.fetchPortalSnapshot()
            let sectionRows = snapshot.courses.enumerated().compactMap { index, payload in
                Self.course(from: payload, colorIndex: index)
            }
            let parsed = Self.mergeConsecutiveSections(sectionRows)
            guard snapshot.courses.isEmpty || !parsed.isEmpty else { throw SyncError.noRecognizedCourses }
            guard generation == cacheGeneration else { return }
            let now = Date()
            let sameTerm = currentTerm == snapshot.term
            let accountChanged = !profile.studentNumber.isEmpty && !snapshot.profile.studentNumber.isEmpty
                && profile.studentNumber != snapshot.profile.studentNumber
            if accountChanged {
                profile = .empty
                grades = []
                gradesUpdatedAt = nil
            }
            courses = parsed
            profile = StudentProfile(
                studentNumber: snapshot.profile.studentNumber.isEmpty ? profile.studentNumber : snapshot.profile.studentNumber,
                name: snapshot.profile.name.isEmpty ? profile.name : snapshot.profile.name,
                gpa: snapshot.profile.gpa.isEmpty ? profile.gpa : snapshot.profile.gpa
            )
            currentTerm = snapshot.term
            maxWeek = max(snapshot.maxWeek, 1)
            if let officialWeek = snapshot.currentWeek, (1...maxWeek).contains(officialWeek) {
                weekAnchor = officialWeek
                weekAnchorDate = now
            } else if snapshot.currentWeekResolved == true || !sameTerm || accountChanged {
                weekAnchor = nil
                weekAnchorDate = nil
            }
            localDate = now
            updateTeachingWeek()
            if let gradePayloads = snapshot.grades {
                let refreshed = gradePayloads.map {
                    GradeRecord(
                        id: $0.id,
                        term: $0.term,
                        courseName: $0.courseName,
                        score: $0.score,
                        credit: $0.credit,
                        gradePoint: $0.gradePoint,
                        courseNature: $0.courseNature,
                        examType: $0.examType,
                        category: $0.category
                    )
                }
                if let categories = snapshot.gradeCategoriesSynced {
                    grades = grades.filter { !categories.contains($0.category) } + refreshed
                    if Set(categories).isSuperset(of: ["主修", "辅修", "微专业"]) { gradesUpdatedAt = now }
                } else {
                    grades = refreshed
                    gradesUpdatedAt = now
                }
            }
            syncWarnings = snapshot.syncWarnings ?? []
            lastUpdated = now
            syncState = .ready(now)
            webSession.pageStatus = syncWarnings.isEmpty ? "课表、成绩与个人信息已保存到本机" : "课表已保存；部分附加信息暂未更新"
            saveCache(source: "教务系统课表与成绩")
        } catch PortalError.authorizationRequired {
            guard generation == cacheGeneration else { return }
            syncState = .needsAuthorization
        } catch PortalError.networkUnavailable {
            guard generation == cacheGeneration else { return }
            markOffline()
        } catch {
            guard generation == cacheGeneration else { return }
            syncState = .failed(error.localizedDescription)
        }
    }

    func markOffline() {
        // Intentionally keep courses, profile, and the persisted session/cache.
        // A connectivity failure is not evidence that the user logged out.
        syncState = .offline
    }

    func markNeedsAuthorization(invalidatePendingSync: Bool = false) {
        if invalidatePendingSync { cacheGeneration += 1 }
        syncState = .needsAuthorization
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
        cacheGeneration += 1
        CredentialStore.deleteScheduleEndpoint()
        courses = []
        profile = .empty
        currentTerm = ""
        currentWeek = nil
        weekAnchor = nil
        weekAnchorDate = nil
        grades = []
        gradesUpdatedAt = nil
        syncWarnings = []
        lastUpdated = nil
        try? FileManager.default.removeItem(at: cacheURL)
        syncState = .sample
    }

    func todayCourses(reference: Date = .now) -> [Course] {
        courses(on: reference, teachingWeek: teachingWeek(on: reference))
    }

    func tomorrowCourses(reference: Date = .now) -> [Course] {
        let calendar = Calendar.autoupdatingCurrent
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: reference) else { return [] }
        return courses(on: tomorrow, teachingWeek: teachingWeek(on: tomorrow))
    }

    private func courses(on date: Date, teachingWeek: Int?) -> [Course] {
        guard let teachingWeek else { return [] }
        let normalized = LocalCalendar.weekday(for: date)
        return courses(forWeek: teachingWeek)
            .filter { $0.weekday == normalized }
            .sorted { $0.startSection < $1.startSection }
    }

    func courses(forWeek week: Int?) -> [Course] {
        guard let week, (1...maxWeek).contains(week) else { return [] }
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
        grades = cached.grades ?? []
        gradesUpdatedAt = cached.gradesUpdatedAt
        weekAnchor = cached.currentWeek
        weekAnchorDate = cached.currentWeekAnchorDate ?? cached.updatedAt
        syncWarnings = cached.syncWarnings ?? []
        updateTeachingWeek()
        syncState = .ready(cached.updatedAt)
    }

    /// Advance only from a real portal week; the cache file's age is not a
    /// semester start date. Monday boundaries work across DST and year changes.
    private func teachingWeek(on date: Date) -> Int? {
        LocalCalendar.teachingWeek(anchorWeek: weekAnchor, anchorDate: weekAnchorDate, on: date, maxWeek: maxWeek)
    }

    private func updateTeachingWeek() {
        currentWeek = teachingWeek(on: localDate)
    }

    func nextCourse(reference: Date = .now) -> CourseOccurrence? {
        let calendar = Calendar.autoupdatingCurrent
        for offset in 0..<(maxWeek * 7) {
            guard let date = calendar.date(byAdding: .day, value: offset, to: reference),
                  let week = teachingWeek(on: date) else { continue }
            let occurrences = courses(on: date, teachingWeek: week).compactMap { course -> CourseOccurrence? in
                guard let interval = SectionTime.interval(startSection: course.startSection, endSection: course.endSection, on: date),
                      interval.end > reference else { return nil }
                return CourseOccurrence(course: course, startDate: interval.start, endDate: interval.end)
            }
            if let next = occurrences.min(by: { $0.startDate < $1.startDate }) { return next }
        }
        return nil
    }

    private func saveCache(source: String) {
        guard let lastUpdated else { return }
        let cache = ScheduleCache(
            courses: courses,
            updatedAt: lastUpdated,
            source: source,
            profile: profile,
            term: currentTerm,
            maxWeek: maxWeek,
            currentWeek: weekAnchor,
            grades: grades,
            gradesUpdatedAt: gradesUpdatedAt,
            currentWeekAnchorDate: weekAnchorDate,
            syncWarnings: syncWarnings
        )
        guard let data = try? JSONEncoder().encode(cache) else { return }
        do {
            try data.write(to: cacheURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        } catch {
            // Keep the in-memory data usable if local persistence fails.
        }
    }

    var gradeTerms: [String] {
        Array(Set(grades.map(\.term))).sorted(by: >)
    }

    func grades(forTerm term: String) -> [GradeRecord] {
        grades.filter { $0.term == term }.sorted {
            if $0.category != $1.category { return $0.category < $1.category }
            return $0.courseName.localizedStandardCompare($1.courseName) == .orderedAscending
        }
    }

    func gradeStatistics(forTerm term: String? = nil) -> GradeStatistics {
        let records = term.map { grades(forTerm: $0) } ?? grades
        func passing(_ grade: GradeRecord) -> Bool? {
            let score = grade.score.trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = Double(score) { return number >= 60 }
            if ["优秀", "良好", "中等", "及格", "合格", "通过"].contains(score) { return true }
            if ["不及格", "不合格", "未通过"].contains(score) { return false }
            return nil
        }
        return GradeStatistics(courseCount: records.count,
            recordedCredits: records.reduce(0) { $0 + (Double($1.credit) ?? 0) },
            earnedCredits: records.filter { passing($0) == true }.reduce(0) { $0 + (Double($1.credit) ?? 0) },
            failedCourseCount: records.filter { passing($0) == false }.count)
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
            activeWeeks: TeachingWeeks.parse(payload.weeks),
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
                activeWeeks: TeachingWeeks.parse(value(item, keys: ["zcd", "ZCD", "weeks", "weekRange", "zc", "skzc"])),
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
