import LightCore
import Observation
import SwiftUI

/// Scan results waiting for the user to pick which devices to add (multi-select), with a manual
/// "Add by IP address" path. `AddBrandActions` awaits `wait()`; the sheet calls `confirm()` /
/// `cancel()`. Devices that are already paired start unticked.
@MainActor
@Observable
final class DeviceSelection: Identifiable {
    struct Candidate: Identifiable, Equatable {
        let device: DiscoveredDevice
        let alreadyAdded: Bool
        var id: String { device.id }
    }

    let id = UUID()
    let brand: Brand
    let allowsManualHost: Bool
    private(set) var candidates: [Candidate]
    var chosen: Set<String>
    var manualHost = ""
    private(set) var isProbing = false
    private(set) var manualError: String?

    @ObservationIgnored private let probe: @MainActor (String) async -> DiscoveredDevice?
    @ObservationIgnored private var continuation: CheckedContinuation<[DiscoveredDevice], any Error>?
    @ObservationIgnored private var result: Result<[DiscoveredDevice], any Error>?

    init(
        brand: Brand,
        devices: [DiscoveredDevice],
        alreadyAdded: Set<String>,
        allowsManualHost: Bool,
        probe: @escaping @MainActor (String) async -> DiscoveredDevice?
    ) {
        self.brand = brand
        self.allowsManualHost = allowsManualHost
        self.probe = probe
        candidates = devices.map { Candidate(device: $0, alreadyAdded: alreadyAdded.contains($0.id)) }
        chosen = Set(devices.filter { !alreadyAdded.contains($0.id) }.map(\.id))
    }

    /// Suspends until the user confirms (selected devices, possibly empty) or cancels (`userCancelled`).
    func wait() async throws -> [DiscoveredDevice] {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func toggle(_ id: String) {
        if chosen.contains(id) { chosen.remove(id) } else { chosen.insert(id) }
    }

    func confirm() {
        finish(.success(candidates.filter { chosen.contains($0.id) }.map(\.device)))
    }

    func cancel() {
        finish(.failure(LightCoreError.userCancelled))
    }

    var trimmedHost: String { manualHost.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Probes the typed address; on success the device is added to the list and ticked.
    func addManualHost() async {
        let host = trimmedHost
        guard !host.isEmpty, !isProbing else { return }
        isProbing = true
        manualError = nil
        let device = await probe(host)
        isProbing = false
        guard let device else {
            manualError = "No \(brand.displayName) device answered at \(host). Check the address and that it is on the same Wi-Fi."
            return
        }
        if !candidates.contains(where: { $0.id == device.id }) {
            candidates.append(Candidate(device: device, alreadyAdded: false))
        }
        chosen.insert(device.id)
        manualHost = ""
    }

    private func finish(_ outcome: Result<[DiscoveredDevice], any Error>) {
        guard result == nil else { return }
        result = outcome
        continuation?.resume(with: outcome)
        continuation = nil
    }
}

/// Sheet listing scan results with checkmarks, plus the manual IP field.
struct DeviceSelectionView: View {
    @Bindable var selection: DeviceSelection

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if selection.candidates.isEmpty {
                        Text("No \(selection.brand.displayName) devices were found. Enter an IP address below, or go back and check the troubleshooting tips.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(selection.candidates) { candidate in
                        row(candidate)
                    }
                } header: {
                    Text(selection.candidates.count == 1 ? "Found 1 device" : "Found \(selection.candidates.count) devices")
                } footer: {
                    if selection.candidates.contains(where: \.alreadyAdded) {
                        Text("Devices you added before are unticked. Tick one to set it up again.")
                    }
                }

                if selection.allowsManualHost {
                    Section {
                        TextField("192.168.1.20", text: $selection.manualHost)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .onSubmit { Task { await selection.addManualHost() } }
                            .accessibilityLabel("IP address")
                        Button {
                            Task { await selection.addManualHost() }
                        } label: {
                            HStack {
                                Text("Check address")
                                if selection.isProbing {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(selection.trimmedHost.isEmpty || selection.isProbing)
                        if let error = selection.manualError {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    } header: {
                        Text("Add by IP address")
                    } footer: {
                        Text("Use this if a device was not found, e.g. when your router blocks discovery.")
                    }
                }
            }
            .navigationTitle("Choose devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { selection.cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selection.chosen.isEmpty ? "Skip" : "Add \(selection.chosen.count)") {
                        selection.confirm()
                    }
                    .bold()
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private func row(_ candidate: DeviceSelection.Candidate) -> some View {
        let isChosen = selection.chosen.contains(candidate.id)
        return Button {
            selection.toggle(candidate.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isChosen ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.device.name)
                        .foregroundStyle(.primary)
                    Text(Self.detail(candidate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .accessibilityHint(isChosen ? "Will be added" : "Will not be added")
    }

    private static func detail(_ candidate: DeviceSelection.Candidate) -> String {
        var parts: [String] = []
        if let model = candidate.device.model, !model.isEmpty { parts.append(model) }
        if let host = candidate.device.host { parts.append(host) }
        parts.append(candidate.device.method.rawValue)
        if candidate.alreadyAdded { parts.append("already added") }
        return parts.joined(separator: " · ")
    }
}

#if DEBUG
#Preview {
    DeviceSelectionView(selection: DeviceSelection(
        brand: .wiz,
        devices: [
            DiscoveredDevice(id: "a8bb5006033d", brand: .wiz, name: "Desk lamp", model: "ESP01_SHRGB1C_31", host: "192.168.1.20", method: .sweep),
            DiscoveredDevice(id: "a8bb5006033e", brand: .wiz, name: "Hall", host: "192.168.1.21", method: .broadcast),
        ],
        alreadyAdded: ["a8bb5006033e"],
        allowsManualHost: true,
        probe: { _ in nil }
    ))
}
#endif
