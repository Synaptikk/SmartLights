import Foundation

/// A provider event tagged with its brand.
public struct RegistryEvent: Sendable, Equatable {
    public let brand: Brand
    public let event: ProviderEvent

    public init(brand: Brand, event: ProviderEvent) {
        self.brand = brand
        self.event = event
    }
}

/// Holds one provider per brand, routes commands by `LightID.brand`, and merges provider
/// event streams into `events`.
public actor ProviderRegistry {
    private var providers: [Brand: any LightProvider] = [:]
    private var forwarders: [Brand: Task<Void, Never>] = [:]
    private let continuation: AsyncStream<RegistryEvent>.Continuation

    /// Merged events of all registered providers. Single consumer (the app's state store).
    public nonisolated let events: AsyncStream<RegistryEvent>

    public init() {
        (events, continuation) = AsyncStream.makeStream(of: RegistryEvent.self, bufferingPolicy: .bufferingNewest(1024))
    }

    deinit {
        for task in forwarders.values { task.cancel() }
        continuation.finish()
    }

    /// Registers (or replaces) the provider for its brand and starts forwarding its events.
    public func register(_ provider: any LightProvider) async {
        let brand = provider.brand
        unregister(brand)
        providers[brand] = provider
        let stream = await provider.events
        let continuation = self.continuation
        forwarders[brand] = Task {
            for await event in stream {
                continuation.yield(RegistryEvent(brand: brand, event: event))
            }
        }
    }

    /// Removes a provider and stops forwarding its events.
    public func unregister(_ brand: Brand) {
        forwarders.removeValue(forKey: brand)?.cancel()
        providers.removeValue(forKey: brand)
    }

    public func provider(for brand: Brand) -> (any LightProvider)? { providers[brand] }

    public var registeredBrands: [Brand] { providers.keys.sorted() }

    /// Routes a command to the provider owning `light`.
    public func send(_ command: LightCommand, to light: LightID) async throws {
        guard let provider = providers[light.brand] else { throw LightCoreError.providerNotRegistered(light.brand) }
        try await provider.send(command, to: light)
    }

    /// Splits `lights` by brand and sends to each provider concurrently (each provider may use
    /// a native group). Throws `.partialFailure` listing the lights that failed.
    public func sendGroup(_ command: LightCommand, to lights: [LightID]) async throws {
        let byBrand = Dictionary(grouping: lights, by: \.brand)
        var failures: [LightID: String] = [:]
        var jobs: [(any LightProvider, [LightID])] = []
        for (brand, ids) in byBrand {
            if let provider = providers[brand] {
                jobs.append((provider, ids))
            } else {
                for id in ids { failures[id] = LightCoreError.providerNotRegistered(brand).localizedDescription }
            }
        }
        let results = await withTaskGroup(of: [LightID: String].self) { group in
            for (provider, ids) in jobs {
                group.addTask {
                    do {
                        try await provider.sendGroup(command, to: ids)
                        return [:]
                    } catch let LightCoreError.partialFailure(f) {
                        return f
                    } catch {
                        return Dictionary(uniqueKeysWithValues: ids.map { ($0, String(describing: error)) })
                    }
                }
            }
            var merged: [LightID: String] = [:]
            for await partial in group { merged.merge(partial) { a, _ in a } }
            return merged
        }
        failures.merge(results) { a, _ in a }
        if !failures.isEmpty { throw LightCoreError.partialFailure(failures) }
    }

    /// Loads lights from every provider concurrently. Failing providers are reported, not fatal.
    public func loadAllLights() async -> (lights: [Light], failures: [Brand: String]) {
        let all = Array(providers.values)
        return await withTaskGroup(of: (Brand, Result<[Light], any Error>).self) { group in
            for provider in all {
                group.addTask {
                    do { return (provider.brand, .success(try await provider.loadLights())) } catch { return (provider.brand, .failure(error)) }
                }
            }
            var lights: [Light] = []
            var failures: [Brand: String] = [:]
            for await (brand, result) in group {
                switch result {
                case .success(let l): lights.append(contentsOf: l)
                case .failure(let e): failures[brand] = String(describing: e)
                }
            }
            lights.sort { $0.id < $1.id }
            return (lights, failures)
        }
    }

    /// Recalls a vendor scene through its brand's provider, or replays an app scene.
    public func recall(_ scene: LightScene) async throws {
        switch scene.kind {
        case .vendor:
            guard let brand = scene.brand, let provider = providers[brand] else {
                throw LightCoreError.unsupported("scene \(scene.id) has no registered provider")
            }
            try await provider.recall(scene.id)
        case .app:
            var failures: [LightID: String] = [:]
            for (id, command) in scene.commands.sorted(by: { $0.key < $1.key }) {
                do { try await send(command, to: id) } catch { failures[id] = String(describing: error) }
            }
            if !failures.isEmpty { throw LightCoreError.partialFailure(failures) }
        }
    }
}
