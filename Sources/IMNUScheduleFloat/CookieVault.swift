import Foundation

enum CookieVault {
    private struct StoredCookie: Codable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var expires: Date?
        var secure: Bool

        init(_ cookie: HTTPCookie) {
            name = cookie.name
            value = cookie.value
            domain = cookie.domain
            path = cookie.path
            expires = cookie.expiresDate
            secure = cookie.isSecure
        }

        var cookie: HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: path
            ]
            if let expires { properties[.expires] = expires }
            if secure { properties[.secure] = "TRUE" }
            return HTTPCookie(properties: properties)
        }
    }

    private static let fileURL: URL = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IMNUScheduleFloat", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("authenticated-cookies.archive")
    }()

    static func save(_ cookies: [HTTPCookie]) {
        let imnuCookies = cookies
            .filter { $0.domain == "imnu.edu.cn" || $0.domain.hasSuffix(".imnu.edu.cn") }
            .map(StoredCookie.init)
        guard let data = try? JSONEncoder().encode(imnuCookies) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            // The live WebKit session still works if a local persistence write fails.
        }
    }

    static func load() -> [HTTPCookie] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode([StoredCookie].self, from: data) else { return [] }
        return records.compactMap(\.cookie)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
