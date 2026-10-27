#if canImport(Network)
import Foundation
import LightCore
import NetKit
@preconcurrency import Network

/// TCP via `NWConnection` (Local Network permission needed, no multicast entitlement).
struct NWMagicHomeConnector {
    static func connect(host: String, port: UInt16, timeout: Duration) async throws -> any MagicHomeConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw LightCoreError.transport("invalid port \(port)") }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = max(1, Int(timeout.seconds.rounded(.up)))
        let parameters = NWParameters(tls: nil, tcp: tcp)
        let nw = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        let connection = NWMagicHomeConnection(nw)
        let ready = MagicHomeGate<Void>()
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
        // Network.framework delivers callbacks on a queue; everything else is async/await.
        nw.start(queue: DispatchQueue(label: "com.sinap.smartlights.magichomekit.tcp"))
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

final class NWMagicHomeConnection: MagicHomeConnection, @unchecked Sendable {
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
        let gate = MagicHomeGate<Void>()
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                gate.resume(.failure(LightCoreError.transport(error.localizedDescription)))
            } else {
                gate.resume(.success(()))
            }
        })
        try await gate.wait(timeout: .seconds(5))
    }

    func close() {
        connection.cancel()
        continuation.finish()
    }
}

extension MagicHomeNetworkEnvironment {
    /// Real network: NWConnection TCP, NetKit BSD-socket broadcast (multicast entitlement),
    /// `NWConnection` unicast for the sweep and manual hosts.
    public static var live: MagicHomeNetworkEnvironment {
        MagicHomeNetworkEnvironment(
            connect: { host, port, timeout in try await NWMagicHomeConnector.connect(host: host, port: port, timeout: timeout) },
            broadcast: { payload, port, listen in liveBroadcast(payload, port: port, listen: listen) },
            unicast: { payload, host, port, timeout in
                guard let data = try? await UDPUnicast.request(payload, to: host, port: port, timeout: timeout) else { return nil }
                return MagicHomeDatagram(data: data, host: host)
            },
            sweepHosts: { SubnetSweeper.currentWiFiHosts().map(\.description) }
        )
    }

    static func liveBroadcast(_ payload: Data, port: UInt16, listen: Duration) -> AsyncStream<MagicHomeDatagram> {
        AsyncStream { continuation in
            let task = Task {
                let wifi = InterfaceInfo.currentWiFi()
                guard let socket = try? UDPSocket(options: .init(interfaceName: wifi?.name, broadcast: true)) else {
                    continuation.finish()
                    return
                }
                defer { socket.close() }
                let directed = wifi?.directedBroadcast.flatMap { $0 == .limitedBroadcast ? nil : $0 }
                let targets: [IPv4Addr] = [.limitedBroadcast] + (directed.map { [$0] } ?? [])
                let sender = Task {
                    // flux_led repeats the probe; UDP broadcasts get lost.
                    for round in 0..<3 {
                        if round > 0 { try? await Task.sleep(for: .milliseconds(400)) }
                        if Task.isCancelled { return }
                        for target in targets { try? socket.sendNow(payload, to: target, port: port) }
                    }
                }
                let timer = Task {
                    try? await Task.sleep(for: listen)
                    socket.close()
                }
                for await datagram in socket.datagrams {
                    continuation.yield(MagicHomeDatagram(data: datagram.data, host: datagram.host.description))
                }
                sender.cancel()
                timer.cancel()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension MagicHomeProvider {
    /// The provider wired to the real network.
    public static func live() -> MagicHomeProvider {
        MagicHomeProvider(environment: .live)
    }
}
#endif
