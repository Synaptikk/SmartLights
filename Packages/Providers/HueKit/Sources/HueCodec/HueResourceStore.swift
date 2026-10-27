import Foundation
import LightCore

/// SSE event kinds (`type` of each event in the `data:` array).
public enum HueEventKind: String, Codable, Sendable, Hashable {
    case add, update, delete, error
}

/// One CLIP v2 event: `{"id","creationtime","type":"update","data":[partial resources]}`.
public struct HueEventMessage: Codable, Sendable, Hashable {
    public var id: String?
    public var creationtime: String?
    /// Raw type; see `kind`.
    public var type: String?
    /// Partial resources ("same format as a GET response on the same resource type",
    /// but only changed properties plus `id`/`type`).
    public var data: [JSONValue]?

    public init(id: String? = nil, creationtime: String? = nil, type: String?, data: [JSONValue]?) {
        self.id = id
        self.creationtime = creationtime
        self.type = type
        self.data = data
    }

    public var kind: HueEventKind? { type.flatMap(HueEventKind.init(rawValue:)) }

    /// Decodes the `data:` payload of one SSE message (a JSON array of events).
    public static func decodeList(_ text: String) throws -> [HueEventMessage] {
        do {
            return try JSONDecoder().decode(LossyArray<HueEventMessage>.self, from: Data(text.utf8)).elements
        } catch {
            throw HueError.invalidResponse("event stream payload is not a JSON array")
        }
    }
}

/// In-memory mirror of a bridge's CLIP v2 resources, updated from GET responses and SSE events.
///
/// Raw JSON is kept per resource so that partial updates merge losslessly; typed views are
/// re-decoded for the resource types SmartLights uses.
public struct HueResourceStore: Sendable, Equatable {
    /// type -> id -> raw resource.
    public private(set) var raw: [String: [String: JSONValue]] = [:]

    public private(set) var lights: [String: HueLight] = [:]
    public private(set) var groupedLights: [String: HueGroupedLight] = [:]
    public private(set) var rooms: [String: HueGroup] = [:]
    public private(set) var zones: [String: HueGroup] = [:]
    public private(set) var scenes: [String: HueScene] = [:]
    public private(set) var devices: [String: HueDevice] = [:]
    public private(set) var bridges: [String: HueBridgeResource] = [:]
    public private(set) var zigbee: [String: HueZigbeeConnectivity] = [:]
    public private(set) var entertainmentConfigurations: [String: HueEntertainmentConfiguration] = [:]
    public private(set) var geofenceClients: [String: HueGeofenceClient] = [:]

    public init() {}

    /// Builds the store from the `data` array of `GET /clip/v2/resource` (or several typed GETs).
    public init(resources: [JSONValue]) {
        for r in resources { upsert(r) }
    }

    /// Decodes a `{"errors":[],"data":[...]}` body.
    public init(envelopeData data: Data) throws {
        let envelope: ResourceEnvelope<[JSONValue]>
        do {
            envelope = try JSONDecoder().decode(ResourceEnvelope<[JSONValue]>.self, from: data)
        } catch {
            throw HueError.invalidResponse("resource list is not a CLIP v2 envelope")
        }
        self.init(resources: envelope.data ?? [])
    }

    // MARK: Mutation

    /// Inserts or replaces a full resource.
    public mutating func upsert(_ resource: JSONValue) {
        guard let type = resource["type"]?.stringValue, let id = resource["id"]?.stringValue else { return }
        raw[type, default: [:]][id] = resource
        refreshTyped(type: type, id: id)
    }

    /// Deep-merges a partial resource into the stored one. Returns false for unknown resources.
    @discardableResult
    public mutating func merge(partial: JSONValue) -> Bool {
        guard let type = partial["type"]?.stringValue, let id = partial["id"]?.stringValue,
            let existing = raw[type]?[id]
        else { return false }
        raw[type]![id] = existing.merging(partial)
        refreshTyped(type: type, id: id)
        return true
    }

    public mutating func remove(type: String, id: String) {
        raw[type]?[id] = nil
        refreshTyped(type: type, id: id)
    }

