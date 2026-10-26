import LightCore
import NetKit
import SwiftUI
import UIKit

/// Settings > Diagnostics content. Knows nothing about `AppModel`; it gets a `DiagnosticsContext`
/// from `DiagnosticsView` (or `.empty` in previews).
struct DiagnosticsScreen: View {
    let context: DiagnosticsContext

    @State private var model = DiagnosticsModel()
    @State private var pendingTest: Light?
    @Environment(\.openURL) private var openURL

    private var collector: DiagnosticsCollector { DiagnosticsCollector.shared }

    var body: some View {
        List {
            permissionsSection
            networkSection
            bonjourSection
            providersSection
            devicesSection
            logsSection
        }
        .navigationTitle("Diagnostics")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Run all", systemImage: "arrow.clockwise") {
                    model.runAll(registry: context.registry)
                }
            }
        }
        .refreshable {
            model.runAll(registry: context.registry)
        }
        .task {
            if !model.hasRun { model.runAll(registry: context.registry) }
        }
        .onDisappear {
            model.cancelAll()
        }
        .confirmationDialog(
            "Send test command?",
            isPresented: Binding(
                get: { pendingTest != nil },
                set: { if !$0 { pendingTest = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingTest
        ) { light in
            Button("Toggle \(light.name) twice") {
                model.sendTestCommand(to: light, registry: context.registry, collector: collector)
                pendingTest = nil
            }
            Button("Cancel", role: .cancel) { pendingTest = nil }
        } message: { light in
            Text("\(light.name) will switch \(light.state.isOn ? "off and on" : "on and off") twice, about one second apart, and end in its current state.")
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        Section {
            LabeledContent("Local Network") {
                HStack(spacing: 6) {
                    if model.checkingLocalNetwork { ProgressView().controlSize(.small) }
                    Text(DiagnosticsFormat.permission(model.localNetwork))
                        .foregroundStyle(permissionColor)
                }
            }
            Button("Re-check Local Network") { model.checkLocalNetwork() }
                .disabled(model.checkingLocalNetwork)
            Button("Trigger permission prompt") { model.triggerLocalNetworkPrompt() }
                .disabled(model.checkingLocalNetwork)
            if model.localNetwork == .denied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            LabeledContent("HomeKit entitlement", value: DiagnosticsFormat.yesNo(model.entitlements?.homeKit))
        } header: {
            Text("Permissions")
        } footer: {
            Text("Local Network is set in Settings > Privacy & Security > Local Network > SmartLights. HomeKit authorization is shown by the Apple Home provider once it is set up.")
        }
    }

    private var permissionColor: Color {
        switch model.localNetwork {
        case .granted: .green
        case .denied: .red
        case .undetermined, nil: .secondary
        }
    }

    // MARK: - Network

    private var networkSection: some View {
        Section {
            if let network = model.network {
                LabeledContent("Interface", value: network.interfaceName ?? "No Wi-Fi")
                LabeledContent("IPv4", value: network.address ?? "-")
                LabeledContent("Subnet", value: network.subnet ?? "-")
                LabeledContent("Directed broadcast", value: network.directedBroadcast ?? "-")
                if !network.otherInterfaces.isEmpty {
                    LabeledContent("Other LAN interfaces", value: network.otherInterfaces.joined(separator: "\n"))
                }
            } else {
                LabeledContent("Interface", value: "Reading...")
            }
            LabeledContent("Multicast entitlement") {
                VStack(alignment: .trailing) {
                    Text(DiagnosticsFormat.yesNo(model.entitlements?.multicast))
                    if let source = model.entitlements?.source {
                        Text(source.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Broadcast") {
                HStack(spacing: 6) {
                    if model.checkingBroadcast { ProgressView().controlSize(.small) }
                    Text(DiagnosticsFormat.broadcast(model.broadcast))
                        .multilineTextAlignment(.trailing)
                }
            }
            Button("Re-test network") {
                model.refreshNetwork()
                model.checkBroadcast()
            }
            .disabled(model.checkingBroadcast)
        } header: {
            Text("Network")
        } footer: {
            Text("Without the multicast entitlement, lights are found by unicast sweep of the subnet or by entering an IP address.")
        }
    }

    // MARK: - Bonjour

    private var bonjourSection: some View {
        Section {
            ForEach(model.bonjour) { result in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(result.type).font(.body.monospaced())
                        Spacer()
                        Text(result.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    ForEach(result.services, id: \.self) { service in
                        VStack(alignment: .leading) {
                            Text(service.name).font(.callout)
                            Text(Self.endpoint(service))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 8)
                    }
                }
            }
            Button(model.browsing ? "Browsing..." : "Browse again (5 s)") { model.browseBonjour() }
                .disabled(model.browsing)
        } header: {
            Text("Bonjour")
        }
    }

    // MARK: - Providers

    private var providersSection: some View {
        let brands = DiagnosticsReport.providerBrands(model: model, context: context, collector: collector)
        return Section {
            if context.registry == nil {
                Text("Provider registry not available").foregroundStyle(.secondary)
            } else if brands.isEmpty {
                Text("No brands set up yet").foregroundStyle(.secondary)
            }
            ForEach(brands, id: \.self) { brand in
                let sample = collector.providers[brand]
                let count = context.lights.filter { $0.brand == brand }.count
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(brand.displayName).font(.headline)
                        Spacer()
                        Text("\(count) device\(count == 1 ? "" : "s")").foregroundStyle(.secondary)
                    }
                    Text(DiagnosticsFormat.connection(sample)).font(.caption)
                    if !model.registeredBrands.contains(brand) {
                        Text("Not registered").font(.caption).foregroundStyle(.orange)
                    }
                    if sample?.needsReauthentication == true {
                        Text("Needs sign-in again").font(.caption).foregroundStyle(.orange)
                    }
                    if let error = sample?.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        } header: {
            Text("Providers")
        }
    }

    // MARK: - Devices

    private var devicesSection: some View {
        Section {
            if context.lights.isEmpty {
                Text("No lights yet").foregroundStyle(.secondary)
            }
            ForEach(DiagnosticsReport.sortedLights(context.lights)) { light in
                deviceRow(light)
            }
        } header: {
            Text("Devices")
        }
    }

    private func deviceRow(_ light: Light) -> some View {
        let sample = collector.devices[light.id]
        let lastSeen = sample?.lastSeen ?? light.state.updatedAt
        let state = model.testRuns[light.id]
        let isTesting = state?.isRunning ?? false
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(light.name).font(.headline)
                Spacer()
                Text(light.brand.displayName).font(.caption).foregroundStyle(.secondary)
            }
            Text(light.id.rawValue)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                Text("Seen \(lastSeen, format: .relative(presentation: .named))")
                Text("Latency \(sample?.lastLatency.map(DiagnosticsFormat.latency) ?? "-")")
            }
            .font(.caption)
            if sample?.reachable == false || !light.state.reachable {
                Text("Unreachable").font(.caption).foregroundStyle(.orange)
            }
            if let error = sample?.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if let text = DiagnosticsFormat.testState(state) {
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
            Button("Send test command") { pendingTest = light }
                .font(.callout)
                .buttonStyle(.borderless)
                .disabled(context.registry == nil || isTesting)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Logs

    private var logsSection: some View {
        Section {
            HStack {
                Button(model.loadingLogs ? "Loading..." : "Reload logs") { model.loadLogs() }
                    .disabled(model.loadingLogs)
                    .buttonStyle(.borderless)
                Spacer()
                Button("Clear in-app log", role: .destructive) { model.clearInAppLog() }
                    .buttonStyle(.borderless)
            }
            if let error = model.logError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if model.logLines.isEmpty {
                Text("No log entries").foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.logLines.suffix(100).reversed())) { line in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(line.date, format: .dateTime.hour().minute().second()) \(line.level) \(line.category)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(line.level == "ERROR" || line.level == "FAULT" ? .red : .secondary)
                        Text(line.message)
                            .font(.caption.monospaced())
                            .lineLimit(4)
                    }
                }
            }

            Button {
                model.export(context: context, collector: collector)
            } label: {
                HStack {
                    Label("Build export bundle", systemImage: "doc.text")
                    if model.exporting {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(model.exporting)

            if let url = model.exportURL {
                ShareLink(item: url, preview: SharePreview("SmartLights diagnostics")) {
                    Label("Share diagnostics", systemImage: "square.and.arrow.up")
                }
            }
            if let error = model.exportError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Logs (\(model.logLines.count))")
        } footer: {
            Text("The export contains device and app versions, every section above and recent logs. Passwords, tokens, keys and e-mail addresses are redacted.")
        }
    }
}

#Preview {
    NavigationStack {
        DiagnosticsScreen(context: .empty)
    }
}

extension DiagnosticsScreen {
    static func endpoint(_ service: BonjourService) -> String {
        let host = service.host ?? "unresolved"
        guard let port = service.port else { return host }
        return "\(host):\(port)"
    }
}

extension TestCommandState {
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
