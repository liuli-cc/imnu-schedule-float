import Foundation

// Compiled with Models/ScheduleStore and this small transport stub. No network,
// real browser, user cache, or credentials are used by these regression checks.
@MainActor
final class WebSession {
    var isNetworkAvailable = true
    var pageStatus = ""
    var fetch: () async throws -> PortalSnapshot = { throw TestFailure.failed("Missing fixture") }
    func fetchPortalSnapshot() async throws -> PortalSnapshot { try await fetch() }
}
enum PortalError: Error { case authorizationRequired, networkUnavailable }
enum TestFailure: Error { case failed(String) }

@main
struct AcademicDataRegression {
    @MainActor static func main() async throws {
        var assertions = 0
        func check(_ result: Bool, _ label: String) throws {
            guard result else { throw TestFailure.failed(label) }
            assertions += 1
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
        let sunday = date("2026-09-20T18:00:00Z")
        let monday = date("2026-09-21T00:01:00Z")
        try check(LocalCalendar.teachingWeek(anchorWeek: 3, anchorDate: sunday, on: monday, maxWeek: 19, calendar: calendar) == 4, "Sunday-to-Monday advances teaching week")
        try check(LocalCalendar.teachingWeek(anchorWeek: nil, anchorDate: sunday, on: monday, maxWeek: 19, calendar: calendar) == nil, "Never invent a week from a cache date")
        try check(LocalCalendar.teachingWeek(anchorWeek: 19, anchorDate: sunday, on: monday, maxWeek: 19, calendar: calendar) == nil, "Semester end is not clamped to the last week")
        try check(TeachingWeeks.parse("1-8单,10-16双") == [1,3,5,7,10,12,14,16], "Mixed parity week ranges")
        try check(TeachingWeeks.parse("1、3、5") == [1,3,5], "Explicit week lists")
        let interval = SectionTime.interval(startSection: 3, endSection: 4, on: monday, calendar: calendar)!
        try check(calendar.component(.hour, from: interval.start) == 10 && calendar.component(.minute, from: interval.start) == 20, "Known school time used for next class")
        let sample = Course(name: "Fixture", teacher: "", location: "", weekday: 1, startSection: 3, endSection: 4, weeks: "1-19", activeWeeks: Array(1...19), colorIndex: 0)
        let occurrence = CourseOccurrence(course: sample, startDate: interval.start, endDate: interval.end)
        try check(occurrence.isInProgress(at: interval.start) && !occurrence.isInProgress(at: interval.end), "Class end is exclusive")
        let parsed = try ScheduleParser.parse(data: Data(#"{"data":[{"kcmc":"Fixture","xqj":1,"jcs":"1-2","zcd":"2-8双"}]}"#.utf8))
        try check(parsed.first?.activeWeeks == [2,4,6,8], "Discovered schedules keep week filters")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("imnu-data-regression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cacheURL = directory.appendingPathComponent("cache.json")
        let cached = ScheduleCache(courses: [sample], updatedAt: sunday, source: "fixture", profile: .empty, term: "fixture", maxWeek: 19)
        try JSONEncoder().encode(cached).write(to: cacheURL)
        let store = ScheduleStore(cacheURL: cacheURL)
        try check(store.currentWeek == nil, "Legacy cache stays useful without a guessed current week")
        let session = WebSession()
        func grade(_ category: String, _ score: String) -> PortalGradePayload {
            PortalGradePayload(id: category, term: "fixture", courseName: "Fixture " + category, score: score, credit: "2", gradePoint: "", courseNature: "", examType: "", category: category)
        }
        func snapshot(_ grades: [PortalGradePayload], categories: [String], warnings: [String] = []) -> PortalSnapshot {
            PortalSnapshot(term: "fixture", maxWeek: 19, currentWeek: 4, profile: StudentProfile(studentNumber: "fixture-account", name: "Fixture", gpa: "3.0"), courses: [], grades: grades, gradeCategoriesSynced: categories, currentWeekResolved: true, syncWarnings: warnings)
        }
        session.fetch = { snapshot([grade("主修", "0"), grade("辅修", "合格")], categories: ["主修", "辅修", "微专业"]) }
        await store.sync(using: session)
        try check(store.courses.isEmpty && store.lastUpdated != nil, "A successful empty timetable replaces stale courses")
        let originalGradesDate = store.gradesUpdatedAt
        session.fetch = { snapshot([grade("主修", "80")], categories: ["主修"], warnings: ["Partial fixture"]) }
        await store.sync(using: session)
        try check(store.grades.count == 2 && store.grades.contains { $0.category == "辅修" }, "Partial grades preserve unsuccessful category cache")
        try check(store.gradesUpdatedAt == originalGradesDate && store.syncWarnings.count == 1, "Partial sync does not relabel all grades fresh")
        let stats = store.gradeStatistics()
        try check(stats.courseCount == 2 && stats.earnedCredits == 4 && stats.failedCourseCount == 0, "Derived grade statistics reflect explicit outcomes")
        var fetchCount = 0
        session.fetch = {
            fetchCount += 1
            try await Task.sleep(for: .milliseconds(30))
            return snapshot([], categories: [])
        }
        async let first: Void = store.sync(using: session)
        async let second: Void = store.sync(using: session)
        _ = await (first, second)
        try check(fetchCount == 1, "Concurrent triggers coalesce into one sync")
        session.fetch = {
            try await Task.sleep(for: .milliseconds(30))
            return snapshot([], categories: ["主修", "辅修", "微专业"])
        }
        let before = store.lastUpdated
        let pending = Task { await store.sync(using: session) }
        try await Task.sleep(for: .milliseconds(5))
        store.markNeedsAuthorization(invalidatePendingSync: true)
        await pending.value
        try check(store.lastUpdated == before && store.syncState == .needsAuthorization, "Clearing authorization invalidates an in-flight response")
        session.isNetworkAvailable = false
        await store.sync(using: session)
        try check(store.grades.count == 2 && store.syncState == .offline, "Offline mode preserves cached grades")
        try check(CookieVault.isSchoolDomain(".IMNU.EDU.CN") && !CookieVault.isSchoolDomain("imnu.edu.cn.attacker.test"), "Cookie backup limited to school domains")
        let worker = KeychainWorker()
        let waitStarted = Date()
        let stalled = Task { await worker.perform(fallback: false) {
            Thread.sleep(forTimeInterval: 1.5)
            return true
        } }
        try await Task.sleep(for: .milliseconds(40))
        try check(Date().timeIntervalSince(waitStarted) < 0.5, "Blocked keychain worker leaves the main actor responsive")
        let stalledResult = await stalled.value
        try check(!stalledResult && Date().timeIntervalSince(waitStarted) < 1.3, "Keychain daemon stall has a bounded fallback")
        let retryStarted = Date()
        let retryResult = await worker.perform(fallback: false) { true }
        try check(!retryResult && Date().timeIntervalSince(retryStarted) < 0.2, "Timed-out keychain backend is not queued again")
        let blockedPermissionStarted = Date()
        let blockedPermission = await worker.performInteractive { true }
        try check(!blockedPermission && Date().timeIntervalSince(blockedPermissionStarted) < 0.2, "Explicit permission never queues behind a known stalled keychain operation")
        let fastWorker = KeychainWorker()
        let isOffMainThread = await fastWorker.perform(fallback: false) { !Thread.isMainThread }
        try check(isOffMainThread, "Keychain operations execute away from the UI thread")
        let explicitWorker = KeychainWorker()
        let interactive = Task { await explicitWorker.performInteractive {
            Thread.sleep(forTimeInterval: 1.0)
            return !Thread.isMainThread
        } }
        try await Task.sleep(for: .milliseconds(40))
        let backgroundDuringPrompt = await explicitWorker.perform(fallback: false) { true }
        try check(!backgroundDuringPrompt, "Background access does not run during explicit interactive permission")
        let interactiveResult = await interactive.value
        try check(interactiveResult, "Explicit permission remains off-main and may exceed the background timeout")
        let backgroundAfterPrompt = await explicitWorker.perform(fallback: false) { true }
        try check(backgroundAfterPrompt, "Background access resumes after explicit permission completes")
        print("Academic data regression: \(assertions) checks passed")
    }
}
