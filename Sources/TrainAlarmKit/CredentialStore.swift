import Foundation
import Security

/// Persists the Můj vlak credentials as a single generic-password item in the login Keychain.
public enum CredentialStore {
    private static let service = "cz.trainalarm.ceskedrahy"
    private static let account = "default"

    private static var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    public static func load() -> Credentials? {
        var item: CFTypeRef?
        var request = query
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    public static func save(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        delete()
        var item = query
        item[kSecValueData] = data
        item[kSecAttrLabel] = "TrainAlarm – Můj vlak"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    public static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
