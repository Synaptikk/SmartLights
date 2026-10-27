#if canImport(Darwin)
import Foundation
import HomeAssistantCodec
import NetKit

/// Production transport: `URLSessionWebSocketTask` plus Bonjour (`_home-assistant._tcp`).
///
/// The app's Info.plist must list `_home-assistant._tcp` in `NSBonjourServices` for discovery;
/// without it the browse reports policy-denied and finishes (manual URL entry still works).
public final class URLSessionHATransport: HAWebSocketTransport {
    private let session: URLSession
    /// `get_states` on a large install is several MB; URLSession's default limit is 1 MiB.
    public let maximumMessageSize: Int

    public init(configuration: URLSessionConfiguration = .default, maximumMessageSize: Int = 64 * 1024 * 1024) {
        let config = (configuration.copy() as? URLSessionConfiguration) ?? .default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
        self.maximumMessageSize = maximumMessageSize
    }

    public func connect(to url: URL) async throws -> any HAWebSocketConnection {
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = maximumMessageSize
        task.resume()
        return URLSessionHAConnection(task)
    }

    public func browse(timeout: Duration) -> AsyncStream<HADiscoveredInstance> {
        let (stream, continuation) = AsyncStream<HADiscoveredInstance>.makeStream()
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await event in BonjourBrowser.browse(type: "_home-assistant._tcp") {
                        guard case .added(let service) = event, let instance = Self.instance(from: service) else { continue }
                        continuation.yield(instance)
                    }
                }
                group.addTask { try? await Task.sleep(for: timeout) }
                await group.next()
                group.cancelAll()
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// TXT keys published by HA's zeroconf integration: `uuid`, `location_name`, `version`,
    /// `internal_url`, `external_url`, `base_url`.
    static func instance(from service: BonjourService) -> HADiscoveredInstance? {
        let txt = service.txt
        let base = txt["internal_url"].flatMap(HAURL.normalize) ?? txt["base_url"].flatMap(HAURL.normalize)
            ?? service.host.flatMap { host in
                let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
                return HAURL.normalize("http://\(h):\(service.port.map { Int($0) } ?? HAURL.defaultPort)")
            }
        guard let base else { return nil }
        return HADiscoveredInstance(
            uuid: txt["uuid"].flatMap { $0.isEmpty ? nil : $0 },
            name: txt["location_name"] ?? service.name,
            baseURL: base,
            externalURL: txt["external_url"].flatMap(HAURL.normalize),
            version: txt["version"])
    }
}

/// `URLSessionWebSocketTask` adapter (the task is thread-safe; it is the only stored state).
final class URLSessionHAConnection: HAWebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(_ task: URLSessionWebSocketTask) { self.task = task }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text): return text
        case .data(let data): return String(decoding: data, as: UTF8.self)
        @unknown default: return ""
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
#endif
