import Foundation
import HueCodec
import LightCore
import Synchronization
import Testing

@testable import HueKit

/// Records datagrams; optionally fails every send.
final class FakeDatagramChannel: HueDatagramChannel {
    private let state = Mutex<(datagrams: [Data], closed: Bool, failSends: Bool)>(([], false, false))

    var datagrams: [Data] { state.withLock { $0.datagrams } }
    var isClosed: Bool { state.withLock { $0.closed } }
    func failSends() { state.withLock { $0.failSends = true } }

    func send(_ datagram: Data) async throws {
        let fail = state.withLock { s -> Bool in
            if s.failSends { return true }
            s.datagrams.append(datagram)
            return false
        }
        if fail { throw HueEntertainmentError.connectionFailed("fake send failure") }
    }

    func close() async { state.withLock { $0.closed = true } }
}

struct ConnectCall: Sendable, Equatable {
    var host: String
    var port: UInt16
    var identity: String
    var psk: [UInt8]
}

final class FakeDTLSConnector: HueDTLSConnector {
    let channel = FakeDatagramChannel()
    private let state = Mutex<(calls: [ConnectCall], error: HueEntertainmentError?)>(([], nil))

    init(error: HueEntertainmentError? = nil) { state.withLock { $0.error = error } }

    var calls: [ConnectCall] { state.withLock { $0.calls } }

    func connect(host: String, port: UInt16, identity: String, psk: [UInt8], timeout: Duration) async throws
        -> any HueDatagramChannel
    {
        let error = state.withLock { s -> HueEntertainmentError? in
            s.calls.append(ConnectCall(host: host, port: port, identity: identity, psk: psk))
            return s.error
        }
        if let error { throw error }
        return channel
    }
}

/// `HueEntertainmentSession` logic with a fake DTLS connector (runs on Linux and macOS).
@Suite("Hue Entertainment session")
struct HueEntertainmentSessionTests {
    typealias M = MockTransport
    static let area = "1a8d99cc-967b-44f2-9202-43f976c0fa6b"
    static let clientKey = "00112233445566778899AABBCCDDEEFF"
    static let psk: [UInt8] = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
    static let areaPath = "/clip/v2/resource/entertainment_configuration/\(area)"

    static func areaJSON(status: String) -> String {
        #"{"errors":[],"data":[{"id":"\#(area)","type":"entertainment_configuration","status":"\#(status)","#
            + #""channels":[{"channel_id":0},{"channel_id":1}]}]}"#
    }

    /// Mock bridge serving one entertainment area with the given status.
    static func transport(status: String = "inactive") -> MockTransport {
        MockTransport { r, _ in
            if r.method == "GET", r.url.path == areaPath { return M.json(areaJSON(status: status)) }
            if r.method == "GET", r.url.path == "/clip/v2/resource/entertainment_configuration" {
                return M.json(areaJSON(status: status))
            }
            return M.defaultRoute(r)
        }
    }

    static func provider(
        _ transport: MockTransport, host: String = M.host, clientKey: String? = clientKey
    ) async throws -> HueProvider {
        let secrets = InMemorySecretStore()
        try await secrets.set(M.appKey, for: HueProvider.appKeySecret(bridgeID: M.bridgeID))
        if let clientKey { try await secrets.set(clientKey, for: HueProvider.clientKeySecret(bridgeID: M.bridgeID)) }
        let provider = HueProvider(secrets: secrets, transport: transport, configuration: HueProviderTests.config())
        await provider.addBridge(PairedDevice(id: M.bridgeID, brand: .hue, name: "Test Bridge", hostHint: host))
        return provider
    }

    static func config(_ tweak: (inout HueEntertainmentSession.Configuration) -> Void = { _ in })
        -> HueEntertainmentSession.Configuration
    {
        var c = HueEntertainmentSession.Configuration()
        c.photosensitivityWarningAcknowledged = true
        tweak(&c)
        return c
    }

    static let channels: [HueStreamChannel] = [
        .rgb(0, red: 1, green: 0, blue: 0),
        .rgb(1, red: 0, green: 0, blue: 1),
    ]