    private mutating func refreshTyped(type: String, id: String) {
        let value = raw[type]?[id]
        func decode<T: Decodable>(_ t: T.Type) -> T? { value.flatMap { try? $0.decode(T.self) } }
        switch type {
        case HueResourceType.light: lights[id] = decode(HueLight.self)
        case HueResourceType.groupedLight: groupedLights[id] = decode(HueGroupedLight.self)
        case HueResourceType.room: rooms[id] = decode(HueGroup.self)
        case HueResourceType.zone: zones[id] = decode(HueGroup.self)
        case HueResourceType.scene: scenes[id] = decode(HueScene.self)
        case HueResourceType.device: devices[id] = decode(HueDevice.self)
        case HueResourceType.bridge: bridges[id] = decode(HueBridgeResource.self)
        case HueResourceType.zigbeeConnectivity: zigbee[id] = decode(HueZigbeeConnectivity.self)
        case HueResourceType.entertainmentConfiguration:
            entertainmentConfigurations[id] = decode(HueEntertainmentConfiguration.self)
        case HueResourceType.geofenceClient: geofenceClients[id] = decode(HueGeofenceClient.self)
        default: break
        }
    }

    // MARK: Relations

    /// Device that owns a light service.
    public func device(forLight lightID: String) -> HueDevice? {
        if let owner = lights[lightID]?.owner, owner.rtype == HueResourceType.device, let d = devices[owner.rid] {
            return d
        }
        return devices.values.first { $0.serviceIDs(ofType: HueResourceType.light).contains(lightID) }
    }

    /// Light services contained in a room/zone (rooms list devices, zones list lights).
    public func memberLightIDs(of group: HueGroup) -> Set<String> {
        var out: Set<String> = []
        for child in group.children ?? [] {
            switch child.rtype {
            case HueResourceType.light:
                if lights[child.rid] != nil { out.insert(child.rid) }
            case HueResourceType.device:
                for id in devices[child.rid]?.serviceIDs(ofType: HueResourceType.light) ?? [] where lights[id] != nil {
                    out.insert(id)
                }
            default:
                break
            }
        }
        return out
    }

    /// Lights controlled by a `grouped_light` (its owner room/zone, or every light for bridge_home).
    public func memberLightIDs(ofGroupedLight id: String) -> Set<String> {
        guard let owner = groupedLights[id]?.owner else { return [] }
        switch owner.rtype {
        case HueResourceType.room: return rooms[owner.rid].map(memberLightIDs(of:)) ?? []
        case HueResourceType.zone: return zones[owner.rid].map(memberLightIDs(of:)) ?? []
        case HueResourceType.bridgeHome: return Set(lights.keys)
        default: return []
        }
    }

    /// The room containing the light (via its device, or directly).
    public func room(forLight lightID: String) -> HueGroup? {
        let deviceID = device(forLight: lightID)?.id
        return rooms.values.sorted { $0.id < $1.id }.first { room in
            (room.children ?? []).contains { child in
                (child.rtype == HueResourceType.device && child.rid == deviceID)
                    || (child.rtype == HueResourceType.light && child.rid == lightID)
            }
        }
    }

    public func zones(forLight lightID: String) -> [HueGroup] {
        zones.values.filter { memberLightIDs(of: $0).contains(lightID) }.sorted { $0.id < $1.id }
    }

    /// Reachability via the owning device's `zigbee_connectivity` (true when unknown).
    public func isReachable(lightID: String) -> Bool {
        guard let device = device(forLight: lightID) else { return true }
        let ids = device.serviceIDs(ofType: HueResourceType.zigbeeConnectivity)
        let services = ids.compactMap { zigbee[$0] }
        if !services.isEmpty { return services.allSatisfy(\.isConnected) }
        // Fallback: connectivity resources pointing at the device.
        let owned = zigbee.values.filter { $0.owner?.rid == device.id }
        return owned.allSatisfy(\.isConnected)
    }

    /// Lights owned by a device.
    public func lightIDs(ofDevice deviceID: String) -> [String] {
        let fromServices = devices[deviceID]?.serviceIDs(ofType: HueResourceType.light) ?? []
        let fromOwner = lights.values.filter { $0.owner?.rid == deviceID }.map(\.id)
        return Array(Set(fromServices + fromOwner).filter { lights[$0] != nil }).sorted()
    }

    /// The bridge id reported by the `bridge` resource (upper-cased), if present and well-formed.
    public var bridgeID: String? {
        bridges.values.compactMap { $0.bridgeID.flatMap(HueBridgeID.normalize) }.first
    }

    // MARK: LightCore mapping

