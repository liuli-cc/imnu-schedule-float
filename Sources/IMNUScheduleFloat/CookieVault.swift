import Foundation

enum CookieVault {
    private struct StoredCookie: Codable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var expires: Date?
        var secure: Bool
        var httpOnly: Bool?
        var sameSite: String?

        init(_ cookie: HTTPCookie) {
            name = cookie.name
            value = cookie.value
            domain = cookie.domain
            path = cookie.path
            expires = cookie.expiresDate
            secure = cookie.isSecure
            httpOnly = cookie.isHTTPOnly
            sameSite = cookie.properties?[HTTPCookiePropertyKey(rawValue: "SameSite")] as? String
        }

        var cookie: HTTPCookie? {
            guard expires.map({ $0 > Date() }) ?? true else { return nil }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: path
            ]
            if let expires { properties[.expires] = expires }
            if secure { properties[.secure] = "TRUE" }
            if httpOnly == true { properties[HTTPCookiePropertyKey(rawValue: "HttpOnly")] = "TRUE" }
            if let sameSite { properties[HTTPCookiePropertyKey(rawValue: "SameSite")] = sameSite }
            return HTTPCookie(properties: properties)
        }
    }

    private static let fileURL: URL = {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IMNUScheduleFloat", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("authenticated-cookies.archive")
    }()

    @discardableResult
    static func save(_ cookies: [HTTPCookie]) async -> Bool {
        let imnuCookies = cookies
            .filter { isSchoolDomain($0.domain) && ($0.expiresDate.map { $0 > Date() } ?? true) }
            .map(StoredCookie.init)
        guard !imnuCookies.isEmpty, let data = try? JSONEncoder().encode(imnuCookies), await CredentialStore.saveSessionData(data) else { return false }
        // Remove the legacy plaintext archive only after the encrypted write
        // succeeds. WebKit remains the primary persistent browser session.
        try? FileManager.default.removeItem(at: fileURL)
        return true
    }

    static func requestPermissionAndSave(_ cookies: [HTTPCookie]) async -> Bool {
        let records = cookies
            .filter { isSchoolDomain($0.domain) && ($0.expiresDate.map { $0 > Date() } ?? true) }
            .map(StoredCookie.init)
        guard !records.isEmpty, let data = try? JSONEncoder().encode(records),
              await CredentialStore.requestPermissionAndSaveSessionData(data) else { return false }
        try? FileManager.default.removeItem(at: fileURL)
        return true
    }

    struct RestoredSession {
        var cookies: [HTTPCookie]
        var isSavedSecurely: Bool
    }

    static func load() async -> RestoredSession {
        let legacy = try? Data(contentsOf: fileURL)
        let secureData = await CredentialStore.sessionData()
        guard let data = secureData ?? legacy,
              let records = try? JSONDecoder().decode([StoredCookie].self, from: data) else {
            return RestoredSession(cookies: [], isSavedSecurely: false)
        }
        let cookies = records.compactMap(\.cookie).filter { isSchoolDomain($0.domain) }
        let securelySaved = legacy != nil ? await save(cookies) : secureData != nil
        return RestoredSession(cookies: cookies, isSavedSecurely: securelySaved && !cookies.isEmpty)
    }

    static func clear() async {
        await CredentialStore.deleteSessionData()
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func isSchoolDomain(_ domain: String) -> Bool {
        let normalized = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized == "imnu.edu.cn" || normalized.hasSuffix(".imnu.edu.cn")
    }
}