    static func actions(_ transport: MockTransport) throws -> [String] {
        try transport.requests("PUT", areaPath).map {
            try JSONDecoder().decode(HueEntertainmentAction.self, from: try #require($0.body)).action.rawValue
        }
    }

    // MARK: Provider CLIP calls

    @Test func providerListsAreasAndSendsStartStop() async throws {
        let transport = Self.transport()
        let provider = try await Self.provider(transport)

        let areas = try await provider.entertainmentConfigurations(bridgeID: M.bridgeID)
        #expect(areas.map(\.id) == [Self.area])
        #expect(areas.first?.channelIDs == [0, 1])

        try await provider.startEntertainment(bridgeID: M.bridgeID, configurationID: Self.area)
        try await provider.stopEntertainment(bridgeID: M.bridgeID, configurationID: Self.area)
        let puts = transport.requests("PUT", Self.areaPath)
        #expect(puts.map { String(decoding: $0.body ?? Data(), as: UTF8.self) } == [#"{"action":"start"}"#, #"{"action":"stop"}"#])
        #expect(puts.allSatisfy { $0.headers["hue-application-key"] == M.appKey && $0.trust == .bridge(id: M.bridgeID) })
    }

    @Test func credentialsComeFromSecretStore() async throws {
        let provider = try await Self.provider(Self.transport())
        let credentials = try await provider.entertainmentCredentials(bridgeID: M.bridgeID.lowercased())
        #expect(credentials.host == M.host)
        #expect(credentials.identity == M.appKey)
        #expect(credentials.psk == Self.psk)
        #expect(!credentials.description.contains(M.appKey))
        #expect(!credentials.description.contains("0011"))
    }

    @Test func missingClientKeyIsReported() async throws {
        let provider = try await Self.provider(Self.transport(), clientKey: nil)
        await #expect(throws: HueEntertainmentError.missingClientKey(bridgeID: M.bridgeID)) {
            try await provider.entertainmentCredentials(bridgeID: M.bridgeID)
        }
        let bad = try await Self.provider(Self.transport(), clientKey: "not-hex")
        await #expect(throws: HueEntertainmentError.invalidClientKey) {
            try await bad.entertainmentCredentials(bridgeID: M.bridgeID)
        }
    }

    // MARK: Session

    @Test func startRequiresPhotosensitivityAcknowledgement() async throws {
        let transport = Self.transport()
        let connector = FakeDTLSConnector()
        let session = HueEntertainmentSession(
            provider: try await Self.provider(transport), bridgeID: M.bridgeID, configurationID: Self.area,
            connector: connector, configuration: Self.config { $0.photosensitivityWarningAcknowledged = false })

        await #expect(throws: HueEntertainmentError.photosensitivityWarningNotAcknowledged) { try await session.start() }
        #expect(transport.requests.isEmpty)
        #expect(connector.calls.isEmpty)
        #expect(await session.state == .idle)
    }

    @Test func streamsFramesAtTheFrameRateAndStops() async throws {
        let transport = Self.transport()
        let connector = FakeDTLSConnector()
        let session = HueEntertainmentSession(
            provider: try await Self.provider(transport), bridgeID: M.bridgeID, configurationID: Self.area.uppercased(),
            connector: connector, configuration: Self.config())

        await session.setChannels(Self.channels)
        try await session.start()
        #expect(await session.state == .streaming)
        #expect(connector.calls == [ConnectCall(host: M.host, port: 2100, identity: M.appKey, psk: Self.psk)])
        #expect(try Self.actions(transport) == ["start"])

        try await Task.sleep(for: .milliseconds(500))
        await session.stop()

        let sent = connector.channel.datagrams
        // 50 Hz for 0.5 s is 25 frames; leave room for slow CI runners but no bursts.
        #expect((8...30).contains(sent.count), "sent \(sent.count) frames")
        let frames = try sent.map { try HueStreamFrame(decoding: $0) }
        #expect(frames.allSatisfy { $0.configurationID == Self.area && $0.colorSpace == .rgb && $0.channels == Self.channels })
        #expect(frames.map(\.sequence) == (0..<frames.count).map { UInt8(truncatingIfNeeded: $0) })

        #expect(await session.state == .stopped(.requested))
        #expect(connector.channel.isClosed)
        #expect(try Self.actions(transport) == ["start", "stop"])

        // Idempotent; no frames after stop.
        await session.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(connector.channel.datagrams.count == sent.count)
        #expect(try Self.actions(transport) == ["start", "stop"])
    }

    @Test func autoStopsWhenIdle() async throws {
        let transport = Self.transport()
        let connector = FakeDTLSConnector()
        let session = HueEntertainmentSession(
            provider: try await Self.provider(transport), bridgeID: M.bridgeID, configurationID: Self.area,
            connector: connector, configuration: Self.config { $0.idleTimeout = .milliseconds(500); $0.frameRate = 25 })

        // Channels before start(): the first tick sends at once, so a busy test runner cannot let the
        // idle timer expire before any frame went out.
        await session.setChannels(Self.channels)
        try await session.start()
        let stopped = await eventually { await session.state == .stopped(.idle) }
        #expect(stopped)
        #expect(connector.channel.isClosed)
        #expect(try Self.actions(transport) == ["start", "stop"])
        // The last frame was repeated until the idle timeout.
        #expect(connector.channel.datagrams.count >= 2)
    }

    @Test func refusesAnAreaAnotherAppStreamsTo() async throws {
        let transport = Self.transport(status: "active")
        let connector = FakeDTLSConnector()
        let session = HueEntertainmentSession(
            provider: try await Self.provider(transport), bridgeID: M.bridgeID, configurationID: Self.area,
            connector: connector, configuration: Self.config())
        await #expect(throws: HueEntertainmentError.areaInUse(Self.area)) { try await session.start() }
        #expect(try Self.actions(transport).isEmpty)
        #expect(connector.calls.isEmpty)
        guard case .stopped(.failed) = await session.state else {
            Issue.record("expected failed state")
            return
        }

        let takeOver = HueEntertainmentSession(
            provider: try await Self.provider(transport), bridgeID: M.bridgeID, configurationID: Self.area,
            connector: connector, configuration: Self.config { $0.takeOverActiveStream = true })
        try await takeOver.start()
        #expect(await takeOver.state == .streaming)
        await takeOver.stop()
    }

    @Test func handshakeFailureSendsStop() async throws {
        let transport = Self.transport()
        let connector = FakeDTLSConnector(error: .handshakeTimedOut)
        let session = HueEntertainmentSession(
            provider: try await Self.provider(transport), bridgeID: M.bridgeID, configurationID: Self.area,
            connector: connector, configuration: Self.config())
        await #expect(throws: HueEntertainmentError.handshakeTimedOut) { try await session.start() }
        #expect(try Self.actions(transport) == ["start", "stop"])
        #expect(await session.state == .stopped(.failed(String(describing: HueEntertainmentError.handshakeTimedOut))))
    }

    @Test func sendFailureStopsTheSession() async throws {
        let transport = Self.transport()
        let connector = FakeDTLSConnector()
        let session = HueEntertainmentSession(
            provider: try await Self.provider(transport), bridgeID: M.bridgeID, configurationID: Self.area,
            connector: connector, configuration: Self.config())
        await session.setChannels(Self.channels)
        try await session.start()
        connector.channel.failSends()
        let failed = await eventually {
            if case .stopped(.failed) = await session.state { return true }
            return false
        }
        #expect(failed)
        #expect(try Self.actions(transport) == ["start", "stop"])
    }

    @Test func moreThanTwentyChannelsSplitPerTick() async throws {
        let transport = Self.transport()
        let connector = FakeDTLSConnector()
        let session = HueEntertainmentSession(
            provider: try await Self.provider(transport), bridgeID: M.bridgeID, configurationID: Self.area,
            connector: connector, configuration: Self.config { $0.colorSpace = .xyBrightness })
        let many = (0..<25).map { HueStreamChannel.xy(UInt8($0), x: 0.3, y: 0.3, brightness: 1) }
        await session.setChannels(many)
        try await session.start()
        _ = await eventually { connector.channel.datagrams.count >= 4 }
        await session.stop()
        let frames = try connector.channel.datagrams.map { try HueStreamFrame(decoding: $0) }
        #expect(frames.count >= 4)
        #expect(frames[0].channels.count == 20 && frames[1].channels.count == 5)
        #expect(frames[0].sequence == frames[1].sequence)
        #expect(frames.allSatisfy { $0.colorSpace == .xyBrightness })
    }

    @Test func frameRateIsClampedTo25Through50Hz() async throws {
        let provider = try await Self.provider(Self.transport())
        func interval(_ rate: Double) -> Duration {
            HueEntertainmentSession(
                provider: provider, bridgeID: M.bridgeID, configurationID: Self.area, connector: FakeDTLSConnector(),
                configuration: Self.config { $0.frameRate = rate }
            ).frameInterval
        }
        #expect(interval(50) == .milliseconds(20))
        #expect(interval(25) == .milliseconds(40))
        #expect(interval(120) == .milliseconds(20))
        #expect(interval(1) == .milliseconds(40))
    }
}
