#if canImport(Network)
import Foundation
import LightCore
import NetKit

extension WLEDNetworkEnvironment {
    /// Real network: URLSession transport and Bonjour `_wled._tcp`.
    public static var live: WLEDNetworkEnvironment {
        WLEDNetworkEnvironment(http: URLSessionWLEDTransport(), browseBonjour: WLEDNetworkEnvironment.bonjourBrowser)
    }

    static let bonjourBrowser: @Sendable () -> AsyncStream<WLEDBonjourHit> = {
        let (stream, continuation) = AsyncStream.makeStream(of: WLEDBonjourHit.self)
        let task = Task {
            for await event in BonjourBrowser.browse(type: WLEDProvider.bonjourType) {
                if case .added(let service) = event {
                    continuation.yield(WLEDBonjourHit(name: service.name, host: service.host, port: service.port, txt: service.txt))
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

extension WLEDProvider {
    /// The provider wired to the real network (URLSession + Bonjour).
    public static func live() -> WLEDProvider {
        WLEDProvider(environment: .live)
    }
}
#endif
