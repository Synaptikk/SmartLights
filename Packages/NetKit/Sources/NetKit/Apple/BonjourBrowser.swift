#if canImport(Network)
import Foundation
@preconcurrency import Network

/// A Bonjour service instance, optionally resolved to host/port.
public struct BonjourService: Sendable, Hashable, CustomStringConvertible {
    public let name: String
    /// e.g. `_hue._tcp`
    public let type: String
    public let domain: String
    public let interfaceName: String?
    /// TXT record (Hue: `bridgeid`, `modelid`; Nanoleaf: `id`, `md`, ...).
    public let txt: [String: String]
    /// Resolved address (IPv4 dotted quad, IPv6 or host name) if resolution succeeded.
    public let host: String?
    public let port: UInt16?

    public init(name: String, type: String, domain: String, interfaceName: String?, txt: [String: String],
                host: String? = nil, port: UInt16? = nil) {
        self.name = name
        self.type = type
        self.domain = domain
        self.interfaceName = interfaceName
        self.txt = txt
        self.host = host
        self.port = port
    }

    /// The unresolved service endpoint (connect to this to let Network.framework resolve it).
    public var endpoint: NWEndpoint { .service(name: name, type: type, domain: domain, interface: nil) }

    public var description: String {
        "\(name) [\(type)] \(host ?? "?"):\(port.map { String($0) } ?? "?") txt=\(txt)"
    }
}

public enum BonjourEvent: Sendable, Hashable {
    case added(BonjourService)
    case removed(BonjourService)
    /// Bonjour returned `kDNSServiceErr_PolicyDenied` (-65570): Local Network access denied, or the
    /// service type is missing from `NSBonjourServices`.
    case policyDenied
    case failed(String)
}

/// `NWBrowser` wrapper producing an `AsyncStream` of service additions/removals.
public enum BonjourBrowser {
    /// Browses `type` (e.g. `"_hue._tcp"`). With `resolve: true` each added service is resolved to
    /// host/port by briefly opening a connection to it (TCP for `._tcp`, UDP for `._udp`) before
    /// it is yielded; unresolved services (timeout/failure) are still yielded with `host == nil`.
    /// Terminating the stream (breaking out of `for await`) cancels the browser.
    public static func browse(
        type: String,
        domain: String? = nil,
        resolve: Bool = true,
        resolveTimeout: Duration = .seconds(5)
    ) -> AsyncStream<BonjourEvent> {
        let (stream, continuation) = AsyncStream<BonjourEvent>.makeStream()
        let queue = DispatchQueue(label: "com.sinap.smartlights.netkit.bonjour")
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: domain), using: parameters)

        browser.stateUpdateHandler = { state in
            switch state {
            case .waiting(let error), .failed(let error):
                if case .dns(let code) = error, code == -65570 {
                    continuation.yield(.policyDenied)
                } else {
                    continuation.yield(.failed(error.localizedDescription))
                }
                if case .failed = state { continuation.finish() }
            case .cancelled:
                continuation.finish()
            default:
                break
            }
        }

        browser.browseResultsChangedHandler = { _, changes in
            for change in changes {
                switch change {
                case .added(let result):
                    guard let service = makeService(from: result) else { continue }
                    if resolve {
                        Self.resolve(service, timeout: resolveTimeout, queue: queue) { continuation.yield(.added($0)) }
                    } else {
                        continuation.yield(.added(service))
                    }
                case .removed(let result):
                    if let service = makeService(from: result) { continuation.yield(.removed(service)) }
                default:
                    break
                }
            }
        }

        continuation.onTermination = { _ in browser.cancel() }
        browser.start(queue: queue)
        return stream
    }

    static func makeService(from result: NWBrowser.Result) -> BonjourService? {
        guard case let .service(name, type, domain, interface) = result.endpoint else { return nil }
        var txt: [String: String] = [:]
        if case let .bonjour(record) = result.metadata {
            txt = record.dictionary
        }
        return BonjourService(name: name, type: type, domain: domain, interfaceName: interface?.name, txt: txt)
    }

    /// Resolves a service to host/port by opening a short-lived connection to it.
    static func resolve(
        _ service: BonjourService,
        timeout: Duration,
        queue: DispatchQueue,
        completion: @escaping @Sendable (BonjourService) -> Void
    ) {
        let isUDP = service.type.hasSuffix("._udp") || service.type.hasSuffix("._udp.")
        let connection = NWConnection(to: service.endpoint, using: isUDP ? .udp : .tcp)
        let done = LockedBox(false)
        let finish: @Sendable (String?, UInt16?) -> Void = { host, port in
            let first = done.withLock { (value: inout Bool) -> Bool in
                defer { value = true }
                return !value
            }
            guard first else { return }
            connection.cancel()
            completion(BonjourService(name: service.name, type: service.type, domain: service.domain,
                                      interfaceName: service.interfaceName, txt: service.txt,
                                      host: host, port: port))
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                    finish(hostString(host), port.rawValue)
                } else {
                    finish(nil, nil)
                }
            case .failed:
                finish(nil, nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout.timeInterval) { finish(nil, nil) }
    }

    static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let name, _):
            return name
        case .ipv4(let address):
            return "\(address)"
        case .ipv6(let address):
            return "\(address)"
        @unknown default:
            return "\(host)"
        }
    }
}
#endif
