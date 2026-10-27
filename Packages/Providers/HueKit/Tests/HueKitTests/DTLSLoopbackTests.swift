#if canImport(Network)
import Foundation
import HueCodec
import LightCore
@preconcurrency import Network
import Synchronization
import Testing

@testable import HueKit

/// DTLS 1.2 PSK echo server on the loopback interface (Network.framework `NWListener`), standing
/// in for the bridge's UDP 2100. swift-nio-ssl has no DTLS, so the server uses the same
/// `NWDTLSConnector.parameters` as the client.
final class DTLSPSKEchoServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.sinap.smartlights.huekit.tests.dtls-server")
    private let received = Mutex<[Data]>([])

    init(identity: String, psk: [UInt8]) throws {
        let parameters = NWDTLSConnector.parameters(identity: identity, psk: psk)
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
    }

    var datagrams: [Data] { received.withLock { $0 } }

    /// Starts listening; returns the port.
    func start() async throws -> UInt16 {
        let ready = OnceGate<UInt16>()
        listener.stateUpdateHandler = { [listener] state in
            switch state {
            case .ready:
                if let port = listener.port {
                    ready.resume(.success(port.rawValue))
                } else {
                    ready.resume(.failure(CancellationError()))
                }
            case .failed(let error): ready.resume(.failure(error))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self, queue] connection in
            connection.start(queue: queue)
            self?.echo(on: connection)
        }
        listener.start(queue: queue)
        return try await ready.wait(timeout: .seconds(5))
    }

    private func echo(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data, !data.isEmpty {
                self.received.withLock { $0.append(data) }
                connection.send(content: data, completion: .idempotent)
            }
            self.echo(on: connection)
        }
    }

    func stop() { listener.cancel() }
}

@Suite("DTLS-PSK loopback (Network.framework)", .serialized)
struct DTLSLoopbackTests {
    typealias M = MockTransport
    static let identity = M.appKey
    static let psk = HueEntertainmentSessionTests.psk

    @Test func handshakeSendAndEcho() async throws {
        let server = try DTLSPSKEchoServer(identity: Self.identity, psk: Self.psk)
        let port = try await server.start()
        defer { server.stop() }

        let channel = try await NWDTLSConnector().connect(
            host: "127.0.0.1", port: port, identity: Self.identity, psk: Self.psk, timeout: .seconds(5))
        let dtls = try #require(channel as? NWDTLSChannel)
        let frame = try HueStreamFrame(
            configurationID: HueEntertainmentSessionTests.area, sequence: 1, colorSpace: .rgb,
            channels: HueEntertainmentSessionTests.channels)

        try await channel.send(frame.data)
        let echo = try await dtls.receive()
        #expect(try HueStreamFrame(decoding: echo) == frame)
        #expect(server.datagrams == [frame.data])
        await channel.close()
    }

    @Test func wrongKeyFailsTheHandshake() async throws {
        let server = try DTLSPSKEchoServer(identity: Self.identity, psk: Self.psk)
        let port = try await server.start()
        defer { server.stop() }

        var wrong = Self.psk
        wrong[0] ^= 0xFF
        await #expect(throws: (any Error).self) {
            let channel = try await NWDTLSConnector().connect(
                host: "127.0.0.1", port: port, identity: Self.identity, psk: wrong, timeout: .seconds(3))
            // Some stacks only notice on first use; make the failure observable.
            try await channel.send(Data([0]))
            _ = try await (channel as? NWDTLSChannel)?.receive()
        }
        #expect(server.datagrams.isEmpty)
    }

    @Test func sessionStreamsHueStreamFramesOverDTLS() async throws {
        let server = try DTLSPSKEchoServer(identity: Self.identity, psk: Self.psk)
        let port = try await server.start()
        defer { server.stop() }

        let transport = HueEntertainmentSessionTests.transport()
        let provider = try await HueEntertainmentSessionTests.provider(transport, host: "127.0.0.1")
        var configuration = HueEntertainmentSession.Configuration()
        configuration.photosensitivityWarningAcknowledged = true
        configuration.port = port
        let session = HueEntertainmentSession(
            provider: provider, bridgeID: M.bridgeID, configurationID: HueEntertainmentSessionTests.area,
            configuration: configuration)

        await session.setChannels(HueEntertainmentSessionTests.channels)
        try await session.start()
        let gotFrames = await eventually(timeout: .seconds(5)) { server.datagrams.count >= 10 }
        await session.stop()

        #expect(gotFrames)
        let frames = try server.datagrams.map { try HueStreamFrame(decoding: $0) }
        #expect(frames.allSatisfy { $0.configurationID == HueEntertainmentSessionTests.area })
        #expect(frames.allSatisfy { $0.channels == HueEntertainmentSessionTests.channels })
        #expect(try HueEntertainmentSessionTests.actions(transport) == ["start", "stop"])
    }
}
#endif
