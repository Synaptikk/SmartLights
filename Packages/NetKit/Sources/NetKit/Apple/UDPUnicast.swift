#if canImport(Network)
import Foundation
@preconcurrency import Network

public enum UDPUnicastError: Error, Sendable, Equatable {
    case invalidPort
    /// The user denied Local Network access (`NWPath.unsatisfiedReason == .localNetworkDenied`).
    case localNetworkDenied
    case timedOut
    case network(String)
    case noData
}

/// One-shot UDP request/response over `NWConnection` (unicast does not need the multicast
/// entitlement). Suitable for WiZ `getPilot`, LIFX `GetService` and sweep probes.
public enum UDPUnicast {
    /// Sends `payload` to `host:port` and returns the first datagram received back.
    /// Throws ``UDPUnicastError/timedOut`` after `timeout`, ``UDPUnicastError/localNetworkDenied``
    /// if Local Network access is denied, and `CancellationError` if the task is cancelled.
    public static func request(
        _ payload: Data,
        to host: String,
        port: UInt16,
        timeout: Duration = .seconds(1)
    ) async throws -> Data {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw UDPUnicastError.invalidPort }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        let gate = ResumeGate<Data>()
        let queue = DispatchQueue(label: "com.sinap.smartlights.netkit.unicast")

        connection.stateUpdateHandler = { [weak connection] state in
            switch state {
            case .ready:
                guard let connection else { return }
                connection.send(content: payload, completion: .contentProcessed { error in
                    if let error {
                        gate.resume(throwing: UDPUnicastError.network(error.localizedDescription))
                        return
                    }
                    connection.receiveMessage { data, _, _, error in
                        if let data, !data.isEmpty {
                            gate.resume(returning: data)
                        } else if let error {
                            gate.resume(throwing: UDPUnicastError.network(error.localizedDescription))
                        } else {
                            gate.resume(throwing: UDPUnicastError.noData)
                        }
                    }
                })
            case .waiting(let error):
                if connection?.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    gate.resume(throwing: UDPUnicastError.localNetworkDenied)
                } else if case .posix(let code) = error, code == .EACCES || code == .EPERM {
                    gate.resume(throwing: UDPUnicastError.localNetworkDenied)
                }
                // Otherwise keep waiting; the timeout decides.
            case .failed(let error):
                gate.resume(throwing: UDPUnicastError.network(error.localizedDescription))
            case .cancelled:
                gate.resume(throwing: CancellationError())
            default:
                break
            }
        }
        connection.start(queue: queue)
        defer { connection.cancel() }
        do {
            return try await gate.wait(timeout: timeout)
        } catch is NetTimeoutError {
            throw UDPUnicastError.timedOut
        }
    }

    /// Convenience for ``IPv4Addr`` hosts.
    public static func request(
        _ payload: Data,
        to host: IPv4Addr,
        port: UInt16,
        timeout: Duration = .seconds(1)
    ) async throws -> Data {
        try await request(payload, to: host.description, port: port, timeout: timeout)
    }
}
#endif
