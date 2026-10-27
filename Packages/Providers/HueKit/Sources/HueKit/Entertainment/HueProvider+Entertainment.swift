import Foundation
import HueCodec
import LightCore

/// Keys for the Entertainment DTLS handshake. `description` never shows the key.
public struct HueEntertainmentCredentials: Sendable, Hashable, CustomStringConvertible {
    public var host: String
    /// PSK identity: the `hue-application-key` (v1 `username`).
    public var identity: String
    /// The hex-decoded `clientkey` (16 bytes).
    public var psk: [UInt8]

    public init(host: String, identity: String, psk: [UInt8]) {
        self.host = host
        self.identity = identity
        self.psk = psk
    }

    public var description: String {
        "HueEntertainmentCredentials(host: \(host), identity: \(Log.redact(identity)), psk: <\(psk.count) bytes>)"
    }
}

/// Entertainment-specific failures. Messages never contain keys.
public enum HueEntertainmentError: Error, Sendable, Equatable, LocalizedError {
    /// The app has not shown (or the user has not accepted) the photosensitivity warning.
    case photosensitivityWarningNotAcknowledged
    /// No `clientkey` stored: the bridge was paired without `generateclientkey`; pair again.
    case missingClientKey(bridgeID: String)
    /// The stored `clientkey` is not hex.
    case invalidClientKey
    case unknownConfiguration(String)
    /// Another application is streaming to this area (and take-over was not requested).
    case areaInUse(String)
    /// The DTLS connection could not be opened or broke while streaming.
    case connectionFailed(String)
    /// The DTLS handshake did not complete in time (wrong key, or the bridge did not open UDP 2100).
    case handshakeTimedOut
    /// The user denied Local Network access.
    case localNetworkDenied
    /// `start()` while the session is already starting or streaming.
    case alreadyStarted
    /// DTLS is not available on this platform (Linux builds).
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case .photosensitivityWarningNotAcknowledged:
            "Show the photosensitivity warning and get the user's consent before streaming light effects"
        case .missingClientKey(let id): "Hue Bridge \(id) was paired without an Entertainment key; pair it again"
        case .invalidClientKey: "The stored Hue Entertainment key is invalid; pair the bridge again"
        case .unknownConfiguration(let id): "Unknown Hue Entertainment area \(id)"
        case .areaInUse(let id): "Another app is already streaming to Hue Entertainment area \(id)"
        case .connectionFailed(let why): "Hue Entertainment connection failed: \(why)"
        case .handshakeTimedOut: "The Hue Bridge did not accept the Entertainment connection in time"
        case .localNetworkDenied: "Local Network access is turned off for SmartLights"
        case .alreadyStarted: "The Hue Entertainment session is already running"
        case .unsupportedPlatform: "Hue Entertainment streaming needs iOS or macOS"
        }
    }
}

// MARK: - CLIP v2 entertainment_configuration

extension HueProvider {
    /// `GET /clip/v2/resource/entertainment_configuration`.
    public func entertainmentConfigurations(bridgeID: String) async throws -> [HueEntertainmentConfiguration] {
        let data = try await clip(
            bridgeID.uppercased(), method: "GET", path: "/clip/v2/resource/\(HueResourceType.entertainmentConfiguration)")
        return try Self.decodeConfigurations(data)
    }

    /// `GET /clip/v2/resource/entertainment_configuration/{id}`.
    public func entertainmentConfiguration(bridgeID: String, id: String) async throws -> HueEntertainmentConfiguration {
        let data = try await clip(
            bridgeID.uppercased(), method: "GET", path: "/clip/v2/resource/\(HueResourceType.entertainmentConfiguration)/\(id)")
        guard let config = try Self.decodeConfigurations(data).first(where: { $0.id == id }) else {
            throw HueEntertainmentError.unknownConfiguration(id)
        }
        return config
    }

    /// `PUT .../entertainment_configuration/{id}` `{"action":"start"}`: the bridge opens DTLS on UDP 2100.
    public func startEntertainment(bridgeID: String, configurationID: String) async throws {
        try await clip(
            bridgeID.uppercased(), method: "PUT",
            path: "/clip/v2/resource/\(HueResourceType.entertainmentConfiguration)/\(configurationID)",
            body: HueEntertainmentAction.start.jsonData())
    }

    /// `PUT .../entertainment_configuration/{id}` `{"action":"stop"}`: lights return to their previous state.
    public func stopEntertainment(bridgeID: String, configurationID: String) async throws {
        try await clip(
            bridgeID.uppercased(), method: "PUT",
            path: "/clip/v2/resource/\(HueResourceType.entertainmentConfiguration)/\(configurationID)",
            body: HueEntertainmentAction.stop.jsonData())
    }

    /// Host, PSK identity (application key) and hex-decoded PSK (`clientkey`) from `SecretStore`.
    public func entertainmentCredentials(bridgeID: String) async throws -> HueEntertainmentCredentials {
        let id = bridgeID.uppercased()
        guard let host = host(bridgeID: id) else { throw HueError.unknownBridge(id) }
        guard let appKey = try await secretString(Self.appKeySecret(bridgeID: id)), !appKey.isEmpty else {
            throw HueError.notPaired(bridgeID: id)
        }
        guard let clientKey = try await secretString(Self.clientKeySecret(bridgeID: id)), !clientKey.isEmpty else {
            throw HueEntertainmentError.missingClientKey(bridgeID: id)
        }
        guard let psk = HueClientKey.psk(fromHex: clientKey) else { throw HueEntertainmentError.invalidClientKey }
        return HueEntertainmentCredentials(host: host, identity: appKey, psk: psk)
    }

    private static func decodeConfigurations(_ data: Data) throws -> [HueEntertainmentConfiguration] {
        do {
            let envelope = try JSONDecoder().decode(
                ResourceEnvelope<LossyArray<HueEntertainmentConfiguration>>.self, from: data)
            return envelope.data?.elements ?? []
        } catch {
            throw HueError.invalidResponse("entertainment_configuration: \(error)")
        }
    }
}
