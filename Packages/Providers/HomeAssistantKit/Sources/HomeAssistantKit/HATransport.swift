import Foundation
import LightCore

/// One open WebSocket to Home Assistant (text frames only).
public protocol HAWebSocketConnection: AnyObject, Sendable {
    /// Sends one text frame.
    func send(_ text: String) async throws
    /// Waits for the next text frame. Throws when the connection is closed or fails.
    func receive() async throws -> String
    /// Idempotent; a pending `receive()` throws afterwards.
    func close()
}

/// A Home Assistant instance seen on the LAN (Bonjour `_home-assistant._tcp`).
public struct HADiscoveredInstance: Sendable, Hashable {
    /// Installation uuid (TXT `uuid`), if advertised.
    public var uuid: String?
    public var name: String
    /// Base URL (TXT `internal_url`/`base_url`, else `http://<host>:<port>`).
    public var baseURL: URL
    public var externalURL: URL?
    public var version: String?

    public init(uuid: String?, name: String, baseURL: URL, externalURL: URL? = nil, version: String? = nil) {
        self.uuid = uuid
        self.name = name
        self.baseURL = baseURL
        self.externalURL = externalURL
        self.version = version
    }
}

/// Everything network-specific the provider uses, so tests can swap in a fake server.
public protocol HAWebSocketTransport: Sendable {
    /// Opens a WebSocket to `url` (`ws(s)://host[:port]/api/websocket`).
    func connect(to url: URL) async throws -> any HAWebSocketConnection
    /// Bonjour browse for `_home-assistant._tcp`; finishes after `timeout`.
    func browse(timeout: Duration) -> AsyncStream<HADiscoveredInstance>
}

extension HAWebSocketTransport {
    public func browse(timeout: Duration) -> AsyncStream<HADiscoveredInstance> {
        AsyncStream { $0.finish() }
    }
}
