import Foundation

/// Transport-level failures of a Yeelight TCP connection.
public enum YeelightTransportError: Error, Sendable, Equatable, CustomStringConvertible {
    /// TCP connection refused: the device is up but "LAN Control" is off (or the port is wrong).
    case connectionRefused
    /// Connect or request deadline elapsed.
    case timedOut
    /// No route / host down / not on the same network.
    case unreachable(String)
    /// Local Network access denied by the user (iOS privacy setting).
    case localNetworkDenied
    /// The connection closed while a request was outstanding.
    case connectionLost
    /// The session was shut down.
    case closed
    case other(String)

    public var description: String {
        switch self {
        case .connectionRefused: "connection refused (LAN Control off?)"
        case .timedOut: "timed out"
        case .unreachable(let s): "unreachable: \(s)"
        case .localNetworkDenied: "Local Network access denied"
        case .connectionLost: "connection lost"
        case .closed: "closed"
        case .other(let s): s
        }
    }
}

/// One open TCP connection to a device. Implementations: `NWYeelightConnector` (Network.framework)
/// in the app; socket- or memory-backed fakes in tests.
public protocol YeelightConnection: Sendable {
    /// Raw bytes received, in order. Finishes when the peer closes; throws on transport errors.
    var incoming: AsyncThrowingStream<Data, any Error> { get }
    /// Writes bytes (one or more complete request lines).
    func send(_ data: Data) async throws
    /// Closes the connection and finishes `incoming`. Idempotent.
    func close() async
}

/// Opens connections. Must throw `YeelightTransportError.connectionRefused` when the device refuses
/// the connection, so the provider can explain the LAN Control toggle.
public protocol YeelightConnector: Sendable {
    func connect(host: String, port: UInt16, timeout: Duration) async throws -> any YeelightConnection
}
