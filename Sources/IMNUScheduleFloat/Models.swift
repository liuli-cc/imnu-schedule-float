import Foundation

enum LocalCalendar {
    /// Returns the app's Monday=1 ... Sunday=7 weekday convention.
    static func weekday(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> Int {
        let systemWeekday = calendar.component(.weekday, from: date)
        return systemWeekday == 1 ? 7 : systemWeekday - 1
    }

    static func monday(containing date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1 - weekday(for: date, calendar: calendar), to: start) ?? start
    }

    static func teachingWeek(anchorWeek: Int?, anchorDate: Date?, on date: Date, maxWeek: Int,
                             calendar: Calendar = .autoupdatingCurrent) -> Int? {
        guard let anchorWeek, let anchorDate, anchorWeek > 0 else { return nil }
        let start = monday(containing: anchorDate, calendar: calendar)
        let target = monday(containing: date, calendar: calendar)
        let days = calendar.dateComponents([.day], from: start, to: target).day ?? 0
        let week = anchorWeek + days / 7
        return (1...max(maxWeek, 1)).contains(week) ? week : nil
    }
}

struct Course: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var teacher: String
    var location: String
    /// 1 is Monday and 7 is Sunday.
    var weekday: Int
    var startSection: Int
    var endSection: Int
    var weeks: String
    var activeWeeks: [Int]?
    var colorIndex: Int

    var sectionText: String {
        startSection == endSection ? "第\(startSection)节" : "第\(startSection)-\(endSection)节"
    }

    var timeText: String {
        SectionTime.text(startSection: startSection, endSection: endSection)
    }
}

enum TeachingWeeks {
    static func parse(_ raw: String) -> [Int]? {
        let text = ["，", "、", ";", "；"].reduce(raw) { $0.replacingOccurrences(of: $1, with: ",") }
        var result = Set<Int>()
        for part in text.split(separator: ",") {
            let values = part.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard let first = values.first, (1...60).contains(first) else { continue }
            let last = values.count >= 2 ? values[1] : first
            guard (1...60).contains(last) else { continue }
            let isOdd = part.contains("单"), isEven = part.contains("双")
            for week in min(first, last)...max(first, last)
                where (!isOdd || !week.isMultiple(of: 2)) && (!isEven || week.isMultiple(of: 2)) {
                result.insert(week)
            }
        }
        return result.isEmpty ? nil : result.sorted()
    }
}

enum SectionTime {
    private struct Block {
        let sections: ClosedRange<Int>
        let start: String
        let end: String
    }

    // 教务系统课表页的“大节”时间：每个大节包含连续两小节。
    private static let blocks = [
        Block(sections: 1...2, start: "08:20", end: "10:00"),
        Block(sections: 3...4, start: "10:20", end: "12:00"),
        Block(sections: 5...6, start: "14:00", end: "15:40"),
        Block(sections: 7...8, start: "16:00", end: "17:40"),
        Block(sections: 9...10, start: "19:00", end: "20:40")
    ]

    static func text(startSection: Int, endSection: Int) -> String {
        guard let first = blocks.first(where: { $0.sections.contains(startSection) }),
              let last = blocks.first(where: { $0.sections.contains(endSection) }) else { return "" }
        return "\(first.start)–\(last.end)"
    }

    static func interval(startSection: Int, endSection: Int, on date: Date,
                         calendar: Calendar = .autoupdatingCurrent) -> DateInterval? {
        guard let first = blocks.first(where: { $0.sections.contains(startSection) }),
              let last = blocks.first(where: { $0.sections.contains(endSection) }) else { return nil }
        func time(_ text: String) -> Date? {
            let parts = text.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { return nil }
            return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: date)
        }
        guard let start = time(first.start), let end = time(last.end), end > start else { return nil }
        return DateInterval(start: start, end: end)
    }
}

struct CourseOccurrence: Identifiable {
    var course: Course
    var startDate: Date
    var endDate: Date
    var id: String { "\(course.id.uuidString)-\(startDate.timeIntervalSince1970)" }
    func isInProgress(at date: Date = .now) -> Bool { startDate <= date && date < endDate }
}

struct GradeStatistics {
    var courseCount: Int
    /// Credits attached to all cached records; repeated attempts remain separate.
    var recordedCredits: Double
    /// Credits only for records whose score explicitly indicates a passing result.
    var earnedCredits: Double
    var failedCourseCount: Int
}

struct StudentProfile: Codable, Equatable {
    var studentNumber: String
    var name: String
    var gpa: String

    static let empty = StudentProfile(studentNumber: "", name: "", gpa: "")
}

struct GradeRecord: Codable, Identifiable, Hashable {
    var id: String
    var term: String
    var courseName: String
    var score: String
    var credit: String
    var gradePoint: String
    var courseNature: String
    var examType: String
    var category: String

    var termLabel: String {
        let parts = term.split(separator: "-")
        guard parts.count >= 3 else { return term }
        return "\(parts[0])-\(parts[1])学年第\(parts[2])学期"
    }
}

struct ScheduleCache: Codable {
    var courses: [Course]
    var updatedAt: Date
    var source: String
    var profile: StudentProfile?
    var term: String?
    var maxWeek: Int?
    var currentWeek: Int?
    var grades: [GradeRecord]?
    var gradesUpdatedAt: Date?
    var currentWeekAnchorDate: Date?
    var syncWarnings: [String]?
}

struct PortalSnapshot: Decodable {
    var term: String
    var maxWeek: Int
    var currentWeek: Int?
    var profile: StudentProfile
    var courses: [PortalCoursePayload]
    var grades: [PortalGradePayload]?
    var gradeCategoriesSynced: [String]?
    var currentWeekResolved: Bool?
    var syncWarnings: [String]?
}

struct PortalCoursePayload: Decodable {
    var name: String
    var teacher: String
    var location: String
    var weekday: Int
    var section: String
    var weeks: String
}

struct PortalGradePayload: Decodable {
    var id: String
    var term: String
    var courseName: String
    var score: String
    var credit: String
    var gradePoint: String
    var courseNature: String
    var examType: String
    var category: String
}

enum SyncState: Equatable {
    case sample
    case syncing
    case ready(Date)
    case offline
    case needsAuthorization
    case failed(String)

    var message: String {
        switch self {
        case .sample: return "尚未同步真实课表"
        case .syncing: return "正在读取本学期课表"
        case .ready:
            return "已同步"
        case .offline: return "网络不可用，正在使用已缓存的课表"
        case .needsAuthorization: return "登录已失效，请重新授权"
        case .failed(let reason): return reason
        }
    }
}

enum CourseSamples {
    static let courses: [Course] = [
        Course(name: "大学英语", teacher: "王老师", location: "赛罕校区·田楼 204", weekday: 1, startSection: 1, endSection: 2, weeks: "1-16周", activeWeeks: Array(1...16), colorIndex: 0),
        Course(name: "高等数学", teacher: "李老师", location: "赛罕校区·行知楼 312", weekday: 1, startSection: 3, endSection: 4, weeks: "1-16周", activeWeeks: Array(1...16), colorIndex: 1),
        Course(name: "计算机基础", teacher: "张老师", location: "赛罕校区·信息楼 401", weekday: 3, startSection: 1, endSection: 2, weeks: "1-16周", activeWeeks: Array(1...16), colorIndex: 2),
        Course(name: "形势与政策", teacher: "赵老师", location: "赛罕校区·田楼 108", weekday: 5, startSection: 5, endSection: 6, weeks: "3-14周", activeWeeks: Array(3...14), colorIndex: 3)
    ]
}
