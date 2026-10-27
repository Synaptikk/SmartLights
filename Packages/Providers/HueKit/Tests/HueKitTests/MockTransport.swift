import Foundation
import HueCodec
import HueKit
import LightCore
import Synchronization

/// Scriptable `HueTransport` for Linux-runnable provider tests.
final class MockTransport: HueTransport {
    typealias Handler = @Sendable (_ request: HueHTTPRequest, _ previous: [HueHTTPRequest]) throws -> HueHTTPResponse

    private struct State {
        var requests: [HueHTTPRequest] = []
        var streams: [AsyncThrowingStream<HueStreamEvent, any Error>.Continuation] = []
        var streamRequests: [HueEventStreamRequest] = []
        var handler: Handler
    }

    private let state: Mutex<State>
    let bonjour: [HueBonjourRecord]

    init(bonjour: [HueBonjourRecord] = [], handler: @escaping Handler = { r, _ in MockTransport.defaultRoute(r) }) {
        state = Mutex(State(handler: handler))
        self.bonjour = bonjour
    }

    func setHandler(_ handler: @escaping Handler) { state.withLock { $0.handler = handler } }

    var requests: [HueHTTPRequest] { state.withLock { $0.requests } }
    var streamCount: Int { state.withLock { $0.streams.count } }
    var streamRequests: [HueEventStreamRequest] { state.withLock { $0.streamRequests } }

    func requests(_ method: String, _ path: String) -> [HueHTTPRequest] {
        requests.filter { $0.method == method && $0.url.path == path }
    }

    func send(_ request: HueHTTPRequest) async throws -> HueHTTPResponse {
        let (handler, previous) = state.withLock { s -> (Handler, [HueHTTPRequest]) in
            let previous = s.requests
            s.requests.append(request)
            return (s.handler, previous)
        }
        return try handler(request, previous)
    }

    func eventStream(_ request: HueEventStreamRequest) -> AsyncThrowingStream<HueStreamEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream<HueStreamEvent, any Error>.makeStream()
        state.withLock {
            $0.streams.append(continuation)
            $0.streamRequests.append(request)
        }
        return stream
    }

    /// Pushes an event into the most recent event stream.
    func emit(_ event: HueStreamEvent) {
        _ = state.withLock { $0.streams.last?.yield(event) }
    }

    func finishStream(throwing error: (any Error)? = nil) {
        state.withLock { $0.streams.last?.finish(throwing: error) }
    }

    func browseBonjour() -> AsyncStream<HueBonjourRecord> {
        let (stream, continuation) = AsyncStream<HueBonjourRecord>.makeStream()
        for record in bonjour { continuation.yield(record) }
        // Like NWBrowser: stays open until cancelled.
        return stream
    }

    // MARK: Canned bridge

    static let bridgeID = "001788FFFE4A2B3C"
    static let host = "10.0.0.2"
    static let appKey = "test-app-key-0123456789abcdefghijklmnop"

    static func json(_ text: String, status: Int = 200, cn: String? = nil) -> HueHTTPResponse {
        HueHTTPResponse(status: status, body: Data(text.utf8), peerCommonName: cn)
    }

    static func fixture(_ name: String = "mini_resources") -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }

    static let configJSON =
        #"{"name":"Test Bridge","bridgeid":"001788FFFE4A2B3C","modelid":"BSB002","swversion":"1967054020","apiversion":"1.67.0","mac":"00:17:88:4a:2b:3c"}"#

    static func defaultRoute(_ r: HueHTTPRequest) -> HueHTTPResponse {
        let path = r.url.path
        switch (r.method, path) {
        case ("GET", "/api/config"):
            return json(configJSON, cn: r.url.scheme == "https" ? bridgeID : nil)
        case ("GET", "/clip/v2/resource"):
            return HueHTTPResponse(status: 200, body: fixture())
        case ("GET", "/clip/v2/resource/geofence_client"):
            return json(#"{"errors":[],"data":[]}"#)
        case ("POST", "/clip/v2/resource/geofence_client"):
            return json(#"{"errors":[],"data":[{"rid":"geo-1","rtype":"geofence_client"}]}"#)
        case ("PUT", _):
            let parts = path.split(separator: "/")
            return json(#"{"errors":[],"data":[{"rid":"\#(parts.last ?? "")","rtype":"\#(parts.dropLast().last ?? "")"}]}"#)
        default:
            return json(#"{"errors":[{"description":"Not Found"}],"data":[]}"#, status: 404)
        }
    }
}

/// Collects provider events from the single-consumer stream.
final class EventCollector: Sendable {
    private let events = Mutex<[ProviderEvent]>([])
    private let task: Mutex<Task<Void, Never>?> = Mutex(nil)

    init(_ stream: AsyncStream<ProviderEvent>) {
        let t = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.events.withLock { $0.append(event) }
            }
        }
        task.withLock { $0 = t }
    }

    deinit { task.withLock { $0?.cancel() } }

    var all: [ProviderEvent] { events.withLock { $0 } }

    /// Waits until an event matches (or times out).
    func wait(timeout: Duration = .seconds(3), _ predicate: (ProviderEvent) -> Bool) async -> ProviderEvent? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let hit = all.first(where: predicate) { return hit }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return all.first(where: predicate)
    }
}

/// Polls `condition` until true or timeout.
func eventually(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
