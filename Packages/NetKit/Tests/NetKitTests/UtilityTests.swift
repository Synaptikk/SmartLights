import Foundation
import Testing
@testable import NetKit

@Suite("HexCoding")
struct HexCodingTests {
    @Test func roundTrip() {
        let bytes = Data([0x00, 0x0F, 0xA5, 0xFF])
        #expect(bytes.hexString() == "000fa5ff")
        #expect(bytes.hexString(uppercase: true, separator: ":") == "00:0F:A5:FF")
        #expect(Data(hexString: "000fa5ff") == bytes)
        #expect(Data(hexString: "0x000FA5FF") == bytes)
        #expect(Data(hexString: "00:0f:a5:ff") == bytes)
        #expect(Data(hexString: "00 0f-a5 ff") == bytes)
        #expect(Data(hexString: "") == Data())
    }

    @Test func rejectsInvalid() {
        #expect(Data(hexString: "abc") == nil)
        #expect(Data(hexString: "zz") == nil)
        #expect(Hex.decode("0g") == nil)
    }
}

@Suite("ExponentialBackoff")
struct ExponentialBackoffTests {
    @Test func growsAndCaps() {
        var backoff = ExponentialBackoff(initial: .seconds(1), multiplier: 2, maximum: .seconds(10))
        let delays = (0..<6).map { _ in backoff.nextDelay() }
        #expect(delays == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(10), .seconds(10)])
        #expect(backoff.attempt == 6)
        backoff.reset()
        #expect(backoff.nextDelay() == .seconds(1))
        #expect(backoff.delay(forAttempt: 10_000) == .seconds(10))
    }

    @Test func fractionalInitial() {
        let backoff = ExponentialBackoff(initial: .milliseconds(250), multiplier: 2, maximum: .seconds(3))
        #expect(backoff.delay(forAttempt: 0) == .milliseconds(250))
        #expect(backoff.delay(forAttempt: 2) == .seconds(1))
        #expect(backoff.delay(forAttempt: 4) == .seconds(3))
    }

    @Test func jitterStaysInBounds() {
        var backoff = ExponentialBackoff(initial: .seconds(4), multiplier: 1, maximum: .seconds(4), jitter: 0.5)
        for _ in 0..<200 {
            let d = backoff.nextDelay().timeInterval
            #expect(d > 2 - 1e-9 && d <= 4 + 1e-9)
        }
    }

    @Test func durationTimeInterval() {
        #expect(Duration.milliseconds(1500).timeInterval == 1.5)
    }
}

@Suite("TOFUPinStore")
struct TOFUPinStoreTests {
    let a = Data(repeating: 0xAA, count: 32)
    let b = Data(repeating: 0xBB, count: 32)

    @Test func firstUseThenMatchThenMismatch() async {
        let store = InMemoryTOFUPinStore()
        #expect(await store.verifyOrPin(sha256: a, for: "001788FFFE123456") == .pinnedOnFirstUse)
        #expect(await store.verifyOrPin(sha256: a, for: "001788fffe123456") == .matched)
        let result = await store.verifyOrPin(sha256: b, for: "001788FFFE123456")
        guard case .mismatch(let pinned) = result else {
            Issue.record("expected mismatch, got \(result)")
            return
        }
        #expect(pinned.sha256 == a)
        #expect(await store.pin(for: "001788FFFE123456")?.sha256 == a)
        await store.removePin(for: "001788FFFE123456")
        #expect(await store.pin(for: "001788FFFE123456") == nil)
        #expect(await store.verifyOrPin(sha256: b, for: "001788FFFE123456") == .pinnedOnFirstUse)
    }

    @Test func keyedPerIdentifierAndRejectsMalformed() async {
        let store = InMemoryTOFUPinStore()
        #expect(await store.verifyOrPin(sha256: a, for: "bridge-1") == .pinnedOnFirstUse)
        #expect(await store.verifyOrPin(sha256: b, for: "bridge-2") == .pinnedOnFirstUse)
        if case .mismatch = await store.verifyOrPin(sha256: Data([1, 2, 3]), for: "bridge-3") {} else {
            Issue.record("malformed digest must not be pinned")
        }
        #expect(await store.allIdentifiers == ["bridge-1", "bridge-2"])
        #expect(CertificatePin(sha256: Data([1])) == nil)
        #expect(CertificatePin(sha256: a)?.fingerprint.hasPrefix("AA:AA:") == true)
    }

    /// A store that only implements the basic requirements exercises the default `verifyOrPin`.
    actor MinimalStore: TOFUPinStore {
        var pins: [String: CertificatePin] = [:]
        func pin(for identifier: String) -> CertificatePin? { pins[identifier] }
        func setPin(_ pin: CertificatePin, for identifier: String) { pins[identifier] = pin }
        func removePin(for identifier: String) { pins[identifier] = nil }
    }

    @Test func defaultImplementation() async {
        let store = MinimalStore()
        #expect(await store.verifyOrPin(sha256: a, for: "x") == .pinnedOnFirstUse)
        #expect(await store.verifyOrPin(sha256: a, for: "x") == .matched)
        if case .mismatch = await store.verifyOrPin(sha256: b, for: "x") {} else { Issue.record("expected mismatch") }
    }

    @Test func pemParsing() {
        let der1 = Data((0..<40).map { UInt8($0) })
        let der2 = Data([0x30, 0x82, 0x01, 0x0A])
        let b64 = der1.base64EncodedString()
        let pem = """
        junk before
        -----BEGIN CERTIFICATE-----
        \(b64.prefix(20))
        \(b64.dropFirst(20))
        -----END CERTIFICATE-----
        -----BEGIN PRIVATE KEY-----
        AAAA
        -----END PRIVATE KEY-----
        -----BEGIN CERTIFICATE-----
        \(der2.base64EncodedString())
        -----END CERTIFICATE-----
        """
        #expect(PEM.certificates(from: pem) == [der1, der2])
        #expect(PEM.certificates(from: "no pem here").isEmpty)
    }
}

