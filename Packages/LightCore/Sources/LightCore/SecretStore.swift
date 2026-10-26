import Foundation
#if canImport(Security)
import Security
#endif

/// Identifies one secret (app key, token, password, signing key). The key itself is not secret.
public struct SecretKey: Codable, Sendable, Hashable, CustomStringConvertible {
    public var brand: Brand
    /// Device or account the secret belongs to (Hue bridge id, AiDot account id, WiZ MAC).
    public var owner: String
    /// What the secret is ("appKey", "clientKey", "accessToken", "password").
    public var item: String

    public init(brand: Brand, owner: String, item: String) {
        self.brand = brand
        self.owner = owner
        self.item = item
    }

    /// Keychain `kSecAttrService`.
    public var service: String { "com.sinap.smartlights.\(brand.rawValue)" }
    /// Keychain `kSecAttrAccount`.
    public var account: String { "\(owner)/\(item)" }
    public var description: String { "\(service):\(account)" }
}

/// Secret storage. Keychain on Apple platforms (`KeychainSecretStore`), in-memory on Linux/tests.
/// Values must never be logged.
public protocol SecretStore: Sendable {
    func data(for key: SecretKey) async throws -> Data?
    func set(_ data: Data, for key: SecretKey) async throws
    func remove(_ key: SecretKey) async throws
}

extension SecretStore {
    public func string(for key: SecretKey) async throws -> String? {
        guard let data = try await data(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ string: String, for key: SecretKey) async throws {
        try await set(Data(string.utf8), for: key)
    }
}

/// Volatile `SecretStore` for Linux and tests.
public actor InMemorySecretStore: SecretStore {
    private var values: [SecretKey: Data]

    public init(_ initial: [SecretKey: Data] = [:]) {
        values = initial
    }

    public func data(for key: SecretKey) -> Data? { values[key] }
    public func set(_ data: Data, for key: SecretKey) { values[key] = data }
    public func remove(_ key: SecretKey) { values[key] = nil }
    /// Number of stored secrets (test helper).
    public var count: Int { values.count }
}

#if canImport(Security)
/// Keychain-backed `SecretStore` (generic passwords, accessible after first unlock so widgets
/// and intents can read while the device is locked). Pass the shared access group to share with
/// app extensions.
public struct KeychainSecretStore: SecretStore {
    public let accessGroup: String?

    public init(accessGroup: String? = nil) {
        self.accessGroup = accessGroup
    }

    private func baseQuery(_ key: SecretKey) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: key.service,
            kSecAttrAccount as String: key.account,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    public func data(for key: SecretKey) async throws -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw LightCoreError.storage("Keychain read failed (\(status)) for \(key)")
        }
    }

    public func set(_ data: Data, for key: SecretKey) async throws {
        let query = baseQuery(key)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw LightCoreError.storage("Keychain write failed (\(status)) for \(key)") }
    }

    public func remove(_ key: SecretKey) async throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LightCoreError.storage("Keychain delete failed (\(status)) for \(key)")
        }
    }
}
#endif
