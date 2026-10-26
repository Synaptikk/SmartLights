// NetKitDemo: lists Bonjour services (and local interfaces) on macOS.
// Usage: swift run NetKitDemo [seconds] [service types...]
//   e.g. swift run NetKitDemo 5 _hue._tcp _nanoleafapi._tcp
#if canImport(Network) && canImport(Darwin)
import Foundation
import NetKit

func run() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let seconds = arguments.first.flatMap { Int($0) } ?? 5
    let explicitTypes = arguments.filter { $0.hasPrefix("_") }
    let types = explicitTypes.isEmpty
        ? ["_hue._tcp", "_nanoleafapi._tcp", "_elg._tcp", "_shelly._tcp", "_wled._tcp", "_http._tcp"]
        : explicitTypes

    print("Interfaces:")
    for interface in InterfaceInfo.localNetworkInterfaces() {
        print("  \(interface) broadcast=\(interface.directedBroadcast.map { "\($0)" } ?? "-")")
    }
    if let wifi = InterfaceInfo.currentWiFi() {
        print("Wi-Fi: \(wifi.name) \(wifi.address) sweep hosts=\(wifi.sweepHosts.count)")
    }
    let capability = await BroadcastCapability.detect()
    print("Broadcast capability: \(capability.rawValue)")
    print("Browsing \(types.joined(separator: ", ")) for \(seconds) s...")

    await withTaskGroup(of: Void.self) { group in
        for type in types {
            group.addTask {
                let stream = BonjourBrowser.browse(type: type)
                let browse = Task {
                    for await event in stream {
                        switch event {
                        case .added(let service): print("+ \(service)")
                        case .removed(let service): print("- \(service.name) [\(service.type)]")
                        case .policyDenied: print("! \(type): policy denied (Local Network / NSBonjourServices)")
                        case .failed(let message): print("! \(type): \(message)")
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(seconds))
                browse.cancel()
            }
        }
    }
    print("Done.")
}

await run()
#else
print("NetKitDemo requires Apple's Network framework (macOS/iOS).")
#endif
