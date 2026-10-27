#if canImport(Darwin)
import Foundation
import LightCore
import NetKit
import TwinklyCodec

/// `TwinklyTransport` on URLSession (plain HTTP, one connection per host: the ESP-based
/// controllers handle one at a time) and NetKit's BSD `UDPSocket` for UDP 5555 discovery.
/// Unicast works with Local Network permission alone; broadcast sends fail with `EACCES`
/// without the multicast entitlement and are skipped (the provider then sweeps the /24).
public final class URLSessionTwinklyTransport: TwinklyTransport {
    private let session: URLSession
    private let interfaceName: String?

    public init(interfaceName: String? = InterfaceInfo.currentWiFi()?.name) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
        self.interfaceName = interfaceName
    }

    deinit { session.invalidateAndCancel() }

    public func send(_ request: TwinklyHTTPRequest) async throws -> TwinklyHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = request.timeout.timeInterval
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw TwinklyTransportError.connectionFailed("not an HTTP response")
            }
            return TwinklyHTTPResponse(status: http.statusCode, body: data)
        } catch let error as URLError {
            switch error.code {
            case .cancelled where Task.isCancelled: throw CancellationError()
            case .timedOut: throw TwinklyTransportError.timedOut
            default: throw TwinklyTransportError.connectionFailed(error.localizedDescription)
            }
        }
    }

    public func probeUDP(_ payload: Data, destinations: [String], port: UInt16, window: Duration) -> AsyncStream<TwinklyDatagram> {
        let (stream, continuation) = AsyncStream.makeStream(of: TwinklyDatagram.self, bufferingPolicy: .bufferingNewest(512))
        let interfaceName = self.interfaceName
        let task = Task {
            let socket: UDPSocket
            do {
                socket = try UDPSocket(options: UDPSocket.Options(interfaceName: interfaceName, broadcast: true))
            } catch {
                Log(package: "twinklykit", category: "discovery").notice("UDP socket failed: \(error)")
                continuation.finish()
                return
            }
            defer { socket.close() }
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await datagram in socket.datagrams {
                        continuation.yield(TwinklyDatagram(data: datagram.data, host: datagram.host.description, port: datagram.port))
                    }
                }
                group.addTask {
                    for destination in destinations {
                        let parsed = TwinklyEndpoint.parse(destination)
                        guard let address = IPv4Addr(parsed.host) else { continue }
                        // EACCES on broadcast without the multicast entitlement: skip that destination.
                        try? await socket.send(payload, to: address, port: parsed.port.map { UInt16(clamping: $0) } ?? port)
                    }
                    try? await Task.sleep(for: window)
                    socket.close()
                }
                await group.waitForAll()
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func broadcastAddresses() -> [String] {
        var out: [String] = []
        if let directed = InterfaceInfo.currentWiFi()?.directedBroadcast { out.append(directed.description) }
        out.append(IPv4Addr.limitedBroadcast.description)
        return out
    }

    public func sweepHosts() -> [String] {
        SubnetSweeper.currentWiFiHosts().map(\.description)
    }
}

extension TwinklyProvider {
    /// Production provider: URLSession/UDP transport and the given secret store (Keychain in the app).
    public static func live(secrets: any SecretStore = KeychainSecretStore(), configuration: Configuration = Configuration()) -> TwinklyProvider {
        TwinklyProvider(secrets: secrets, transport: URLSessionTwinklyTransport(), configuration: configuration)
    }
}
#endif
