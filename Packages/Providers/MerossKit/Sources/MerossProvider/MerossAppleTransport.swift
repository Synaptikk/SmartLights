#if canImport(Network)
import Foundation
import LightCore
import MerossCodec
import NetKit
@preconcurrency import Network
import Synchronization

/// `POST /config` as raw HTTP/1.1 over `NWConnection` (one connection per request, `Connection: close`).
/// Avoids URLSession's App Transport Security checks for plain HTTP to LAN IPs; needs Local Network permission.
public struct NWMerossLocalTransport: MerossLocalTransport {
    public init() {}

    public func post(host: String, port: UInt16, body: Data, contentType: String, timeout: Duration) async throws -> (status: Int, body: Data) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw LightCoreError.transport("invalid port \(port)") }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = max(1, Int(timeout.seconds.rounded(.up)))
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: NWParameters(tls: nil, tcp: tcp))
        let exchange = HTTPExchange(connection: connection,
                                    request: MerossHTTP1.request(host: host, port: port, body: body, contentType: contentType))
        defer { connection.cancel() }
        return try await withTaskCancellationHandler {
            try await exchange.run(timeout: timeout)
        } onCancel: {
            connection.cancel()
        }
    }

    /// Hosts of the current Wi-Fi subnet (`/24` around the phone's address).
    public static func currentWiFiHosts() -> [String] {
        SubnetSweeper.currentWiFiHosts().map(\.description)
    }
}

/// One request/response exchange; callbacks run on a private queue and finish a `OnceGate`.
/// `@unchecked`: mutable state is behind `Mutex`/`OnceGate`; `NWConnection` is thread-safe.
private final class HTTPExchange: @unchecked Sendable {
    private let connection: NWConnection
    private let request: Data
    private let gate = OnceGate<(Int, Data)>()
    private let buffer = Mutex<Data>(Data())

    init(connection: NWConnection, request: Data) {
        self.connection = connection
        self.request = request
    }

    func run(timeout: Duration) async throws -> (status: Int, body: Data) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.connection.send(content: self.request, completion: .contentProcessed { error in
                    if let error { self.gate.resume(.failure(LightCoreError.transport(error.localizedDescription))) }
                })
                self.receive()
            case .waiting(let error):
                if self.connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    self.gate.resume(.failure(LightCoreError.unreachable("Local Network access denied")))
                } else {
                    self.gate.resume(.failure(LightCoreError.unreachable(error.localizedDescription)))
                }
            case .failed(let error):
                self.gate.resume(.failure(LightCoreError.unreachable(error.localizedDescription)))
            case .cancelled:
                self.gate.resume(.failure(CancellationError()))
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "com.sinap.smartlights.merosskit.http"))
        let (status, body) = try await gate.wait(timeout: timeout)
        return (status, body)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let snapshot: Data = self.buffer.withLock { b in
                if let data { b.append(data) }
                return b
            }
            do {
                if let response = try MerossHTTP1.parse(snapshot, complete: isComplete || error != nil) {
                    self.gate.resume(.success((response.status, response.body)))
                    return
                }
            } catch {
                self.gate.resume(.failure(LightCoreError.protocolError("bad HTTP response from Meross device")))
                return
            }
            if let error {
                self.gate.resume(.failure(LightCoreError.transport(error.localizedDescription)))
            } else if isComplete {
                self.gate.resume(.failure(LightCoreError.transport("connection closed")))
            } else {
                self.receive()
            }
        }
    }
}
#endif
