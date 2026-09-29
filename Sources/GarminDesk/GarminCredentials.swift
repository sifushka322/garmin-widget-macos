import Foundation
import Security
import LocalAuthentication

struct GarminCredentials: Codable {
    let username: String
    let password: String
}

protocol GarminCredentialStore {
    func load() throws -> GarminCredentials?
    func save(_ credentials: GarminCredentials) throws
    func delete() throws
}

/// Host-only, device-local Keychain storage. Never copied to preferences,
/// diagnostics, the widget snapshot or iCloud Keychain.
struct GarminKeychain: GarminCredentialStore {
    struct Failure: Error { let status: OSStatus }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.mikhail.garmindesk",
         kSecAttrAccount as String: "garmin-auto-login",
         kSecAttrSynchronizable as String: false]
    }

    func load() throws -> GarminCredentials? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Background refresh must not interrupt the user with a Keychain prompt.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
        return try JSONDecoder().decode(GarminCredentials.self, from: data)
    }

    func save(_ credentials: GarminCredentials) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(credentials),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure(status: added) }
        } else if status != errSecSuccess { throw Failure(status: status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}

/// One password submission per connection attempt. A rejected password or MFA
/// leaves the normal Garmin window available, never a background retry loop.
struct GarminAutoLoginPolicy {
    private(set) var attempted = false
    mutating func reset() { attempted = false }
    mutating func begin() -> Bool {
        guard !attempted else { return false }
        attempted = true
        return true
    }
    static func allows(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil else { return false }
        // Saved passwords belong only to the SSO service, not every Garmin host.
        return url.host?.lowercased() == "sso.garmin.com"
    }
}
