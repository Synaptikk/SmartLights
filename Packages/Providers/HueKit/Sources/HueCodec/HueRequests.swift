import Foundation

// CLIP v2 request bodies. Optional properties are omitted from the JSON when nil.

/// `PUT /clip/v2/resource/light/{id}` and `.../grouped_light/{id}` body.
/// On, brightness and colour travel in one request (no intermediate flash).
public struct HueLightUpdate: Codable, Sendable, Hashable {
    public struct On: Codable, Sendable, Hashable {
        public var on: Bool
        public init(on: Bool) { self.on = on }
    }

    public struct Dimming: Codable, Sendable, Hashable {
        /// 0...100.
        public var brightness: Double
        public init(brightness: Double) { self.brightness = brightness }
    }

    public struct Color: Codable, Sendable, Hashable {
        public var xy: HueXY
        public init(xy: HueXY) { self.xy = xy }
    }

    public struct ColorTemperature: Codable, Sendable, Hashable {
        public var mirek: Int
        public init(mirek: Int) { self.mirek = mirek }
    }

    public struct Dynamics: Codable, Sendable, Hashable {
        /// Transition time in milliseconds.
        public var duration: Int
        public init(duration: Int) { self.duration = duration }
    }

    public struct Effects: Codable, Sendable, Hashable {
        /// One of the light's `effects.effect_values`, `"no_effect"` to stop.
        public var effect: String
        public init(effect: String) { self.effect = effect }
    }

    public var on: On?
    public var dimming: Dimming?
    public var color: Color?
    public var colorTemperature: ColorTemperature?
    public var dynamics: Dynamics?
    public var effects: Effects?

    enum CodingKeys: String, CodingKey {
        case on, dimming, color, dynamics, effects
        case colorTemperature = "color_temperature"
    }

    public init(
        on: Bool? = nil, brightness: Double? = nil, xy: HueXY? = nil, mirek: Int? = nil,
        durationMilliseconds: Int? = nil, effect: String? = nil
    ) {
        self.on = on.map(On.init(on:))
        self.dimming = brightness.map(Dimming.init(brightness:))
        self.color = xy.map(Color.init(xy:))
        self.colorTemperature = mirek.map(ColorTemperature.init(mirek:))
        self.dynamics = durationMilliseconds.map(Dynamics.init(duration:))
        self.effects = effect.map(Effects.init(effect:))
    }

    /// True when nothing but (maybe) a duration would be sent.
    public var isEmpty: Bool {
        on == nil && dimming == nil && color == nil && colorTemperature == nil && effects == nil
    }

    /// Compact JSON (sorted keys for stable tests/logs).
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// Scene recall actions (`recall.action`).
public enum HueSceneRecallAction: String, Codable, Sendable, Hashable, CaseIterable {
    /// Recall the scene's static state.
    case active
    /// Recall and start cycling through the scene's palette.
    case dynamicPalette = "dynamic_palette"
    /// Static recall that also stops dynamics (newer firmware).
    case `static`
}

/// `PUT /clip/v2/resource/scene/{id}` body: `{"recall":{"action":"active"}}`.
public struct HueSceneRecall: Codable, Sendable, Hashable {
    public struct Recall: Codable, Sendable, Hashable {
        public var action: HueSceneRecallAction
        /// Transition in ms.
        public var duration: Int?
        public var dimming: HueLightUpdate.Dimming?
    }

    public var recall: Recall

    public init(action: HueSceneRecallAction = .active, durationMilliseconds: Int? = nil, brightness: Double? = nil) {
        recall = Recall(action: action, duration: durationMilliseconds, dimming: brightness.map(HueLightUpdate.Dimming.init))
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// `POST /clip/v2/resource/geofence_client` and the rename `PUT` used as SSE keep-alive.
public struct HueGeofenceClientBody: Codable, Sendable, Hashable {
    public var type: String?
    public var name: String

    /// Create body (`type` is required by POST).
    public static func create(name: String) -> HueGeofenceClientBody {
        HueGeofenceClientBody(type: HueResourceType.geofenceClient, name: name)
    }

    /// Rename body.
    public static func rename(name: String) -> HueGeofenceClientBody {
        HueGeofenceClientBody(type: nil, name: name)
    }

    /// Name prefix of SmartLights' keep-alive client.
    public static let namePrefix = "smartlights_"

    /// `smartlights_<random>` (22 characters).
    public static func randomName() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let suffix = String((0..<10).map { _ in alphabet.randomElement()! })
        return namePrefix + suffix
    }
}

/// `PUT /clip/v2/resource/entertainment_configuration/{id}` body: `{"action":"start"}` opens the
/// bridge's DTLS server on UDP 2100 for this area, `{"action":"stop"}` ends streaming and lets the
/// lights return to their previous state.
public struct HueEntertainmentAction: Codable, Sendable, Hashable {
    public enum Action: String, Codable, Sendable {
        case start, stop
    }

    public var action: Action

    public static let start = HueEntertainmentAction(action: .start)
    public static let stop = HueEntertainmentAction(action: .stop)

    public init(action: Action) { self.action = action }

    public func jsonData() throws -> Data { try JSONEncoder().encode(self) }
}
