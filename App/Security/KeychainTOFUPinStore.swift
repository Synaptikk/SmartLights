import Foundation
import LightCore
import NetKit
import Security

/// Keychain-backed `TOFUPinStore` (NetKit). Holds the SHA-256 leaf-certificate pins of Hue
/// bridges that still present self-signed certificates, keyed by bridge id, so a pin taken on
/// first use survives relaunches and a later certificate swap is detected (`.mismatch`).
///
/// - One generic-password item per identifier: service `com.sinap.smartlights.tofu`, account =
///   lower-cased identifier, data = JSON `CertificatePin`. Pins are not secrets, but the Keychain
///   keeps them tamper-resistant and shared with the extensions through the access group.
/// - The access group defaults to the app's keychain access group from the entitlements
///   (`$(AppIdentifierPrefix)com.sinap.smartlights`, see `KeychainAccessGroup`).
/// - `verifyOrPin` is atomic through actor isolation. Reads are cached for the process lifetime.
actor KeychainTOFUPinStore: TOFUPinStore {
    static let service = "com.sinap.smartlights.tofu"

    let accessGroup: String?
    private var cache: [String: CertificatePin] = [:]
    private let log = Log(package: "app", category: "tofu")

    init(accessGroup: String? = KeychainAccessGroup.appDefault) {
        self.accessGroup = accessGroup
    }

    func pin(for identifier: String) -> CertificatePin? {
        let key = identifier.lowercased()
        if let cached = cache[key] { return cached }
        guard let pin = read(key) else { return nil }
        cache[key] = pin
        return pin
    }

    func setPin(_ pin: CertificatePin, for identifier: String) {
        let key = identifier.lowercased()
        cache[key] = pin
        write(pin, for: key)
    }

    func removePin(for identifier: String) {
        let key = identifier.lowercased()
        cache[key] = nil
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            log.error("Keychain delete of certificate pin for \(key) failed (\(status))")
        }
    }

    func verifyOrPin(sha256: Data, for identifier: String) -> TOFUResult {
        if let existing = pin(for: identifier) {
            return existing.sha256 == sha256 ? .matched : .mismatch(pinned: existing)
        }
        guard let pin = CertificatePin(sha256: sha256) else {
            // Malformed fingerprint: never pin it, never trust it.
            return .mismatch(pinned: CertificatePin(sha256: Data(repeating: 0, count: 32))!)
        }
        setPin(pin, for: identifier)
        log.notice("Pinned certificate for \(identifier.lowercased()) on first use")
        return .pinnedOnFirstUse
    }

    // MARK: Keychain

    private func baseQuery(_ key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private func read(_ key: String) -> CertificatePin? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return try? JSONDecoder().decode(CertificatePin.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            log.error("Keychain read of certificate pin for \(key) failed (\(status))")
            return nil
        }
    }

    private func write(_ pin: CertificatePin, for key: String) {
        guard let data = try? JSONEncoder().encode(pin) else { return }
        let query = baseQuery(key)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            // The pin still applies for this process (cache); it is re-pinned after a relaunch.
            log.error("Keychain write of certificate pin for \(key) failed (\(status))")
        }
    }
}

/// Resolves the app's keychain access group as granted by the entitlements.
enum KeychainAccessGroup {
    /// The default access group the system assigns to this app's items: the first entry of
    /// `keychain-access-groups` (`<TeamID>.com.sinap.smartlights`) in signed builds. nil if it
    /// cannot be determined (then items use the default group implicitly, which is the same).
    static let appDefault: String? = resolve()

    private static func resolve() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.sinap.smartlights.accessgroup",
            kSecAttrAccount as String: "probe",
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            var add = query
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, &result)
        }
        guard status == errSecSuccess, let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrAccessGroup as String] as? String
    }
}
