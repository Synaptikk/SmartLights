import Foundation
import LightCore
import TPLinkCodec

/// Credentials for KLAP (TP-Link account email + password, both case-sensitive). Never logged.
public struct TPLinkCredentials: Sendable, Hashable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// Why a device request failed (mapped to `LightCoreError` by the provider).
enum TPLinkClientError: Error, Sendable, Equatable {
    /// KLAP handshake1 hash matched none of the candidate credentials, or the device answered
    /// with an authentication error code.
    case authentication(String)
    case unsupported(String)
}

/// One device's connection: serialises requests, owns the KLAP session (cookie, AES state,
/// expiry) and re-handshakes when the device drops it (HTTP 403, `error_code` 9999 / -40401).
actor TPLinkDeviceClient {
    struct KLAPState {
        var session: TPLinkKLAPSession
        var cookie: String?
        var expiresAt: ContinuousClock.Instant
        /// Index of the matched candidate (0 = account credentials when given).
        var matchedCandidate: Int
    }

    let host: String
    private(set) var connection: TPLinkConnection
    private let environment: TPLinkNetworkEnvironment
    private let timeout: Duration
    private let credentials: TPLinkCredentials?
    private let terminalUUID: String
    private let log = Log(package: "tplinkkit", category: "session")
    private let clock = ContinuousClock()

    private var klap: KLAPState?
    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []
    /// Handshakes performed (diagnostics/tests).
    private(set) var handshakeCount = 0

    init(host: String, connection: TPLinkConnection, environment: TPLinkNetworkEnvironment, timeout: Duration,
         credentials: TPLinkCredentials?, terminalUUID: String) {
        self.host = host
        self.connection = connection
        self.environment = environment
        self.timeout = timeout
        self.credentials = credentials
        self.terminalUUID = terminalUUID
    }

    /// Drops the KLAP session (next request re-handshakes).
    func resetSession() { klap = nil }

    var hasSession: Bool { klap != nil }

    // MARK: Requests

    /// IOT JSON request (legacy XOR or Kasa KLAP). Returns the whole response object.
    func iot(_ request: TPLinkJSON) async throws -> TPLinkJSON {
        await lock()
        defer { unlock() }
        switch connection.transport {
        case .xor:
            return try await xorExchange(request)
        case .klap:
            let data = try await klapSend(request.data)
            return try TPLinkJSON.parse(data)
        case .aes:
            throw TPLinkClientError.unsupported(Self.aesMessage)
        }
    }

    /// SMART request over KLAP. Returns `result` (`.null` for set methods).
    func smart(_ method: String, params: TPLinkJSON? = nil) async throws -> TPLinkJSON {
        await lock()
        defer { unlock() }
        guard connection.transport == .klap else {
            throw TPLinkClientError.unsupported(connection.transport == .aes ? Self.aesMessage : "SMART needs KLAP")
        }
        var attempt = 0
        while true {
            attempt += 1
            let millis = Int64((Date().timeIntervalSince1970 * 1000).rounded())
            let request = TPLinkSmart.request(method: method, params: params, timeMillis: millis, terminalUUID: terminalUUID)
            let json = try TPLinkJSON.parse(try await klapSend(request.data))
            do {
                return try TPLinkSmart.result(of: json, method: method)
            } catch TPLinkCodecError.smartError(_, let code) where code.requiresNewSession && attempt < 3 {
                log.info("\(host): \(method) answered \(code.name); new session")
                klap = nil
                continue
            } catch TPLinkCodecError.smartError(_, let code) where code.isAuthentication {
                klap = nil
                throw TPLinkClientError.authentication("\(method): \(code.name)")
            }
        }
    }

    static let aesMessage = "This Tapo firmware uses the older AES protocol, which SmartLights does not support. "
        + "Update the device in the Tapo app (Me > Firmware Update) and add it again."

    // MARK: XOR (TCP 9999)

    private func xorExchange(_ request: TPLinkJSON) async throws -> TPLinkJSON {
        let frame = TPLinkXOR.frame(request)
        var lastError: any Error = LightCoreError.timeout
        // One retry: the bulbs occasionally reset a connection while busy.
        for attempt in 1...2 {
            do {
                let answer = try await environment.stream.exchange(frame, host: host, port: connection.port, timeout: timeout)
                return try TPLinkJSON.parse(TPLinkXOR.unframe(answer))
            } catch let error as LightCoreError {
                lastError = error
                if case .unreachable = error { throw error } // refused/no route: retrying will not help
                log.debug("\(host): XOR attempt \(attempt) failed: \(error)")
            } catch let error as TPLinkCodecError {
                throw LightCoreError.protocolError(error.description)
            }
        }
        throw lastError
    }

    // MARK: KLAP

    private var baseURL: String { "http://\(host):\(connection.port)" }

    private func url(_ path: String, query: String? = nil) throws -> URL {
        guard let u = URL(string: baseURL + path + (query.map { "?" + $0 } ?? "")) else {
            throw LightCoreError.transport("invalid URL for \(host)")
        }
        return u
    }

    private func sessionValid(_ state: KLAPState) -> Bool { clock.now < state.expiresAt }

    /// Encrypts `plaintext`, posts it to `/app/request?seq=N` and decrypts the answer.
    /// A 403 (session dropped) triggers one new handshake.
    private func klapSend(_ plaintext: Data) async throws -> Data {
        var attempt = 0
        while true {
            attempt += 1
            if klap == nil || !sessionValid(klap!) { try await handshake() }
            guard var state = klap else { throw LightCoreError.transport("no KLAP session") }
            let (body, seq) = try state.session.encrypt(plaintext)
            klap = state
            let response = try await environment.http.post(
                try url(TPLinkKLAP.requestPath, query: "seq=\(seq)"), body: body,
                cookie: state.cookie.map { "\(TPLinkKLAP.sessionCookieName)=\($0)" }, timeout: timeout)
            switch response.status {
            case 200:
                do {
                    return try state.session.open(response.body, sequence: seq)
                } catch {
                    klap = nil
                    throw LightCoreError.protocolError("\(host): cannot decrypt KLAP answer (\(error))")
                }
            case 401 where attempt < 2, 403 where attempt < 2:
                log.info("\(host): KLAP request answered \(response.status); new handshake")
                klap = nil
                continue
            default:
                klap = nil
                throw LightCoreError.protocolError("\(host): KLAP request answered HTTP \(response.status)")
            }
        }
    }

    /// handshake1 + handshake2. Tries the configured KLAP version first; when the device's hash
    /// matches the other version instead (manually added devices), switches to it.
    private func handshake() async throws {
        klap = nil
        handshakeCount += 1
        let localSeed = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let r1 = try await environment.http.post(try url(TPLinkKLAP.handshake1Path), body: localSeed, cookie: nil, timeout: timeout)
        guard r1.status == 200 else {
            throw LightCoreError.protocolError("\(host): handshake1 answered HTTP \(r1.status)")
        }
        let (remoteSeed, serverHash) = try TPLinkKLAP.parseHandshake1(r1.body)
        let preferred = connection.klapVersion ?? .v2
        var match: (TPLinkKLAP.Version, Int, Data)?
        for version in [preferred] + TPLinkKLAP.Version.allCases.filter({ $0 != preferred }) {
            let candidates = TPLinkKLAP.candidateHashes(username: credentials?.username, password: credentials?.password, version: version)
            if let i = TPLinkKLAP.matchCandidate(candidates, localSeed: localSeed, remoteSeed: remoteSeed, serverHash: serverHash, version: version) {
                match = (version, i, candidates[i])
                break
            }
        }
        guard let matched = match else {
            throw TPLinkClientError.authentication("\(host) rejected the TP-Link credentials")
        }
        let (version, index, authHash) = matched
        if version != connection.klapVersion {
            log.notice("\(host): device uses KLAP v\(version.rawValue)")
            connection.klapVersion = version
            if version == .v1 { connection.family = .iot }
        }
        let cookie = r1.cookies[TPLinkKLAP.sessionCookieName]
        let lifetime = r1.cookies[TPLinkKLAP.timeoutCookieName].flatMap { Int($0) } ?? TPLinkKLAP.defaultSessionSeconds
        let payload = TPLinkKLAP.handshake2Hash(localSeed: localSeed, remoteSeed: remoteSeed, authHash: authHash, version: version)
        let r2 = try await environment.http.post(try url(TPLinkKLAP.handshake2Path), body: payload,
                                                  cookie: cookie.map { "\(TPLinkKLAP.sessionCookieName)=\($0)" }, timeout: timeout)
        guard r2.status == 200 else {
            if r2.status == 401 || r2.status == 403 {
                throw TPLinkClientError.authentication("\(host): handshake2 answered HTTP \(r2.status)")
            }
            throw LightCoreError.protocolError("\(host): handshake2 answered HTTP \(r2.status)")
        }
        let usable = max(lifetime - TPLinkKLAP.sessionRenewalMarginSeconds, min(lifetime, 60))
        klap = KLAPState(
            session: TPLinkKLAPSession(localSeed: localSeed, remoteSeed: remoteSeed, authHash: authHash),
            cookie: cookie,
            expiresAt: clock.now.advanced(by: .seconds(usable)),
            matchedCandidate: index
        )
        let who = credentials != nil && index == 0 ? "account credentials" : "device default credentials"
        log.debug("\(host): KLAP v\(version.rawValue) session established (\(who))")
    }

    /// Only checks that something speaks KLAP at this address (handshake1 answers 48 bytes).
    static func probeKLAP(host: String, port: UInt16, environment: TPLinkNetworkEnvironment, timeout: Duration) async -> Bool {
        guard let url = URL(string: "http://\(host):\(port)\(TPLinkKLAP.handshake1Path)") else { return false }
        let seed = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        guard let r = try? await environment.http.post(url, body: seed, cookie: nil, timeout: timeout) else { return false }
        return r.status == 200 && r.body.count == 48
    }

    // MARK: Serialisation

    private func lock() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { queue.append($0) }
    }

    private func unlock() {
        if queue.isEmpty {
            busy = false
        } else {
            queue.removeFirst().resume()
        }
    }
}
