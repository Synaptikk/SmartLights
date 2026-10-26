// simctl: run any fake device from the command line.
//
//   simctl wiz   [--host 0.0.0.0] [--port 38899] [--signing-key <32 hex>] [--module ESP01_SHRGB_03]
//                [--fw 1.25.0] [--mac a8bb5006033d] [--push-port 38900] [--no-push]
//   simctl hue   [--host 0.0.0.0] [--https-port 443] [--http-port 80] [--bridge-id 001788FFFE000001]
//                [--link-button] [--app-key <username>] [--max-concurrent 3] [--delay-ms 0]
//   simctl aidot [--host 0.0.0.0] [--cloud-port 8080] [--udp-port 6666] [--tcp-port 10000]
//                [--advertise-ip 192.168.1.50] [--user-id 1840000000000000001] [--aes-key 0123456789abcdef]
//                [--dev-password devpass-0001]
//
// Runs until interrupted (Ctrl-C).

import Foundation
import Simulators

@main
struct SimCtl {
    static func usage() -> Never {
        print(
            """
            usage: simctl <wiz|hue|aidot> [options]
              wiz   --host H --port P --signing-key HEX --module NAME --fw VER --mac MAC --push-port P --no-push
              hue   --host H --https-port P --http-port P --bridge-id ID --link-button --app-key KEY
                    --max-concurrent N --delay-ms MS
              aidot --host H --cloud-port P --udp-port P --tcp-port P --advertise-ip IP --user-id ID
                    --aes-key KEY --dev-password PW
            """)
        exit(2)
    }

    static func main() async throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let kind = args.first else { usage() }
        args.removeFirst()
        var opts: [String: String] = [:]
        var flags: Set<String> = []
        var i = 0
        while i < args.count {
            let a = args[i]
            guard a.hasPrefix("--") else { usage() }
            let key = String(a.dropFirst(2))
            if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                opts[key] = args[i + 1]
                i += 2
            } else {
                flags.insert(key)
                i += 1
            }
        }
        func int(_ k: String, _ def: Int) -> Int { opts[k].flatMap(Int.init) ?? def }
        let host = opts["host"] ?? "0.0.0.0"
        let runner = SimulatorRunner()

        switch kind {
        case "wiz":
            var cfg = FakeWiZBulb.Configuration()
            cfg.host = host
            cfg.port = int("port", 38899)
            if let m = opts["module"] { cfg.moduleName = m }
            if let f = opts["fw"] { cfg.fwVersion = f }
            if let mac = opts["mac"] { cfg.mac = mac }
            cfg.pushPort = int("push-port", 38900)
            cfg.pushEnabled = !flags.contains("no-push")
            if let hex = opts["signing-key"] {
                guard let key = SimCrypto.hexDecode(hex), key.count == 16 else {
                    print("--signing-key must be 32 hex chars")
                    exit(2)
                }
                cfg.signingKey = key
                cfg.signingMode = true
            }
            let bulb = try await runner.start(FakeWiZBulb(cfg))
            print("FakeWiZBulb \(cfg.moduleName) fw \(cfg.fwVersion) mac \(cfg.mac) on udp \(host):\(bulb.port ?? -1)")
            print("signing mode: \(cfg.signingMode ? "on (Only verified controls)" : "off"); push: \(cfg.pushEnabled ? "to registered phoneIp:\(cfg.pushPort)" : "disabled")")
        case "hue":
            var cfg = FakeHueBridge.Configuration()
            cfg.host = host
            cfg.httpsPort = int("https-port", 443)
            if let p = opts["http-port"].flatMap(Int.init) { cfg.httpPort = p }
            if let id = opts["bridge-id"] { cfg.bridgeId = id }
            cfg.linkButtonPressed = flags.contains("link-button")
            if let k = opts["app-key"] { cfg.appKeys[k] = "" }
            if let n = opts["max-concurrent"].flatMap(Int.init) { cfg.maxConcurrentRequests = n > 0 ? n : nil }
            cfg.responseDelayMs = int("delay-ms", 0)
            let bridge = try await runner.start(try FakeHueBridge(cfg))
            print("FakeHueBridge \(cfg.bridgeId) https \(host):\(bridge.httpsPort ?? -1)" + (bridge.httpPort.map { " http \(host):\($0)" } ?? ""))
            print("press link button: curl -k -X POST https://127.0.0.1:\(bridge.httpsPort ?? 443)/_sim/linkbutton")
            print(bridge.certificate.certificatePEM)
        case "aidot":
            var info = AiDotDeviceInfo()
            if let u = opts["user-id"] { info.ownerUserId = u }
            if let k = opts["aes-key"] { info.aesKey = k }
            if let p = opts["dev-password"] { info.password = p }
            var dcfg = FakeAiDotDevice.Configuration(info: info, host: host, discoveryPort: int("udp-port", 6666), tcpPort: int("tcp-port", 10000))
            dcfg.advertisedIP = opts["advertise-ip"] ?? "127.0.0.1"
            let device = try await runner.start(FakeAiDotDevice(dcfg))
            var ccfg = FakeAiDotCloud.Configuration()
            ccfg.host = host
            ccfg.port = int("cloud-port", 8080)
            ccfg.userId = info.ownerUserId
            let cloud = try await runner.start(FakeAiDotCloud(ccfg, devices: [device]))
            print("FakeAiDotCloud on http://\(host):\(cloud.port ?? -1)/v35 (user \(ccfg.username), any password)")
            print("FakeAiDotDevice \(info.id) udp \(device.discoveryPort ?? -1) tcp \(device.tcpPort ?? -1) advertised \(dcfg.advertisedIP)")
        default:
            usage()
        }
        print("running; Ctrl-C to stop")
        fflush(nil)  // make the banner visible when stdout is redirected
        while true { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
    }
}
