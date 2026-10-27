#if canImport(Darwin)
import Foundation
import LightCore
import NetKit

/// `ws://host/rpc` via `URLSessionWebSocketTask`.
final class URLSessionShellyWebSocket: ShellyWebSocket, @unchecked Sendable {
    let messages: AsyncThrowingStream<String, any Error>
    private let continuation: AsyncThrowingStream<String, any Error>.Continuation
    private let task: URLSessionWebSocketTask
    private let session: URLSession

    init(host: String, port: Int) throws {
        guard let url = URL(string: "ws://\(host)\(port == 80 ? "" : ":\(port)")/rpc") else {
            throw LightCoreError.transport("invalid Shelly WebSocket URL for \(host)")
        }
        session = URLSession(configuration: .ephemeral)
        task = session.webSocketTask(with: url)
        (messages, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        task.resume()
        receive()
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let text)):
                self.continuation.yield(text)
                self.receive()
            case .success(.data(let data)):
                self.continuation.yield(String(decoding: data, as: UTF8.self))
                self.receive()
            case .success:
                self.receive()
            case .failure(let error):
                self.continuation.finish(throwing: LightCoreError.transport(error.localizedDescription))
            }
        }
    }

    func send(_ text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            throw LightCoreError.transport(error.localizedDescription)
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        continuation.finish()
    }
}

extension ShellyNetworkEnvironment {
    /// Real network: URLSession HTTP, Bonjour `_shelly._tcp` + `_http._tcp`, WebSocket notifications.
    public static var live: ShellyNetworkEnvironment {
        ShellyNetworkEnvironment(
            http: URLSessionShellyTransport(),
            browseBonjour: ShellyNetworkEnvironment.bonjourBrowser,
            sweepHosts: { SubnetSweeper.currentWiFiHosts().map(\.description) },
            openWebSocket: { host, port in try URLSessionShellyWebSocket(host: host, port: port) }
        )
    }

    #if canImport(Network)
    static let bonjourBrowser: (@Sendable () -> AsyncStream<ShellyBonjourHit>)? = {
        let (stream, continuation) = AsyncStream.makeStream(of: ShellyBonjourHit.self)
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                for type in ["_shelly._tcp", "_http._tcp"] {
                    group.addTask {
                        for await event in BonjourBrowser.browse(type: type) {
                            guard case .added(let service) = event else { continue }
                            // `_http._tcp` carries every web server on the LAN; keep Shelly names only.
                            if type == "_http._tcp", !service.name.lowercased().hasPrefix("shelly") { continue }
                            continuation.yield(ShellyBonjourHit(name: service.name, type: type, host: service.host,
                                                                port: service.port, txt: service.txt))
                        }
                    }
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
    #else
    static let bonjourBrowser: (@Sendable () -> AsyncStream<ShellyBonjourHit>)? = nil
    #endif
}

extension ShellyProvider {
    /// The provider wired to the real network and the Keychain.
    public static func live(secretStore: any SecretStore = KeychainSecretStore()) -> ShellyProvider {
        ShellyProvider(environment: .live, secretStore: secretStore)
    }
}
#endif
