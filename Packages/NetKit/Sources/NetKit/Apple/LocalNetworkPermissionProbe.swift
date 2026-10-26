#if canImport(Network) && canImport(Darwin)
import Darwin
import Foundation
@preconcurrency import Network

/// Local Network privacy helpers (Apple TN3179). There is no API to query or request the
/// privilege (FB8711182); these are the documented workarounds.
public enum LocalNetworkPermissionProbe {
    /// Best-effort trigger of the Local Network alert (TN3179 technique): send a one-byte UDP
    /// datagram to the discard port (9) on the IPv4 address of every broadcast-capable interface.
    /// Call it when the user reaches the "Add brand" step, not at launch. No-op if already decided.
    public static func triggerPrompt() {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { _ = Darwin.close(fd) }
        var message: [UInt8] = [0]
        for interface in InterfaceInfo.localNetworkInterfaces() {
            var address = UDPSocket.socketAddress(interface.address, port: 9)
            _ = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.sendto(fd, &message, message.count, MSG_DONTWAIT, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// Observes the current state by opening a UDP `NWConnection` (no packets are sent) to a host on
    /// the Wi-Fi subnet: `.ready` means granted, `.waiting` with `.localNetworkDenied` means denied;
    /// no answer within `timeout` (prompt still showing, or no Wi-Fi) is `.undetermined`.
    /// While undetermined and in the foreground this may itself show the prompt.
    public static func check(timeout: Duration = .seconds(2)) async -> LocalNetworkPermission {
        guard let wifi = InterfaceInfo.currentWiFi(),
              let target = wifi.sweepHosts.first ?? wifi.directedBroadcast else { return .undetermined }
        let connection = NWConnection(host: NWEndpoint.Host(target.description), port: 9, using: .udp)
        let gate = ResumeGate<LocalNetworkPermission>()
        connection.stateUpdateHandler = { [weak connection] state in
            switch state {
            case .ready:
                gate.resume(returning: .granted)
            case .waiting(let error):
                if connection?.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    gate.resume(returning: .denied)
                } else if case .posix(let code) = error, code == .EACCES || code == .EPERM {
                    gate.resume(returning: .denied)
                }
            case .failed:
                gate.resume(returning: .undetermined)
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "com.sinap.smartlights.netkit.lnp"))
        defer { connection.cancel() }
        return (try? await gate.wait(timeout: timeout)) ?? .undetermined
    }
}

/// Runtime detection of UDP broadcast capability (multicast entitlement on iOS).
public enum BroadcastCapability {
    /// Sends one small datagram to the Wi-Fi directed broadcast address via a BSD socket bound to the
    /// Wi-Fi interface and classifies the result. Use a harmless `port`/`payload` (default: discard
    /// port 9, one zero byte). macOS does not require the entitlement and reports `.entitled`.
    public static func detect(port: UInt16 = 9, payload: Data = Data([0])) async -> BroadcastCapabilityStatus {
        guard let wifi = InterfaceInfo.currentWiFi(), let target = wifi.directedBroadcast else { return .unknown }
        var sendErrno: Int32?
        do {
            let socket = try UDPSocket(options: .init(interfaceName: wifi.name, broadcast: true))
            defer { socket.close() }
            try socket.sendNow(payload, to: target, port: port)
        } catch let error as UDPSocketError {
            sendErrno = error.code
        } catch {
            return .unknown
        }
        guard sendErrno != nil else { return .entitled }
        let permission = await LocalNetworkPermissionProbe.check()
        if permission == .undetermined { return .unknown }
        return BroadcastCapabilityStatus.classify(sendErrno: sendErrno, localNetworkDenied: permission == .denied)
    }
}
#endif
