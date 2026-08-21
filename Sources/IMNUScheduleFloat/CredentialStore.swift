import Foundation

enum CredentialStore {
    private static let endpointDefaultsKey = "scheduleEndpoint"

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
