#if canImport(Network)
import Foundation
import LightCore
import NetKit

extension ElgatoNetworkEnvironment {
    /// Real network: URLSession transport and Bonjour `_elg._tcp`.
    public static var live: ElgatoNetworkEnvironment {
        ElgatoNetworkEnvironment(http: URLSessionElgatoTransport(), browseBonjour: ElgatoNetworkEnvironment.bonjourBrowser)
    }

    static let bonjourBrowser: @Sendable () -> AsyncStream<ElgatoBonjourHit> = {
        let (stream, continuation) = AsyncStream.makeStream(of: ElgatoBonjourHit.self)
        let task = Task {
            for await event in BonjourBrowser.browse(type: ElgatoProvider.bonjourType) {
                if case .added(let service) = event {
                    continuation.yield(ElgatoBonjourHit(name: service.name, host: service.host, port: service.port, txt: service.txt))
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

extension ElgatoProvider {
    /// The provider wired to the real network (URLSession + Bonjour).
    public static func live() -> ElgatoProvider {
        ElgatoProvider(environment: .live)
    }
}
#endif
