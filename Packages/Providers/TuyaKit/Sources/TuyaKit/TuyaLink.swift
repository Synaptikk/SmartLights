import Foundation
import LightCore
import NetKit
import TuyaCodec

/// One open TCP 6668 connection speaking the Tuya protocol: connect, the 3.4/3.5 session-key handshake,
/// then framed requests and decoded responses (pushes included). tinytuya `XenonDevice._get_socket`,
/// `_negotiate_session_key`, `_send_receive`.
actor TuyaLink {
    enum Failure: Error, Sendable, Equatable {
        /// TCP connect failed: wrong IP, device offline, or another client holds the only connection.
        case connect(String)
        case connectionClosed
        /// No (valid) answer: wrong local key or protocol version.
        case noResponse
        case handshake(String)
    }

    struct Settings: Sendable {
        var port: UInt16
        var connectTimeout: Duration
        var responseTimeout: Duration
    }

    let deviceId: String
    nonisolated let responses: AsyncStream<TuyaResponse>

    private var codec: TuyaSessionCodec
    private let connection: any TuyaTCPConnection
    private let continuation: AsyncStream<TuyaResponse>.Continuation
    private var decoder = TuyaFrameDecoder()
    private var negotiationGate: OnceGate<[UInt8]>?
    private var statusGate: OnceGate<TuyaResponse>?
    private var reader: Task<Void, Never>?
    private let log = Log(package: "tuyakit", category: "link")

    private init(codec: TuyaSessionCodec, connection: any TuyaTCPConnection) {
        self.codec = codec
        deviceId = codec.deviceId
        self.connection = connection
        (responses, continuation) = AsyncStream<TuyaResponse>.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    /// Connects and, for 3.4/3.5, negotiates the session key.
    static func open(host: String, codec: TuyaSessionCodec, connector: any TuyaTCPConnector, settings: Settings) async throws -> TuyaLink {
        let connection: any TuyaTCPConnection
        do {
            connection = try await connector.connect(host: host, port: settings.port, timeout: settings.connectTimeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.connect(String(describing: error))
        }
        let link = TuyaLink(codec: codec, connection: connection)
        await link.startReader()
        if codec.version.negotiatesSessionKey {
            do {
                try await link.negotiate(timeout: settings.responseTimeout)
            } catch {
                await link.close()
                throw error
            }
        }
        return link
    }

    var deviceType: TuyaDeviceType { codec.deviceType }
    var version: TuyaVersion { codec.version }

    func close() {
        reader?.cancel()
        connection.close()
        finish()
    }

    /// Encodes and sends `request` (sequence number, timestamp and encryption handled by the codec).
    func send(_ request: TuyaRequest) async throws {
        let frame: [UInt8]
        do {
            frame = try codec.encode(request, time: Int(Date().timeIntervalSince1970))
        } catch {
            throw LightCoreError.protocolError("Tuya encode failed: \(error)")
        }
        try await connection.send(Data(frame))
    }

    /// Sends `DP_QUERY` and returns the first status. A "data unvalid" answer switches to the device22
    /// variant and asks again once (tinytuya does the same).
    func queryStatus(timeout: Duration) async throws -> [String: TuyaJSON] {
        for _ in 0..<2 {
            let gate = OnceGate<TuyaResponse>()
            statusGate = gate
            try await send(.dpQuery)
            let response: TuyaResponse
            do {
                response = try await gate.wait(timeout: timeout)
            } catch LightCoreError.timeout {
                statusGate = nil
                throw Failure.noResponse
            }
            statusGate = nil
            if response.isDataUnvalid {
                guard codec.deviceType == .default else { throw Failure.noResponse }
                log.info("\(deviceId): 'data unvalid', switching to device22 queries")
                codec.deviceType = .device22
                continue
            }
            return response.dps ?? [:]
        }
        throw Failure.noResponse
    }

    // MARK: - Private

    private func negotiate(timeout: Duration) async throws {
        let gate = OnceGate<[UInt8]>()
        negotiationGate = gate
        defer { negotiationGate = nil }
        let start = try codec.negotiationStart()
        try await connection.send(Data(start))
        let reply: [UInt8]
        do {
            reply = try await gate.wait(timeout: timeout)
        } catch LightCoreError.timeout {
            throw Failure.noResponse
        }
        do {
            let finish = try codec.negotiationFinish(response: reply)
            try await connection.send(Data(finish))
        } catch let error as TuyaSessionCodec.Failure {
            throw Failure.handshake(String(describing: error))
        }
    }

    private func startReader() {
        let incoming = connection.incoming
        reader = Task { [weak self] in
            do {
                for try await chunk in incoming {
                    guard let self else { return }
                    await self.received(chunk)
                }
            } catch {
                await self?.logReadError(error)
            }
            await self?.finish()
        }
    }

    private func received(_ chunk: Data) {
        let frames: [[UInt8]]
        do {
            frames = try decoder.append(chunk)
        } catch {
            log.error("\(deviceId): corrupt stream (\(error)); closing")
            connection.close()
            return
        }
        for frame in frames {
            if let gate = negotiationGate, let header = try? TuyaFrame.parseHeader(frame, maxPayload: .max),
               header.command == TuyaCommand.sessKeyNegResp.rawValue {
                gate.resume(.success(frame))
                continue
            }
            do {
                let response = try codec.decode(frame)
                if let gate = statusGate, response.dps != nil || response.isDataUnvalid {
                    statusGate = nil
                    gate.resume(.success(response))
                }
                continuation.yield(response)
            } catch {
                // Wrong key, corrupt frame or a frame from a previous key: skip it.
                log.debug("\(deviceId): dropped frame (\(frame.count) bytes): \(error)")
            }
        }
    }

    private func logReadError(_ error: any Error) {
        log.info("\(deviceId) read error: \(error)")
    }

    private func finish() {
        negotiationGate?.resume(.failure(Failure.connectionClosed))
        statusGate?.resume(.failure(Failure.connectionClosed))
        negotiationGate = nil
        statusGate = nil
        continuation.finish()
    }
}
