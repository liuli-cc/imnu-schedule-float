import Foundation
import Security
import LocalAuthentication

/// The legacy macOS keychain can wait inside securityd even when LAContext
/// disallows interaction. Never run its synchronous API on the UI executor.
final class KeychainWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "IMNUScheduleFloat.Keychain", qos: .utility)
    private let lock = NSLock()
    private var unavailable = false
    private var interactiveRequestPending = false

    private var isUnavailable: Bool { lock.withLock { unavailable || interactiveRequestPending } }
    var hasTimedOut: Bool { lock.withLock { unavailable } }
    private func disableForThisProcess() { lock.withLock { unavailable = true } }

    func perform<Value: Sendable>(fallback: Value, operation: @escaping @Sendable () -> Value) async -> Value {
        guard !isUnavailable else { return fallback }
        return await withCheckedContinuation { continuation in
            let pending = KeychainResult(continuation: continuation)
            // A daemon failure must not gate opening the portal or interacting
            // with the floating ball. Stop scheduling more keychain work after
            // a timeout; the existing item and its ACL stay untouched.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.8) { [self] in
                if pending.resolve(fallback) { disableForThisProcess() }
            }
            queue.async { [self] in
                guard pending.isPending, !isUnavailable else {
                    pending.resolve(fallback)
                    return
                }
                // Required for the legacy login-keychain backend: LAContext
                // alone did not prevent an ACL wait after ad-hoc app updates.
                SecKeychainSetUserInteractionAllowed(false)
                pending.resolve(operation())
            }
        }
    }

    /// Called only from an explicit user action. The same serial queue keeps
    /// background access out while legacy interaction is temporarily allowed.
    func performInteractive(operation: @escaping @Sendable () -> Bool) async -> Bool {
        let canStart = lock.withLock {
            guard !unavailable, !interactiveRequestPending else { return false }
            interactiveRequestPending = true
            return true
        }
        guard canStart else { return false }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                let result: Bool = {
                    SecKeychainSetUserInteractionAllowed(true)
                    defer { SecKeychainSetUserInteractionAllowed(false) }
                    return operation()
                }()
                lock.withLock {
                    interactiveRequestPending = false
                    if result { unavailable = false }
                }
                continuation.resume(returning: result)
            }
        }
    }
}

private final class KeychainResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    init(continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
    var isPending: Bool { lock.withLock { continuation != nil } }
    @discardableResult func resolve(_ value: Value) -> Bool {
        let next = lock.withLock {
            let current = continuation
            continuation = nil
            return current
        }
        guard let next else { return false }
        next.resume(returning: value)
        return true
    }
}

enum CredentialStore {
    private static let endpointDefaultsKey = "scheduleEndpoint"
    private static let service = "cn.imnu.schedulefloat.session"
    private static let worker = KeychainWorker()
    static var isSessionStorageUnavailable: Bool { worker.hasTimedOut }

    static func sessionData() async -> Data? {
        await worker.perform(fallback: nil as Data?) {
            var query = keychainQuery()
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
            return result as? Data
        }
    }

    @discardableResult
    static func saveSessionData(_ data: Data) async -> Bool {
        await worker.perform(fallback: false) {
            writeSessionData(data, allowInteraction: false)
        }
    }

    static func requestPermissionAndSaveSessionData(_ data: Data) async -> Bool {
        await worker.performInteractive {
            var query = keychainQuery(allowInteraction: true)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var existing: CFTypeRef?
            let access = SecItemCopyMatching(query as CFDictionary, &existing)
            guard access == errSecSuccess || access == errSecItemNotFound else { return false }
            return writeSessionData(data, allowInteraction: true)
        }
    }

    private static func writeSessionData(_ data: Data, allowInteraction: Bool) -> Bool {
        let query = keychainQuery(allowInteraction: allowInteraction)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        // Never delete an inaccessible item or loosen its access policy.
        guard status == errSecItemNotFound else { return false }
        var item = keychainQuery(allowInteraction: allowInteraction)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "教务悬浮助手 · 官网会话"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func deleteSessionData() async -> Bool {
        await worker.perform(fallback: false) {
            let status = SecItemDelete(keychainQuery() as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
    }

    private static func keychainQuery(allowInteraction: Bool = false) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "official-session",
                kSecUseAuthenticationContext as String: context]
        if !allowInteraction { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        return query
    }

    static func scheduleEndpoint() -> String? {
        UserDefaults.standard.string(forKey: endpointDefaultsKey)
    }

    static func saveScheduleEndpoint(_ endpoint: String) throws {
        UserDefaults.standard.set(endpoint, forKey: endpointDefaultsKey)
    }

    static func deleteScheduleEndpoint() {
        UserDefaults.standard.removeObject(forKey: endpointDefaultsKey)
    }
}
