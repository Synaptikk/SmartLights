#if canImport(Network)
import Foundation
import HueCodec
@preconcurrency import Network
import Security
import Synchronization

/// DTLS 1.2 with a pre-shared key over Network.framework, as the Hue bridge requires on UDP 2100:
/// PSK identity = application key, PSK = hex-decoded `clientkey`, cipher suite
/// `TLS_PSK_WITH_AES_128_GCM_SHA256` (0x00A8). Same approach as adeze/HueEntertainmentKit
/// (`NIOTSDTLSTransport`), without the swift-nio layer.
public struct NWDTLSConnector: HueDTLSConnector {
    /// `TLS_PSK_WITH_AES_128_GCM_SHA256`.
    public static let cipherSuite: UInt16 = 0x00A8

    public init() {}

    /// DTLS-PSK parameters. The same parameters work for an `NWListener` (used by the loopback test).
    public static func parameters(identity: String, psk: [UInt8]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .DTLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .DTLSv12)
        if let suite = tls_ciphersuite_t(rawValue: cipherSuite) {
            sec_protocol_options_append_tls_ciphersuite(options, suite)
        }
        let key = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let keyIdentity = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, key as dispatch_data_t, keyIdentity as dispatch_data_t)
        return NWParameters(dtls: tls, udp: NWProtocolUDP.Options())
    }

    public func connect(host: String, port: UInt16, identity: String, psk: [UInt8], timeout: Duration) async throws
        -> any HueDatagramChannel
    {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw HueEntertainmentError.connectionFailed("invalid port \(port)")
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: nwPort, using: Self.parameters(identity: identity, psk: psk))
        let ready = OnceGate<Void>()
        connection.stateUpdateHandler = { [weak connection] state in
            switch state {
            case .ready:
                ready.resume(.success(()))
            case .waiting(let error):
                if connection?.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    ready.resume(.failure(HueEntertainmentError.localNetworkDenied))
                } else if case .tls = error {
                    ready.resume(.failure(HueEntertainmentError.connectionFailed(error.localizedDescription)))
                }
                // Otherwise keep waiting; the handshake timeout decides.
            case .failed(let error):
                ready.resume(.failure(HueEntertainmentError.connectionFailed(error.localizedDescription)))
            case .cancelled:
                ready.resume(.failure(CancellationError()))
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "com.sinap.smartlights.huekit.dtls"))
        do {
            try await ready.wait(timeout: timeout)
        } catch {
            connection.stateUpdateHandler = nil
            connection.cancel()
            throw error
        }
        return NWDTLSChannel(connection: connection)
    }
}

/// An established DTLS connection. Sends fail once the connection has failed.
final class NWDTLSChannel: HueDatagramChannel, @unchecked Sendable {
    let connection: NWConnection

    init(connection: NWConnection) { self.connection = connection }

    func send(_ datagram: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: datagram, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: HueEntertainmentError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Next datagram from the peer (the bridge sends none; the loopback test echoes).
    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            connection.receiveMessage { data, _, _, error in
                if let error {
                    continuation.resume(throwing: HueEntertainmentError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }

    func close() async {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}

/// Resolves once; `wait` throws `HueEntertainmentError.handshakeTimedOut` after `timeout`.
final class OnceGate<T: Sendable>: Sendable {
    private struct State {
        var result: Result<T, any Error>?
        var waiter: CheckedContinuation<T, any Error>?
    }

    private let state = Mutex(State())

    func resume(_ result: Result<T, any Error>) {
        let waiter = state.withLock { s -> CheckedContinuation<T, any Error>? in
            guard s.result == nil else { return nil }
            s.result = result
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume(with: result)
    }

    func wait(timeout: Duration) async throws -> T {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.resume(.failure(HueEntertainmentError.handshakeTimedOut))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                let done = state.withLock { s -> Result<T, any Error>? in
                    if let result = s.result { return result }
                    s.waiter = continuation
                    return nil
                }
                if let done { continuation.resume(with: done) }
            }
        } onCancel: {
            resume(.failure(CancellationError()))
        }
    }
}

extension HueEntertainmentSession {
    /// A session that streams over Network.framework DTLS (`NWDTLSConnector`).
    public init(
        provider: HueProvider, bridgeID: String, configurationID: String, configuration: Configuration = Configuration()
    ) {
        self.init(
            provider: provider, bridgeID: bridgeID, configurationID: configurationID, connector: NWDTLSConnector(),
            configuration: configuration)
    }
}
#endif
