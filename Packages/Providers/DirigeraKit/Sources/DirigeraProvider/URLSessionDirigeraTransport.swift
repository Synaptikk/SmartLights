#if canImport(Darwin) && canImport(Security) && canImport(CryptoKit) && canImport(Network)
import DirigeraCodec
import Foundation
import LightCore
import NetKit
@preconcurrency import Security
import Synchronization

/// `DirigeraTransport` on URLSession.
///
/// - `.hub(id)` requests and the event WebSocket use one session per hub whose delegate is a
///   NetKit `TrustingSessionDelegate` with no anchors and the self-signed TOFU fallback: the
///   leaf's SHA-256 must equal the pin stored for the hub id at pairing time. The hub's CN is not
///   checked (its format is unverified; see docs/HARDWARE-NOTES.md).
/// - `.pairing` requests accept any certificate and report the leaf's SHA-256; the provider
///   checks it stays the same through the pairing flow and pins it under the hub id.
public final class URLSessionDirigeraTransport: DirigeraTransport {
    private let pinStore: any TOFUPinStore
    private let hubSessions = Mutex<[String: URLSession]>([:])

    public init(pinStore: any TOFUPinStore) {
        self.pinStore = pinStore
    }

    deinit {
        hubSessions.withLock { sessions in
            for session in sessions.values { session.invalidateAndCancel() }
        }
    }

    private func session(forHub id: String) -> URLSession {
        hubSessions.withLock { sessions in
            if let existing = sessions[id] { return existing }
            let evaluator = TrustEvaluator(
                anchorCertificatesDER: [], expectedIdentifier: id, pinStore: pinStore,
                allowSelfSignedTOFU: true, requireSelfSignedCommonNameMatch: false)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpMaximumConnectionsPerHost = 3
            let session = TrustingSessionDelegate.session(evaluator: evaluator, configuration: configuration)
            sessions[id] = session
            return session
        }
    }

    public func send(_ request: DirigeraHTTPRequest) async throws -> DirigeraHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = request.timeout.timeInterval
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }

        let session: URLSession
        var pairingDelegate: PairingTrustDelegate?
        switch request.trust {
        case .hub(let id):
            session = self.session(forHub: id)
        case .pairing:
            let delegate = PairingTrustDelegate()
            pairingDelegate = delegate
            session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        }
        defer { if pairingDelegate != nil { session.finishTasksAndInvalidate() } }

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw DirigeraTransportError.connectionFailed("not an HTTP response")
            }
            return DirigeraHTTPResponse(status: http.statusCode, body: data, peerCertificateSHA256: pairingDelegate?.fingerprint)
        } catch let error as URLError {
            throw Self.map(error)
        }
    }

    static func map(_ error: URLError) -> any Error {
        switch error.code {
        case .cancelled:
            // A rejected server-trust challenge also surfaces as `.cancelled`.
            if Task.isCancelled { return CancellationError() }
            return DirigeraTransportError.trustRejected("server certificate does not match the pinned one")
        case .timedOut:
            return DirigeraTransportError.timedOut
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid, .secureConnectionFailed:
            return DirigeraTransportError.trustRejected(error.localizedDescription)
        default:
            return DirigeraTransportError.connectionFailed(error.localizedDescription)
        }
    }

    public func eventStream(_ request: DirigeraEventStreamRequest) -> AsyncThrowingStream<DirigeraStreamEvent, any Error> {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.setValue("Bearer \(request.token)", forHTTPHeaderField: "Authorization")
        let task = session(forHub: request.hubID).webSocketTask(with: urlRequest)
        let (stream, continuation) = AsyncThrowingStream<DirigeraStreamEvent, any Error>.makeStream()
        let pingInterval = request.pingInterval
        let reader = Task {
            task.resume()
            let pinger = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: pingInterval)
                    if Task.isCancelled { return }
                    task.sendPing { _ in }
                }
            }
            defer { pinger.cancel() }
            var announced = false
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    if !announced {
                        announced = true
                        continuation.yield(.connected)
                    }
                    switch message {
                    case .string(let text): continuation.yield(.message(text))
                    case .data(let data): continuation.yield(.message(String(decoding: data, as: UTF8.self)))
                    @unknown default: break
                    }
                }
                continuation.finish()
            } catch {
                let status = (task.response as? HTTPURLResponse)?.statusCode
                if status == 401 || status == 403 {
                    continuation.finish(throwing: DirigeraTransportError.unauthorized)
                } else if let urlError = error as? URLError {
                    continuation.finish(throwing: Self.map(urlError))
                } else {
                    continuation.finish(throwing: DirigeraTransportError.connectionFailed(error.localizedDescription))
                }
            }
        }
        continuation.onTermination = { _ in
            reader.cancel()
            task.cancel(with: .goingAway, reason: nil)
        }
        return stream
    }

    /// The hub advertises `gw2-<id>` [verify service type]; `_hap._tcp` is browsed because the hub is
    /// also a HomeKit bridge. Only `gw2-*` names are used by the provider.
    public func browseBonjour() -> AsyncStream<DirigeraBonjourRecord> {
        let (stream, continuation) = AsyncStream<DirigeraBonjourRecord>.makeStream()
        let log = Log(package: "dirigerakit", category: "discovery")
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                for type in ["_ihsp._tcp", "_hap._tcp"] {
                    group.addTask {
                        for await event in BonjourBrowser.browse(type: type) {
                            switch event {
                            case .added(let service):
                                continuation.yield(DirigeraBonjourRecord(
                                    name: service.name, host: service.host, port: service.port.map(Int.init), txt: service.txt))
                            case .policyDenied:
                                log.notice("Bonjour \(type) denied (Local Network permission or NSBonjourServices)")
                            case .failed(let message):
                                log.notice("Bonjour \(type) failed: \(message)")
                            case .removed:
                                break
                            }
                        }
                    }
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func sweepHosts() -> [String] {
        SubnetSweeper.currentWiFiHosts().map(\.description)
    }
}

/// Accepts any certificate during pairing and records the leaf's SHA-256 for pinning.
final class PairingTrustDelegate: NSObject, URLSessionDelegate, Sendable {
    private let recorded = Mutex<Data?>(nil)

    var fingerprint: Data? { recorded.withLock { $0 } }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else { return (.performDefaultHandling, nil) }
        if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first {
            let digest = TrustEvaluator.sha256(of: leaf)
            recorded.withLock { $0 = digest }
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

extension DirigeraProvider {
    /// Production provider: URLSession transport with TOFU pins in `pinStore` (Keychain-backed in the app).
    public init(secrets: any SecretStore, pinStore: any TOFUPinStore, configuration: Configuration = Configuration()) {
        self.init(secrets: secrets, pinStore: pinStore, transport: URLSessionDirigeraTransport(pinStore: pinStore),
                  configuration: configuration)
    }
}
#endif
