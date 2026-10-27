#if canImport(Network)
import Foundation
import LightCore
import NanoleafCodec
@preconcurrency import Network
import NetKit

/// Bonjour discovery of `_nanoleafapi._tcp` controllers (Apple platforms only).
///
/// Browses with NetKit's `BonjourBrowser` without its generic resolution, then resolves each service
/// with an IPv4-only `NWConnection`: firmware >= 8.5.2 advertises IPv6 addresses on which API
/// requests fail (openHAB nanoleaf binding notes), so IPv6 results are never used.
/// The app's Info.plist must list `_nanoleafapi._tcp` in `NSBonjourServices`.
public enum NanoleafBonjour {
    private static let log = Log(package: "nanoleafkit", category: "bonjour")

    /// Streams resolved services until `timeout` elapses, then finishes. Terminating the stream stops
    /// browsing.
    public static func browse(timeout: Duration, resolveTimeout: Duration = .seconds(4)) -> AsyncStream<NanoleafServiceRecord> {
        let (stream, continuation) = AsyncStream.makeStream(of: NanoleafServiceRecord.self)
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await withDiscardingTaskGroup { resolvers in
                        for await event in BonjourBrowser.browse(type: NanoleafAPI.serviceType, resolve: false) {
                            switch event {
                            case .added(let service):
                                resolvers.addTask {
                                    guard let resolved = await resolveIPv4(service, timeout: resolveTimeout) else {
                                        log.notice("Could not resolve \(service.name) to IPv4")
                                        return
                                    }
                                    continuation.yield(NanoleafServiceRecord(
                                        name: service.name, host: resolved.0, port: Int(resolved.1), txt: service.txt))
                                }
                            case .policyDenied:
                                log.error("Bonjour denied: Local Network permission off or _nanoleafapi._tcp missing from NSBonjourServices")
                            case .failed(let message):
                                log.notice("Bonjour browse failed: \(message)")
                            case .removed:
                                break
                            }
                        }
                    }
                }
                group.addTask { try? await Task.sleep(for: timeout) }
                _ = await group.next()
                group.cancelAll()
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Resolves a service to an IPv4 address and port by opening a short IPv4-only TCP connection.
    static func resolveIPv4(_ service: BonjourService, timeout: Duration) async -> (String, UInt16)? {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: service.endpoint, using: parameters)
        let queue = DispatchQueue(label: "com.sinap.smartlights.nanoleafkit.resolve")
        let once = ResolveOnce()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<(String, UInt16)?, Never>) in
                let finish: @Sendable ((String, UInt16)?) -> Void = { result in
                    guard once.claim() else { return }
                    connection.cancel()
                    continuation.resume(returning: result)
                }
                once.setCancel { finish(nil) }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint,
                           case let .ipv4(address) = host {
                            finish((ipv4String(address), port.rawValue))
                        } else {
                            finish(nil)
                        }
                    case .failed, .cancelled:
                        finish(nil)
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                let c = timeout.components
                let seconds = Double(c.seconds) + Double(c.attoseconds) / 1e18
                queue.asyncAfter(deadline: .now() + seconds) { finish(nil) }
            }
        } onCancel: {
            once.cancel()
        }
    }

    /// Dotted quad without any `%interface` suffix.
    static func ipv4String(_ address: IPv4Address) -> String {
        let bytes = [UInt8](address.rawValue)
        guard bytes.count == 4 else { return "\(address)".split(separator: "%").first.map(String.init) ?? "\(address)" }
        return bytes.map(String.init).joined(separator: ".")
    }
}

/// First-caller-wins flag plus a cancel hook.
private final class ResolveOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var onCancel: (@Sendable () -> Void)?
    private var cancelled = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }

    func setCancel(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        let alreadyCancelled = cancelled
        onCancel = handler
        lock.unlock()
        if alreadyCancelled { handler() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let handler = onCancel
        lock.unlock()
        handler?()
    }
}
#endif
