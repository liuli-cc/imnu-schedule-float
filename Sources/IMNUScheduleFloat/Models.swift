import Foundation

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
}

struct StudentProfile: Codable, Equatable {
    var studentNumber: String
    var name: String
    var gpa: String

    static let empty = StudentProfile(studentNumber: "", name: "", gpa: "")
}

struct ScheduleCache: Codable {
    var courses: [Course]
    var updatedAt: Date
    var source: String
    var profile: StudentProfile?
    var term: String?
    var maxWeek: Int?
}

struct PortalSnapshot: Decodable {
    var term: String
    var maxWeek: Int
    var currentWeek: Int?
    var profile: StudentProfile
    var courses: [PortalCoursePayload]
}

struct PortalCoursePayload: Decodable {
    var name: String
    var teacher: String
    var location: String
    var weekday: Int
    var section: String
    var weeks: String
}

enum SyncState: Equatable {
    case sample
    case syncing
    case ready(Date)
    case needsAuthorization
    case failed(String)

    var message: String {
        switch self {
        case .sample: return "尚未同步真实课表"
        case .syncing: return "正在读取本学期课表"
        case .ready:
            return "已同步"
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
