#if canImport(Darwin) && canImport(Security) && canImport(CryptoKit) && canImport(Network)
import Foundation
import HueCodec
import LightCore
import NetKit
@preconcurrency import Security
import Synchronization

/// `HueTransport` on URLSession + Network.framework.
///
/// - `.bridge(id)` requests use one session per bridge whose delegate is a NetKit
///   `TrustingSessionDelegate`: anchors = `hue-roots.pem`, leaf CN must equal the bridge id,
///   self-signed bridges are pinned on first use in `pinStore`.
/// - `.probe` requests accept any certificate and report its CN (no secrets are sent).
/// - The event stream uses NetKit `SSEClient` on the bridge session.
public final class URLSessionHueTransport: HueTransport {
    private let anchorsDER: [Data]
    private let pinStore: any TOFUPinStore
    private let publicSession: URLSession
    private let bridgeSessions = Mutex<[String: URLSession]>([:])

    /// - Parameters:
    ///   - anchorsPEM: Signify roots (defaults to the bundled `hue-roots.pem`).
    ///   - pinStore: persistent TOFU pins (Keychain-backed in the app).
    public init(anchorsPEM: String = HueRootCertificates.pem, pinStore: any TOFUPinStore) {
        self.anchorsDER = PEM.certificates(from: anchorsPEM)
        self.pinStore = pinStore
        self.publicSession = URLSession(configuration: .ephemeral)
    }

    deinit {
        publicSession.invalidateAndCancel()
        bridgeSessions.withLock { sessions in
            for session in sessions.values { session.invalidateAndCancel() }
        }
    }

    private func session(forBridge id: String) -> URLSession {
        let key = id.uppercased()
        return bridgeSessions.withLock { sessions in
            if let existing = sessions[key] { return existing }
            let evaluator = TrustEvaluator(
                anchorCertificatesDER: anchorsDER, expectedIdentifier: key, pinStore: pinStore,
                allowSelfSignedTOFU: true, requireSelfSignedCommonNameMatch: true)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpMaximumConnectionsPerHost = 3
            let session = TrustingSessionDelegate.session(evaluator: evaluator, configuration: configuration)
            sessions[key] = session
            return session
        }
    }

    public func send(_ request: HueHTTPRequest) async throws -> HueHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = request.timeout.timeInterval
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }

        let session: URLSession
        var probeDelegate: ProbeTrustDelegate?
        switch request.trust {
        case .publicInternet:
            session = publicSession
        case .bridge(let id):
            session = self.session(forBridge: id)
        case .probe:
            let delegate = ProbeTrustDelegate()
            probeDelegate = delegate
            session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        }
        defer { if probeDelegate != nil { session.finishTasksAndInvalidate() } }

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw HueTransportError.connectionFailed("not an HTTP response")
            }
            return HueHTTPResponse(status: http.statusCode, body: data, peerCommonName: probeDelegate?.commonName)
        } catch let error as URLError {
            throw Self.map(error)
        }
    }

    static func map(_ error: URLError) -> any Error {
        switch error.code {
        case .cancelled:
            // A cancelled auth challenge (trust rejected) also surfaces as `.cancelled`.
            if Task.isCancelled { return CancellationError() }
            return HueTransportError.trustRejected("server certificate not trusted")
        case .timedOut:
            return HueTransportError.timedOut
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid, .secureConnectionFailed, .clientCertificateRejected:
            return HueTransportError.trustRejected(error.localizedDescription)
        default:
            return HueTransportError.connectionFailed(error.localizedDescription)
        }
    }

    public func eventStream(_ request: HueEventStreamRequest) -> AsyncThrowingStream<HueStreamEvent, any Error> {
        let client = SSEClient(
            configuration: SSEClient.Configuration(
                url: request.url,
                headers: ["hue-application-key": request.applicationKey],
                readTimeout: request.readTimeout,
                backoff: request.backoff,
                lastEventID: request.lastEventID,
                fatalStatuses: [401, 403, 404]),
            session: session(forBridge: request.bridgeID))
        let upstream = client.events()
        let (stream, continuation) = AsyncThrowingStream<HueStreamEvent, any Error>.makeStream()
        let task = Task {
            do {
                for try await event in upstream {
                    switch event {
                    case .connected:
                        continuation.yield(.connected)
                    case .event(let sse):
                        continuation.yield(.message(id: sse.id, data: sse.data))
                    case .disconnected(let reason, let retryIn):
                        continuation.yield(.disconnected(reason: reason, retryIn: retryIn))
                    }
                }
                continuation.finish()
            } catch let error as HTTPError {
                switch error {
                case .unauthorized, .forbidden: continuation.finish(throwing: HueError.unauthorized)
                case .notFound: continuation.finish(throwing: HueError.v2Unsupported)
                default: continuation.finish(throwing: error)
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func browseBonjour() -> AsyncStream<HueBonjourRecord> {
        let upstream = BonjourBrowser.browse(type: "_hue._tcp")
        let (stream, continuation) = AsyncStream<HueBonjourRecord>.makeStream()
        let log = Log(package: "huekit", category: "discovery")
        let task = Task {
            for await event in upstream {
                switch event {
                case .added(let service):
                    continuation.yield(HueBonjourRecord(
                        name: service.name, host: service.host, port: service.port.map(Int.init), txt: service.txt))
                case .policyDenied:
                    log.notice("Bonjour browsing denied (Local Network permission or NSBonjourServices)")
                case .failed(let message):
                    log.notice("Bonjour browsing failed: \(message)")
                case .removed:
                    break
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

/// Accepts any server certificate for the unauthenticated `/api/config` probe and records the
/// leaf CN so the caller can check it against the returned bridge id.
final class ProbeTrustDelegate: NSObject, URLSessionDelegate, Sendable {
    private let recordedCommonName = Mutex<String?>(nil)

    var commonName: String? { recordedCommonName.withLock { $0 } }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else { return (.performDefaultHandling, nil) }
        if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first {
            let name = TrustEvaluator.commonName(of: leaf)
            recordedCommonName.withLock { $0 = name }
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

extension HueProvider {
    /// Production provider: URLSession transport with the bundled Signify roots and the given
    /// TOFU pin store (use a Keychain-backed store in the app).
    public init(secrets: any SecretStore, pinStore: any TOFUPinStore, configuration: Configuration = Configuration()) {
        self.init(secrets: secrets, transport: URLSessionHueTransport(pinStore: pinStore), configuration: configuration)
    }
}
#endif