    public func makeLight(id lightID: String, bridgeID: String, now: Date = Date()) -> Light? {
        guard let light = lights[lightID], let id = HueIdentifiers.lightID(bridgeID: bridgeID, resourceID: lightID)
        else { return nil }
        let device = device(forLight: lightID)
        let name = light.metadata?.name ?? device?.metadata?.name ?? "Hue light"
        let roomHint = room(forLight: lightID)?.metadata?.name ?? zones(forLight: lightID).first?.metadata?.name
        let manufacturer = device?.productData?.manufacturerName
        let isSignify = manufacturer.map { $0.localizedCaseInsensitiveContains("signify") || $0.localizedCaseInsensitiveContains("philips") } ?? true
        return Light(
            id: id,
            name: name,
            roomHint: roomHint,
            capabilities: HueMapping.capabilities(for: light),
            state: HueMapping.state(for: light, reachable: isReachable(lightID: lightID), at: now),
            providerRef: "\(bridgeID)/\(lightID)",
            manufacturer: isSignify ? nil : manufacturer,
            model: device?.productData?.modelID
        )
    }

    public func makeLights(bridgeID: String, now: Date = Date()) -> [Light] {
        lights.keys.sorted().compactMap { makeLight(id: $0, bridgeID: bridgeID, now: now) }
    }

    public func makeScene(id sceneID: String, bridgeID: String) -> LightScene? {
        guard let scene = scenes[sceneID] else { return nil }
        var roomHint: String?
        if let group = scene.group {
            roomHint = (group.rtype == HueResourceType.zone ? zones[group.rid] : rooms[group.rid])?.metadata?.name
        }
        let lightIDs = (scene.actions ?? []).compactMap { action -> LightID? in
            guard let target = action.target, target.rtype == HueResourceType.light else { return nil }
            return HueIdentifiers.lightID(bridgeID: bridgeID, resourceID: target.rid)
        }
        return LightScene(
            id: HueIdentifiers.sceneID(bridgeID: bridgeID, resourceID: sceneID),
            name: scene.metadata?.name ?? "Scene",
            kind: .vendor,
            brand: .hue,
            roomHint: roomHint,
            lightIDs: lightIDs
        )
    }

    public func makeScenes(bridgeID: String) -> [LightScene] {
        scenes.keys.sorted().compactMap { makeScene(id: $0, bridgeID: bridgeID) }
            .sorted { ($0.roomHint ?? "", $0.name) < ($1.roomHint ?? "", $1.name) }
    }

    // MARK: Events

    /// Applies SSE events and returns the resulting provider events.
    public mutating func apply(_ messages: [HueEventMessage], bridgeID: String, now: Date = Date()) -> [ProviderEvent] {
        var out: [ProviderEvent] = []
        for message in messages {
            guard let kind = message.kind else { continue }
            for item in message.data ?? [] {
                out += apply(kind: kind, item: item, bridgeID: bridgeID, now: now)
            }
        }
        return out
    }

    private static let structuralTypes: Set<String> = [
        HueResourceType.room, HueResourceType.zone, HueResourceType.device,
    ]

    private mutating func apply(kind: HueEventKind, item: JSONValue, bridgeID: String, now: Date) -> [ProviderEvent] {
        guard let type = item["type"]?.stringValue, let id = item["id"]?.stringValue else { return [] }
        if kind == .error { return [] }

        let lightsBefore = Self.structuralTypes.contains(type) || type == HueResourceType.zigbeeConnectivity
            ? Dictionary(uniqueKeysWithValues: makeLights(bridgeID: bridgeID, now: now).map { ($0.id, $0) })
            : [:]
        let lightBefore = type == HueResourceType.light ? makeLight(id: id, bridgeID: bridgeID, now: now) : nil
        let sceneBefore = type == HueResourceType.scene ? makeScene(id: id, bridgeID: bridgeID) : nil

        switch kind {
        case .add:
            if raw[type]?[id] != nil { merge(partial: item) } else { upsert(item) }
        case .update:
            guard merge(partial: item) else { return [] }
        case .delete:
            remove(type: type, id: id)
        case .error:
            return []
        }

        var out: [ProviderEvent] = []
        switch type {
        case HueResourceType.light:
            let after = makeLight(id: id, bridgeID: bridgeID, now: now)
            switch (lightBefore, after) {
            case (nil, let a?): out.append(.lightAdded(a))
            case (let b?, nil): out.append(.lightRemoved(b.id))
            case (let b?, let a?):
                if !Self.sameState(b.state, a.state) { out.append(.stateChanged(a.id, a.state)) }
                if Self.descriptorChanged(b, a) { out.append(.lightUpdated(a)) }
            case (nil, nil): break
            }
        case HueResourceType.scene:
            let after = makeScene(id: id, bridgeID: bridgeID)
            if sceneBefore != after { out.append(.scenesChanged) }
        case HueResourceType.zigbeeConnectivity:
            for light in makeLights(bridgeID: bridgeID, now: now) {
                if let before = lightsBefore[light.id], before.state.reachable != light.state.reachable {
                    out.append(.reachabilityChanged(light.id, reachable: light.state.reachable))
                }
            }
        case _ where Self.structuralTypes.contains(type):
            for light in makeLights(bridgeID: bridgeID, now: now) {
                if let before = lightsBefore[light.id], Self.descriptorChanged(before, light) {
                    out.append(.lightUpdated(light))
                }
            }
            if type != HueResourceType.device, kind != .update || item["metadata"] != nil {
                // Room/zone renamed or deleted: scene room hints change too.
                if scenes.values.contains(where: { $0.group?.rid == id }) { out.append(.scenesChanged) }
            }
        default:
            break
        }
        return out
    }