@Suite("HTTP and capability mapping")
struct MappingTests {
    @Test func statusMapping() {
        #expect(HTTPError.check(status: 200) == nil)
        #expect(HTTPError.check(status: 204) == nil)
        #expect(HTTPError.check(status: 403, body: Data("nope".utf8)) == .forbidden(body: "nope"))
        #expect(HTTPError.check(status: 401) == .unauthorized(status: 401, body: ""))
        #expect(HTTPError.check(status: 404) == .notFound(body: ""))
        #expect(HTTPError.check(status: 429, retryAfter: "3") == .rateLimited(status: 429, retryAfter: .seconds(3)))
        #expect(HTTPError.check(status: 503, retryAfter: "1") == .rateLimited(status: 503, retryAfter: .seconds(1)))
        #expect(HTTPError.check(status: 503) == .server(status: 503, body: ""))
        #expect(HTTPError.check(status: 418) == .client(status: 418, body: ""))
        #expect(HTTPError.check(status: 302) == .unexpectedStatus(status: 302, body: ""))
        #expect(HTTPError.check(status: 429)?.isRetryable == true)
        #expect(HTTPError.check(status: 403)?.isRetryable == false)
        #expect(HTTPError.parseRetryAfter("Wed, 21 Oct 2015 07:28:00 GMT") == nil)
        let long = Data(repeating: 0x41, count: 2000)
        if case .server(_, let body) = HTTPError.check(status: 500, body: long) {
            #expect(body.count == 512)
        } else {
            Issue.record("expected server error")
        }
    }

    @Test func broadcastClassification() {
        #expect(BroadcastCapabilityStatus.classify(sendErrno: nil, localNetworkDenied: false) == .entitled)
        #expect(BroadcastCapabilityStatus.classify(sendErrno: nil, localNetworkDenied: nil) == .entitled)
        #expect(BroadcastCapabilityStatus.classify(sendErrno: EACCES, localNetworkDenied: false) == .notEntitled)
        #expect(BroadcastCapabilityStatus.classify(sendErrno: EPERM, localNetworkDenied: nil) == .notEntitled)
        #expect(BroadcastCapabilityStatus.classify(sendErrno: EACCES, localNetworkDenied: true) == .localNetworkDenied)
        #expect(BroadcastCapabilityStatus.classify(sendErrno: ENETUNREACH, localNetworkDenied: false) == .unknown)
    }
}

@Suite("Concurrency helpers")
struct ConcurrencyHelperTests {
    @Test func sweeperRespectsConcurrencyLimitAndCollectsHits() async throws {
        let subnet = try #require(IPv4Subnet(cidr: "192.168.1.0/24"))
        let me = IPv4Addr(192, 168, 1, 10)
        let hosts = subnet.hosts(excluding: [me])
        let tracker = InFlightTracker()
        let sweeper = SubnetSweeper(maxConcurrent: 8)
        let hits = await sweeper.sweep(hosts) { host -> IPv4Addr? in
            await tracker.enter()
            try? await Task.sleep(for: .milliseconds(2))
            await tracker.leave()
            return host.octets[3] % 50 == 0 ? host : nil
        }
        #expect(Set(hits) == [IPv4Addr(192, 168, 1, 50), IPv4Addr(192, 168, 1, 100), IPv4Addr(192, 168, 1, 150),
                              IPv4Addr(192, 168, 1, 200), IPv4Addr(192, 168, 1, 250)])
        #expect(await tracker.peak <= 8)
        #expect(await tracker.total == 253)
    }

    @Test func sweeperStreamCancellation() async {
        let hosts = (1...200).map { IPv4Addr(10, 0, 0, UInt8($0)) }
        let tracker = InFlightTracker()
        do {
            let stream = SubnetSweeper(maxConcurrent: 4).stream(hosts) { host -> IPv4Addr? in
                await tracker.enter()
                try? await Task.sleep(for: .milliseconds(20))
                await tracker.leave()
                return host
            }
            var received = 0
            for await _ in stream {
                received += 1
                if received == 3 { break }
            }
        }
        try? await Task.sleep(for: .milliseconds(200))
        let afterStop = await tracker.total
        try? await Task.sleep(for: .milliseconds(200))
        #expect(await tracker.total == afterStop) // nothing new launched after the consumer left
        #expect(afterStop < 200)
    }

    @Test func resumeGateBeforeAndAfterWait() async throws {
        let early = ResumeGate<Int>()
        early.resume(returning: 1)
        early.resume(returning: 2) // ignored
        #expect(try await early.wait() == 1)

        let late = ResumeGate<String>()
        Task {
            try? await Task.sleep(for: .milliseconds(10))
            late.resume(returning: "ok")
        }
        #expect(try await late.wait(timeout: .seconds(5)) == "ok")
        #expect(late.isFinished)
    }

    @Test func resumeGateTimeout() async {
        let gate = ResumeGate<Int>()
        await #expect(throws: NetTimeoutError.self) {
            try await gate.wait(timeout: .milliseconds(20))
        }
        gate.resume(returning: 5) // ignored after timeout
    }

    @Test func resumeGateCancellation() async {
        let gate = ResumeGate<Int>()
        let task = Task { try await gate.wait() }
        try? await Task.sleep(for: .milliseconds(10))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

actor InFlightTracker {
    private(set) var current = 0
    private(set) var peak = 0
    private(set) var total = 0
    func enter() {
        current += 1
        total += 1
        peak = max(peak, current)
    }
    func leave() { current -= 1 }
}
