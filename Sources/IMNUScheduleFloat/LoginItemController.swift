import Foundation

/// A per-user login item. Quitting is respected: there is no KeepAlive job.
enum LoginItemController {
    static let label = "cn.liuli.imnu-schedule-float.login"
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return value["Label"] as? String == label && value["RunAtLoad"] as? Bool == true
    }

    static func setEnabled(_ enabled: Bool) throws {
        if !enabled {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            return
        }
        guard let executable = Bundle.main.executableURL else { throw CocoaError(.fileNoSuchFile) }
        let settings: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
