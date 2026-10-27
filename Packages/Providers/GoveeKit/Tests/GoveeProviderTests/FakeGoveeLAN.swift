import Foundation
import GoveeCodec
import GoveeProvider
import LightCore

/// Behaviour of one fake Govee LAN device (shared by the UDP fake and the in-memory network).
final class FakeGoveeDeviceLogic: @unchecked Sendable {
    struct State: Sendable, Equatable {
        var onOff = 0
        var brightness = 100
        var color = GoveeRGB(r: 255, g: 255, b: 255)
        var kelvin = 0
    }

    let device: String
    let sku: String
    let ip: String
    private let state: Locked<State>
    private let log = Locked<[GoveeLANCommand]>([])
    /// When false the device ignores everything (unplugged / LAN Control off).
    let online = Locked(true)
    /// Answers multicast scans (joined the group).
    let joinsMulticast: Bool

    init(device: String, sku: String, ip: String, state: State = State(), joinsMulticast: Bool = true) {
        self.device = device
        self.sku = sku
        self.ip = ip
        self.state = Locked(state)
        self.joinsMulticast = joinsMulticast
    }

    var received: [GoveeLANCommand] { log.current }
    var current: State { state.current }
    func set(_ body: (inout State) -> Void) { state.withLock(body) }
    func clearLog() { log.withLock { $0.removeAll() } }

    /// Applies a client datagram; returns the reply datagram, if any.
    func handle(_ data: Data) -> Data? {
        guard online.current, let command = GoveeLANCommand.decode(data) else { return nil }
        log.withLock { $0.append(command) }
        switch command {
        case .scan:
            return GoveeLANResponse.scan(GoveeScanResponse(
                ip: ip, device: device, sku: sku, bleVersionHard: "3.01.01", bleVersionSoft: "1.03.01",
                wifiVersionHard: "1.00.10", wifiVersionSoft: "1.02.03"
            )).encoded()
        case .devStatus:
            let s = state.current
            return GoveeLANResponse.devStatus(GoveeDevStatus(onOff: s.onOff, brightness: s.brightness, color: s.color,
                                                             colorTemInKelvin: s.kelvin)).encoded()
        case .turn(let on):
            state.withLock { $0.onOff = on ? 1 : 0 }
        case .brightness(let b):
            state.withLock { $0.brightness = min(max(b, 1), 100) }
        case .color(let rgb):
            state.withLock {
                $0.color = GoveeRGB(rgb)
                $0.kelvin = 0
            }
        case .colorTemperature(let k):
            state.withLock {
                $0.kelvin = k
                $0.color = GoveeRGB(r: 0, g: 0, b: 0)
            }
        }
        return nil
    }
}

/// A fake Govee device on real UDP sockets (127.0.0.1): a scan socket (stands in for 4001) and a
/// control socket (4003). Replies go to the sender's address and port (a real device replies to
/// port 4002, which is where the provider's socket is bound in production).
final class FakeGoveeUDPDevice: @unchecked Sendable {
    let logic: FakeGoveeDeviceLogic
    let scanSocket: TestUDPSocket
    let controlSocket: TestUDPSocket

    init(device: String = "1F:80:C5:32:32:36:72:4E", sku: String = "H6076") throws {
        logic = FakeGoveeDeviceLogic(device: device, sku: sku, ip: "127.0.0.1")
        scanSocket = try TestUDPSocket()
        controlSocket = try TestUDPSocket()
        for socket in [scanSocket, controlSocket] {
            let logic = self.logic
            socket.startReceiving { data, host, port in
                if let reply = logic.handle(data) { try? socket.send(reply, to: host, port: port) }
            }
        }
    }

    var scanPort: UInt16 { scanSocket.port }
    var controlPort: UInt16 { controlSocket.port }

    func stop() {
        scanSocket.close()
        controlSocket.close()
    }
}

/// `GoveeLANTransport` over a POSIX UDP socket bound to 127.0.0.1 (ephemeral port), for Linux and
/// macOS tests against `FakeGoveeUDPDevice`.
actor POSIXGoveeLANTransport: GoveeLANTransport {
    private var socket: TestUDPSocket?
    private(set) var sent: [(Data, String, UInt16)] = []

    func open() throws -> AsyncStream<GoveeDatagram> {
        socket?.close()
        let socket = try TestUDPSocket()
        self.socket = socket
        let (stream, continuation) = AsyncStream.makeStream(of: GoveeDatagram.self)
        socket.startReceiving { data, host, _ in continuation.yield(GoveeDatagram(data: data, host: host)) }
        return stream
    }

    func send(_ data: Data, to host: String, port: UInt16) throws {
        guard let socket else { throw GoveeTransportError.notOpen }
        sent.append((data, host, port))
        try socket.send(data, to: host, port: port)
    }

    func close() {
        socket?.close()
        socket = nil
    }
}

/// In-memory LAN with several fake devices addressed by IP. Multicast scans reach every device
/// that joined the group; `multicastDenied` simulates iOS without the multicast entitlement.
final class FakeLANNetwork: GoveeLANTransport, @unchecked Sendable {
    struct Sent: Sendable, Equatable {
        var host: String
        var port: UInt16
        var command: GoveeLANCommand?
    }

    let devices: Locked<[String: FakeGoveeDeviceLogic]>
    let multicastDenied = Locked(false)
    private let continuation = Locked<AsyncStream<GoveeDatagram>.Continuation?>(nil)
    private let log = Locked<[Sent]>([])
    let openCount = Locked(0)

    init(_ devices: [FakeGoveeDeviceLogic]) {
        self.devices = Locked(Dictionary(devices.map { ($0.ip, $0) }, uniquingKeysWith: { a, _ in a }))
    }

    var sent: [Sent] { log.current }
    func sent(to host: String) -> [GoveeLANCommand] { sent.filter { $0.host == host }.compactMap(\.command) }
    func clearLog() { log.withLock { $0.removeAll() } }

    func open() async throws -> AsyncStream<GoveeDatagram> {
        let (stream, continuation) = AsyncStream.makeStream(of: GoveeDatagram.self)
        self.continuation.withLock { $0 = continuation }
        openCount.withLock { $0 += 1 }
        return stream
    }

    func send(_ data: Data, to host: String, port: UInt16) async throws {
        log.withLock { $0.append(Sent(host: host, port: port, command: GoveeLANCommand.decode(data))) }
        if host == GoveeLAN.multicastAddress {
            if multicastDenied.current { throw GoveeTransportError.network("sendto failed: Permission denied (13)") }
            for device in devices.current.values where device.joinsMulticast {
                deliver(device.handle(data), from: device.ip)
            }
            return
        }
        guard let device = devices.current[host] else { return } // nobody there: UDP is silent
        deliver(device.handle(data), from: host)
    }

    private func deliver(_ reply: Data?, from host: String) {
        guard let reply else { return }
        _ = continuation.current?.yield(GoveeDatagram(data: reply, host: host))
    }

    func close() async {
        continuation.withLock {
            $0?.finish()
            $0 = nil
        }
    }
}
