#if canImport(Network)
import Foundation
import LightCore
import NetKit
@preconcurrency import Network

/// TCP via `NWConnection` (no multicast entitlement needed; Local Network permission is).
public struct NWTuyaTCPConnector: TuyaTCPConnector {
    public init() {}

    public func connect(host: String, port: UInt16, timeout: Duration) async throws -> any TuyaTCPConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw LightCoreError.transport("invalid port \(port)") }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = max(1, Int(timeout.timeInterval.rounded(.up)))
        let parameters = NWParameters(tls: nil, tcp: tcp)
        let nw = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        let connection = NWTuyaConnection(nw)
        let ready = OnceGate<Void>()
        nw.stateUpdateHandler = { [weak nw] state in
            switch state {
            case .ready:
                ready.resume(.success(()))
            case .waiting(let error):
                if nw?.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    ready.resume(.failure(LightCoreError.unreachable("Local Network access denied")))
                } else if case .posix(let code) = error, code == .EACCES || code == .EPERM {
                    ready.resume(.failure(LightCoreError.unreachable("Local Network access denied")))
                } else {
                    ready.resume(.failure(LightCoreError.unreachable("\(host):\(port) \(error.localizedDescription)")))
                }
            case .failed(let error):
                ready.resume(.failure(LightCoreError.unreachable("\(host):\(port) \(error.localizedDescription)")))
                connection.finish(error)
            case .cancelled:
                ready.resume(.failure(CancellationError()))
                connection.finish(nil)
            default:
                break
            }
        }
        nw.start(queue: DispatchQueue(label: "com.sinap.smartlights.tuyakit.tcp"))
        do {
            try await ready.wait(timeout: timeout)
        } catch {
            nw.cancel()
            throw error
        }
        connection.startReceiving()
        return connection
    }
}

final class NWTuyaConnection: TuyaTCPConnection, @unchecked Sendable {
    let incoming: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let connection: NWConnection

    init(_ connection: NWConnection) {
        self.connection = connection
        (incoming, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
    }

    func startReceiving() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.continuation.yield(data) }
            if let error {
                self.finish(error)
            } else if isComplete {
                self.finish(nil)
            } else {
                self.startReceiving()
            }
        }
    }

    func finish(_ error: (any Error)?) {
        if let error { continuation.finish(throwing: LightCoreError.transport(error.localizedDescription)) } else { continuation.finish() }
    }

    func send(_ data: Data) async throws {
        let gate = OnceGate<Void>()
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                gate.resume(.failure(LightCoreError.transport(error.localizedDescription)))
            } else {
                gate.resume(.success(()))
            }
        })
        try await gate.wait(timeout: .seconds(10))
    }

    func close() {
        connection.cancel()
        continuation.finish()
    }
}

/// UDP via NetKit BSD sockets: listening on 6666/6667 for announcements (needs the multicast
/// entitlement on iOS to receive broadcasts) and the `REQ_DEVINFO` broadcast.
public struct NetKitTuyaDatagramTransport: TuyaDatagramTransport {
    public init() {}

    public func listen(ports: [UInt16], duration: Duration) -> AsyncStream<TuyaDatagram> {
        AsyncStream { continuation in
            let task = Task {
                let sockets = ports.compactMap { port in
                    try? UDPSocket(options: .init(localPort: port, broadcast: true, reuseAddress: true, reusePort: true,
                                                  maxDatagramSize: 4096))
                }
                defer { for s in sockets { s.close() } }
                guard !sockets.isEmpty else {
                    continuation.finish()
                    return
                }
                let timer = Task {
                    try? await Task.sleep(for: duration)
                    for s in sockets { s.close() }
                }
                await withTaskGroup(of: Void.self) { group in
                    for socket in sockets {
                        group.addTask {
                            for await datagram in socket.datagrams {
                                continuation.yield(TuyaDatagram(data: datagram.data, host: datagram.host.description))
                            }
                        }
                    }
                }
                timer.cancel()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func broadcast(_ payload: Data, port: UInt16) async {
        let wifi = InterfaceInfo.currentWiFi()
        guard let socket = try? UDPSocket(options: .init(interfaceName: wifi?.name, broadcast: true)) else { return }
        defer { socket.close() }
        var targets: [IPv4Addr] = [.limitedBroadcast]
        if let directed = wifi?.directedBroadcast, directed != .limitedBroadcast { targets.append(directed) }
        for target in targets { try? socket.sendNow(payload, to: target, port: port) }
    }

    public func localAddress() -> String? {
        InterfaceInfo.currentWiFi()?.address.description
    }

    public func sweepHosts() -> [String] {
        SubnetSweeper.currentWiFiHosts().map(\.description)
    }
}
#endif
