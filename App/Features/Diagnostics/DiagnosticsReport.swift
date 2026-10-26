import Foundation
import LightCore
import NetKit

/// Builds the plain-text diagnostics bundle exported from Settings > Diagnostics.
/// The text is redacted by the caller (`DiagnosticsRedactor`) before it is written.
enum DiagnosticsReport {
    @MainActor
    static func build(model: DiagnosticsModel, context: DiagnosticsContext, collector: DiagnosticsCollector) -> String {
        var out: [String] = []
        func section(_ title: String) {
            out.append("")
            out.append("== \(title) ==")
        }
        func row(_ label: String, _ value: String) {
            out.append("\(label): \(value)")
        }

        out.append("SmartLights diagnostics")
        row("Generated", DiagnosticsFormat.timestamp(Date()))

        section("Device")
        row("Model identifier", machineIdentifier())
        row("OS", ProcessInfo.processInfo.operatingSystemVersionString)
        let info = Bundle.main.infoDictionary
        row("App version", "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))")
        row("Bundle id", Bundle.main.bundleIdentifier ?? "?")
        #if targetEnvironment(simulator)
        row("Environment", "Simulator")
        #else
        row("Environment", "Device")
        #endif
        row("Locale", Locale.current.identifier)
        row("Time zone", TimeZone.current.identifier)

        section("Permissions")
        row("Local Network", DiagnosticsFormat.permission(model.localNetwork))
        row("HomeKit entitlement", DiagnosticsFormat.yesNo(model.entitlements?.homeKit))

        section("Network")
        if let network = model.network {
            row("Interface", network.interfaceName ?? "none (no Wi-Fi)")
            row("IPv4", network.address ?? "-")
            row("Subnet", network.subnet ?? "-")
            row("Netmask", network.netmask ?? "-")
            row("Directed broadcast", network.directedBroadcast ?? "-")
            row("Other LAN interfaces", network.otherInterfaces.isEmpty ? "none" : network.otherInterfaces.joined(separator: ", "))
        } else {
            row("Interface", "not captured")
        }
        row("Multicast entitlement present", DiagnosticsFormat.yesNo(model.entitlements?.multicast))
        if let entitlements = model.entitlements {
            row("Entitlements source", entitlements.source.rawValue)
            if let note = entitlements.note { row("Entitlements note", note) }
            row("Entitlement names", entitlements.keys.isEmpty ? "-" : entitlements.keys.joined(separator: ", "))
        }
        row("Broadcast working", DiagnosticsFormat.broadcast(model.broadcast))

        section("Bonjour (\(DiagnosticsModel.bonjourTypes.count) types, \(DiagnosticsModel.bonjourDuration))")
        for result in model.bonjour {
            row(result.type, result.status)
            for service in result.services {
                let host = service.host ?? "?"
                let port = service.port.map { String($0) } ?? "?"
                let txt = service.txt.keys.sorted().map { "\($0)=\(service.txt[$0] ?? "")" }.joined(separator: " ")
                out.append("  - \(service.name) \(host):\(port)\(txt.isEmpty ? "" : " txt: \(txt)")")
            }
        }

        section("Providers")
        let brands = providerBrands(model: model, context: context, collector: collector)
        if brands.isEmpty { out.append("none registered") }
        for brand in brands {
            let sample = collector.providers[brand]
            let count = context.lights.filter { $0.brand == brand }.count
            out.append("\(brand.displayName) [\(brand.rawValue)]")
            row("  registered", model.registeredBrands.contains(brand) ? "yes" : "no")
            row("  connection", DiagnosticsFormat.connection(sample))
            row("  devices", "\(count)")
            row("  events", "\(sample?.eventCount ?? 0), last \(DiagnosticsFormat.timestamp(sample?.lastEventAt))")
            if sample?.needsReauthentication == true { row("  needs sign-in", "yes") }
            if let error = sample?.lastError {
                row("  last error", "\(error) at \(DiagnosticsFormat.timestamp(sample?.lastErrorAt))")
            }
        }

        section("Devices (\(context.lights.count))")
        for light in sortedLights(context.lights) {
            let sample = collector.devices[light.id]
            out.append("\(light.name) [\(light.brand.displayName)] \(light.id)")
            if let modelID = light.model { row("  model", modelID) }
            if let manufacturer = light.manufacturer { row("  manufacturer", manufacturer) }
            row("  state", "\(light.state.isOn ? "on" : "off"), reachable \(sample?.reachable ?? light.state.reachable)")
            row("  last seen", DiagnosticsFormat.timestamp(sample?.lastSeen ?? light.state.updatedAt))
            row("  last latency", sample?.lastLatency.map(DiagnosticsFormat.latency) ?? "-")
            row("  avg latency", sample?.averageLatency.map(DiagnosticsFormat.latency) ?? "-")
            row("  commands/errors", "\(sample?.commandCount ?? 0)/\(sample?.errorCount ?? 0)")
            if let error = sample?.lastError {
                row("  last error", "\(error) at \(DiagnosticsFormat.timestamp(sample?.lastErrorAt))")
            }
            if let test = DiagnosticsFormat.testState(model.testRuns[light.id]) { row("  test", test) }
        }

        section("Logs (\(model.logLines.count) lines)")
        if let error = model.logError { row("OSLog", error) }
        for line in model.logLines { out.append(line.formatted) }

        out.append("")
        out.append("(Secrets are redacted before export.)")
        return out.joined(separator: "\n")
    }

    /// Writes `text` to a fresh temporary file. Nonisolated, synchronous I/O: call it detached.
    static func write(_ text: String) -> URL? {
        let stamp = Date().formatted(Date.ISO8601FormatStyle())
            .replacingOccurrences(of: ":", with: "")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Keep only the latest bundle.
            if let old = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for file in old { try? FileManager.default.removeItem(at: file) }
            }
            let url = directory.appendingPathComponent("SmartLights-diagnostics-\(stamp).txt")
            try Data(text.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    @MainActor
    static func providerBrands(model: DiagnosticsModel, context: DiagnosticsContext, collector: DiagnosticsCollector) -> [Brand] {
        var brands = Set(model.registeredBrands)
        brands.formUnion(collector.providers.keys)
        brands.formUnion(context.lights.map(\.brand))
        return brands.sorted()
    }

    static func sortedLights(_ lights: [Light]) -> [Light] {
        lights.sorted { lhs, rhs in
            if lhs.brand != rhs.brand { return lhs.brand < rhs.brand }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// e.g. "iPhone16,2" (`hw.machine`); on the simulator the simulated model.
    static func machineIdentifier() -> String {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        #endif
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

}
