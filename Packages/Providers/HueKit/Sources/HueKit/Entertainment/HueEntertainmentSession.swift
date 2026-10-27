import Foundation
import HueCodec
import LightCore

/// An open, encrypted datagram connection to the bridge's Entertainment port.
public protocol HueDatagramChannel: Sendable {
    func send(_ datagram: Data) async throws
    func close() async
}

/// Opens a DTLS 1.2 PSK connection (cipher `TLS_PSK_WITH_AES_128_GCM_SHA256`).
/// `NWDTLSConnector` implements it with Network.framework; tests inject a fake.
public protocol HueDTLSConnector: Sendable {
    func connect(host: String, port: UInt16, identity: String, psk: [UInt8], timeout: Duration) async throws
        -> any HueDatagramChannel
}

/// Streams HueStream v2 frames to one Entertainment area (`entertainment_configuration`).
///
/// Lifecycle: `start()` checks the photosensitivity acknowledgement, reads the keys, refuses an area
/// another app is streaming to (unless `takeOverActiveStream`), sends `{"action":"start"}`, opens
/// DTLS to UDP 2100 and runs a fixed-rate send loop (25...50 Hz). Every tick re-sends the latest
/// channels from `setChannels`, which also keeps the bridge's stream alive. When `setChannels` has
/// not been called for `idleTimeout`, or the connection fails, or `stop()` is called, the session
/// closes DTLS and sends `{"action":"stop"}` so the lights return to their previous state.
///
/// Photosensitivity: Signify's developer terms require a health warning before fast or strobing
/// light effects. The app must show it and set `photosensitivityWarningAcknowledged` only after the
/// user accepted it; `start()` throws otherwise. See README "Entertainment streaming".
///
/// On Apple platforms `init(provider:bridgeID:configurationID:configuration:)` uses `NWDTLSConnector`.
public actor HueEntertainmentSession {
    public struct Configuration: Sendable {
        /// Frames per second, clamped to `HueEntertainmentSession.frameRateRange` (25...50).
        public var frameRate: Double = 50
        /// Auto-stop when `setChannels` has not been called for this long. The last frame is
        /// re-sent until then.
        public var idleTimeout: Duration = .seconds(10)
        public var colorSpace: HueStreamColorSpace = .rgb
        public var handshakeTimeout: Duration = .seconds(5)
        /// Stream even when another application is already streaming to the area.
        public var takeOverActiveStream = false
        /// The bridge listens on 2100; overridden by tests only.
        public var port: UInt16 = HueStreamFrame.port
        /// Set by the app after the user accepted the photosensitivity warning.
        public var photosensitivityWarningAcknowledged = false

        public init() {}
    }

    public enum StopReason: Sendable, Equatable {
        case requested
        /// No `setChannels` for `idleTimeout`.
        case idle
        case failed(String)
    }

    public enum State: Sendable, Equatable {
        case idle
        case starting
        case streaming
        case stopped(StopReason)
    }

    /// Signify recommends 50-60 Hz to the bridge, which forwards about 25 Hz over Zigbee.
    public static let frameRateRange: ClosedRange<Double> = 25...50

    public nonisolated let bridgeID: String
    public nonisolated let configurationID: String
    public nonisolated let configuration: Configuration
    /// Every state change, starting with the first transition after `.idle`.
    public nonisolated let stateUpdates: AsyncStream<State>

    public private(set) var state: State = .idle
    /// Datagrams sent since `start()` (diagnostics).
    public private(set) var datagramsSent = 0

    private let provider: HueProvider
    private let connector: any HueDTLSConnector
    private let stateContinuation: AsyncStream<State>.Continuation
    private var channels: [HueStreamChannel] = []
    private var sequence: UInt8 = 0
    private var lastActivity = ContinuousClock.now
    private var connection: (any HueDatagramChannel)?
    private var loopTask: Task<Void, Never>?
    private let log = Log(package: "huekit", category: "entertainment")

    public init(
        provider: HueProvider, bridgeID: String, configurationID: String, connector: any HueDTLSConnector,
        configuration: Configuration = Configuration()
    ) {
        self.provider = provider
        self.bridgeID = bridgeID.uppercased()
        self.configurationID = configurationID.lowercased()
        self.connector = connector
        self.configuration = configuration
        let (stream, continuation) = AsyncStream<State>.makeStream(bufferingPolicy: .bufferingNewest(16))
        self.stateUpdates = stream
        self.stateContinuation = continuation
    }

    deinit {
        loopTask?.cancel()
        stateContinuation.finish()
    }

    /// Seconds between frames.
    public nonisolated var frameInterval: Duration {
        let rate = min(max(configuration.frameRate, Self.frameRateRange.lowerBound), Self.frameRateRange.upperBound)
        return .nanoseconds(Int64((1_000_000_000 / rate).rounded()))
    }

    // MARK: - Control

    public func start() async throws {
        guard configuration.photosensitivityWarningAcknowledged else {
            throw HueEntertainmentError.photosensitivityWarningNotAcknowledged
        }
        switch state {
        case .starting, .streaming: throw HueEntertainmentError.alreadyStarted
        case .idle, .stopped: break
        }
        guard HueStreamFrame.isValidConfigurationID(configurationID) else {
            throw HueStreamError.invalidConfigurationID(configurationID)
        }
        setState(.starting)
        datagramsSent = 0
        do {
            let credentials = try await provider.entertainmentCredentials(bridgeID: bridgeID)
            let area = try await provider.entertainmentConfiguration(bridgeID: bridgeID, id: configurationID)
            if area.isActive, !configuration.takeOverActiveStream {
                throw HueEntertainmentError.areaInUse(configurationID)
            }
            try await provider.startEntertainment(bridgeID: bridgeID, configurationID: configurationID)
            do {
                connection = try await connector.connect(
                    host: credentials.host, port: configuration.port, identity: credentials.identity,
                    psk: credentials.psk, timeout: configuration.handshakeTimeout)
            } catch {
                try? await provider.stopEntertainment(bridgeID: bridgeID, configurationID: configurationID)
                throw error
            }
        } catch {
            log.error("start \(configurationID) failed: \(error)")
            setState(.stopped(.failed(String(describing: error))))
            throw error
        }
        // stop() may have run while we were suspended.
        guard state == .starting else {
            await connection?.close()
            connection = nil
            try? await provider.stopEntertainment(bridgeID: bridgeID, configurationID: configurationID)
            return
        }
        lastActivity = .now
        setState(.streaming)
        log.info("streaming to \(configurationID) at \(frameInterval) per frame")
        loopTask = Task { [weak self] in await self?.runLoop() }
    }

    /// Replaces the colours sent on every tick and resets the idle timer. Can be called before
    /// `start()`. More than 20 channels are split over several datagrams per tick.
    public func setChannels(_ channels: [HueStreamChannel]) {
        self.channels = channels
        lastActivity = .now
    }

    /// Stops streaming: closes DTLS and sends `{"action":"stop"}`. Idempotent.
    public func stop() async {
        await finish(.requested)
    }

    // MARK: - Loop

    private func runLoop() async {
        let clock = ContinuousClock()
        let interval = frameInterval
        var next = clock.now
        while !Task.isCancelled, state == .streaming {
            if clock.now - lastActivity >= configuration.idleTimeout {
                log.info("no updates for \(configuration.idleTimeout); stopping \(configurationID)")
                await finish(.idle)
                return
            }
            if !channels.isEmpty, let connection {
                do {
                    let frames = try HueStreamFrame.frames(
                        configurationID: configurationID, sequence: sequence, colorSpace: configuration.colorSpace,
                        channels: channels)
                    for frame in frames {
                        guard state == .streaming else { return }
                        try await connection.send(frame.data)
                        datagramsSent += 1
                    }
                    sequence &+= 1
                } catch {
                    guard state == .streaming else { return }
                    log.error("send failed: \(error)")
                    await finish(.failed(String(describing: error)))
                    return
                }
            }
            next = next.advanced(by: interval)
            let now = clock.now
            if next < now { next = now }  // fell behind: skip, do not burst
            try? await Task.sleep(until: next, clock: clock)
        }
    }

    private func finish(_ reason: StopReason) async {
        switch state {
        case .starting, .streaming: break
        case .idle, .stopped: return
        }
        let wasStarting = state == .starting
        setState(.stopped(reason))
        loopTask?.cancel()
        loopTask = nil
        // While starting, start() owns the cleanup once its awaits return.
        guard !wasStarting else { return }
        await connection?.close()
        connection = nil
        do {
            try await provider.stopEntertainment(bridgeID: bridgeID, configurationID: configurationID)
        } catch {
            log.error("stop \(configurationID) failed: \(error)")
        }
    }

    private func setState(_ new: State) {
        guard new != state else { return }
        state = new
        stateContinuation.yield(new)
    }
}
