import Foundation

/// Persistence for paired devices, accounts and the last-known light list (for offline UI).
/// Never stores secrets (see `SecretStore`). Devices are keyed by brand + stable id.
public protocol DeviceStore: Sendable {
    func pairedDevices() async throws -> [PairedDevice]
    /// Insert or replace by `PairedDevice.storeKey`.
    func save(_ device: PairedDevice) async throws
    /// Removes the device and its cached lights.
    func removeDevice(brand: Brand, id: String) async throws

    func accounts() async throws -> [ProviderAccount]
    /// Insert or replace by `ProviderAccount.id`.
    func save(_ account: ProviderAccount) async throws
    func removeAccount(id: String) async throws

    func cachedLights() async throws -> [Light]
    /// Insert or replace each light by id.
    func cacheLights(_ lights: [Light]) async throws

    func removeAll() async throws
}

/// On-disk snapshot used by `JSONFileDeviceStore`.
public struct DeviceStoreSnapshot: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var devices: [PairedDevice]
    public var accounts: [ProviderAccount]
    public var lights: [Light]

    public init(version: Int = DeviceStoreSnapshot.currentVersion, devices: [PairedDevice] = [], accounts: [ProviderAccount] = [], lights: [Light] = []) {
        self.version = version
        self.devices = devices
        self.accounts = accounts
        self.lights = lights
    }
}

/// Linux-safe `DeviceStore` writing one JSON file atomically. Used in tests, on Linux and as
/// the fallback until the SwiftData store (app target, T1.6) exists.
public actor JSONFileDeviceStore: DeviceStore {
    public nonisolated let fileURL: URL
    private var cache: DeviceStoreSnapshot?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    private func load() throws -> DeviceStoreSnapshot {
        if let cache { return cache }
        let snapshot: DeviceStoreSnapshot
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                snapshot = try JSONDecoder().decode(DeviceStoreSnapshot.self, from: data)
            } catch {
                throw LightCoreError.storage("cannot read \(fileURL.lastPathComponent): \(error)")
            }
        } else {
            snapshot = DeviceStoreSnapshot()
        }
        cache = snapshot
        return snapshot
    }

    private func write(_ snapshot: DeviceStoreSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            throw LightCoreError.storage("cannot write \(fileURL.lastPathComponent): \(error)")
        }
        cache = snapshot
    }

    private func mutate(_ body: (inout DeviceStoreSnapshot) -> Void) throws {
        var snapshot = try load()
        body(&snapshot)
        try write(snapshot)
    }

    public func pairedDevices() throws -> [PairedDevice] { try load().devices }

    public func save(_ device: PairedDevice) throws {
        try mutate { s in
            if let i = s.devices.firstIndex(where: { $0.storeKey == device.storeKey }) {
                s.devices[i] = device
            } else {
                s.devices.append(device)
            }
        }
    }

    public func removeDevice(brand: Brand, id: String) throws {
        try mutate { s in
            let removed = s.devices.filter { $0.brand == brand && $0.id == id }
            let lightIDs = Set(removed.flatMap(\.lightIDs))
            s.devices.removeAll { $0.brand == brand && $0.id == id }
            s.lights.removeAll { lightIDs.contains($0.id) }
        }
    }

    public func accounts() throws -> [ProviderAccount] { try load().accounts }

    public func save(_ account: ProviderAccount) throws {
        try mutate { s in
            if let i = s.accounts.firstIndex(where: { $0.id == account.id }) {
                s.accounts[i] = account
            } else {
                s.accounts.append(account)
            }
        }
    }

    public func removeAccount(id: String) throws {
        try mutate { s in s.accounts.removeAll { $0.id == id } }
    }

    public func cachedLights() throws -> [Light] { try load().lights }

    public func cacheLights(_ lights: [Light]) throws {
        try mutate { s in
            for light in lights {
                if let i = s.lights.firstIndex(where: { $0.id == light.id }) {
                    s.lights[i] = light
                } else {
                    s.lights.append(light)
                }
            }
        }
    }

    public func removeAll() throws {
        try write(DeviceStoreSnapshot())
    }
}

#if canImport(SwiftData)
/// Stub for the SwiftData-backed store (D10). The real implementation lives in the app target
/// (T1.6, `@Model` types need the app's ModelContainer). Until then it forwards to a JSON file
/// so the app can already depend on this type name.
public actor SwiftDataDeviceStore: DeviceStore {
    private let fallback: JSONFileDeviceStore

    public init(fallbackFileURL: URL) {
        fallback = JSONFileDeviceStore(fileURL: fallbackFileURL)
    }

    public func pairedDevices() async throws -> [PairedDevice] { try await fallback.pairedDevices() }
    public func save(_ device: PairedDevice) async throws { try await fallback.save(device) }
    public func removeDevice(brand: Brand, id: String) async throws { try await fallback.removeDevice(brand: brand, id: id) }
    public func accounts() async throws -> [ProviderAccount] { try await fallback.accounts() }
    public func save(_ account: ProviderAccount) async throws { try await fallback.save(account) }
    public func removeAccount(id: String) async throws { try await fallback.removeAccount(id: id) }
    public func cachedLights() async throws -> [Light] { try await fallback.cachedLights() }
    public func cacheLights(_ lights: [Light]) async throws { try await fallback.cacheLights(lights) }
    public func removeAll() async throws { try await fallback.removeAll() }
}
#endif