    // MARK: Resync

    /// Events that turn `old` into `new` (used after an event-stream gap > 60 s).
    public static func diff(from old: HueResourceStore, to new: HueResourceStore, bridgeID: String, now: Date = Date())
        -> [ProviderEvent]
    {
        var out: [ProviderEvent] = []
        let before = Dictionary(uniqueKeysWithValues: old.makeLights(bridgeID: bridgeID, now: now).map { ($0.id, $0) })
        let after = Dictionary(uniqueKeysWithValues: new.makeLights(bridgeID: bridgeID, now: now).map { ($0.id, $0) })
        for id in before.keys.sorted() where after[id] == nil { out.append(.lightRemoved(id)) }
        for id in after.keys.sorted() {
            let a = after[id]!
            guard let b = before[id] else {
                out.append(.lightAdded(a))
                continue
            }
            if Self.descriptorChanged(b, a) { out.append(.lightUpdated(a)) }
            if b.state.reachable != a.state.reachable {
                out.append(.reachabilityChanged(id, reachable: a.state.reachable))
            }
            if !sameState(b.state, a.state) { out.append(.stateChanged(id, a.state)) }
        }
        if old.makeScenes(bridgeID: bridgeID) != new.makeScenes(bridgeID: bridgeID) { out.append(.scenesChanged) }
        return out
    }

    /// State equality ignoring `updatedAt`.
    public static func sameState(_ a: LightState, _ b: LightState) -> Bool {
        var a2 = a
        a2.updatedAt = b.updatedAt
        return a2 == b
    }

    static func descriptorChanged(_ a: Light, _ b: Light) -> Bool {
        a.name != b.name || a.roomHint != b.roomHint || a.capabilities != b.capabilities || a.model != b.model
    }
}

// MARK: - Group planning

/// How to execute a command for a set of lights on one bridge: whole rooms/zones via their
/// `grouped_light` (1 request, 1/s limit), the rest one by one (10/s per light).
public struct HueGroupPlan: Sendable, Equatable {
    public struct GroupedTarget: Sendable, Equatable {
        public var groupedLightID: String
        public var lightIDs: Set<String>

        public init(groupedLightID: String, lightIDs: Set<String>) {
            self.groupedLightID = groupedLightID
            self.lightIDs = lightIDs
        }
    }

    public var grouped: [GroupedTarget]
    public var individual: [String]

    public init(grouped: [GroupedTarget], individual: [String]) {
        self.grouped = grouped
        self.individual = individual
    }

    /// Greedy cover: largest room/zone/bridge_home groups (>= 2 lights) whose member set is fully
    /// targeted are used first; leftovers are sent individually.
    public static func make(targets: Set<String>, store: HueResourceStore) -> HueGroupPlan {
        var remaining = targets
        var grouped: [GroupedTarget] = []
        let candidates = store.groupedLights.keys.sorted().compactMap { id -> GroupedTarget? in
            let members = store.memberLightIDs(ofGroupedLight: id)
            return members.count >= 2 ? GroupedTarget(groupedLightID: id, lightIDs: members) : nil
        }
        .sorted { ($0.lightIDs.count, $1.groupedLightID) > ($1.lightIDs.count, $0.groupedLightID) }
        for candidate in candidates where candidate.lightIDs.isSubset(of: remaining) {
            grouped.append(candidate)
            remaining.subtract(candidate.lightIDs)
        }
        return HueGroupPlan(grouped: grouped, individual: remaining.sorted())
    }
}
