import Foundation

// Nanoleaf Open API (v1) response models. Every field is optional and decoding is lenient: firmware
// across Light Panels (NL22), Canvas (NL29), Shapes (NL42), Elements (NL52) and Lines (NL59) differs
// in which keys it returns. Unknown keys are ignored.

/// `{"value": 50, "min": 0, "max": 100}` (brightness, hue, sat, ct, globalOrientation).
public struct NanoleafRange: Codable, Sendable, Hashable {
    public var value: Int
    public var min: Int?
    public var max: Int?

    public init(value: Int, min: Int? = nil, max: Int? = nil) {
        self.value = value
        self.min = min
        self.max = max
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        value = try c.decodeLenientInt(.value) ?? 0
        min = try c.decodeLenientInt(.min)
        max = try c.decodeLenientInt(.max)
    }

    /// `min...max` when both are present and ordered.
    public var range: ClosedRange<Int>? {
        guard let min, let max, min < max else { return nil }
        return min...max
    }
}

/// `{"value": true}`.
public struct NanoleafBoolValue: Codable, Sendable, Hashable {
    public var value: Bool

    public init(value: Bool) { self.value = value }
}

/// `state.colorMode`: `"hs"`, `"ct"` or `"effect"`.
public enum NanoleafColorMode: String, Codable, Sendable, Hashable {
    case hs
    case ct
    case effect
}

/// `state` object of `GET /api/v1/{token}/`.
public struct NanoleafState: Codable, Sendable, Hashable {
    public var on: NanoleafBoolValue?
    public var brightness: NanoleafRange?
    public var hue: NanoleafRange?
    public var sat: NanoleafRange?
    public var ct: NanoleafRange?
    /// Raw `colorMode` (kept as a string so unknown future modes still decode).
    public var colorMode: String?

    public init(
        on: NanoleafBoolValue? = nil,
        brightness: NanoleafRange? = nil,
        hue: NanoleafRange? = nil,
        sat: NanoleafRange? = nil,
        ct: NanoleafRange? = nil,
        colorMode: String? = nil
    ) {
        self.on = on
        self.brightness = brightness
        self.hue = hue
        self.sat = sat
        self.ct = ct
        self.colorMode = colorMode
    }

    public var mode: NanoleafColorMode? { colorMode.flatMap(NanoleafColorMode.init(rawValue:)) }
}

/// `effects` object: the selected effect and the names of all effects stored on the controller.
public struct NanoleafEffects: Codable, Sendable, Hashable {
    /// Selected effect. Special values: `*Solid*` (plain colour), `*Static*`, `*Dynamic*` (transient
    /// app-pushed effects).
    public var select: String?
    public var effectsList: [String]?

    public init(select: String? = nil, effectsList: [String]? = nil) {
        self.select = select
        self.effectsList = effectsList
    }
}

/// One panel in `panelLayout.layout.positionData`.
public struct NanoleafPanelPosition: Codable, Sendable, Hashable {
    public var panelId: Int
    public var x: Int
    public var y: Int
    /// Orientation in degrees.
    public var o: Int
    /// Shape type (0 triangle, 1 rhythm, 2 square, 3 control square, 7 hexagon, ...); absent on old firmware.
    public var shapeType: Int?

    public init(panelId: Int, x: Int, y: Int, o: Int, shapeType: Int? = nil) {
        self.panelId = panelId
        self.x = x
        self.y = y
        self.o = o
        self.shapeType = shapeType
    }
}

public struct NanoleafLayout: Codable, Sendable, Hashable {
    public var numPanels: Int?
    public var sideLength: Int?
    public var positionData: [NanoleafPanelPosition]?

    public init(numPanels: Int? = nil, sideLength: Int? = nil, positionData: [NanoleafPanelPosition]? = nil) {
        self.numPanels = numPanels
        self.sideLength = sideLength
        self.positionData = positionData
    }
}

public struct NanoleafPanelLayout: Codable, Sendable, Hashable {
    public var globalOrientation: NanoleafRange?
    public var layout: NanoleafLayout?

    public init(globalOrientation: NanoleafRange? = nil, layout: NanoleafLayout? = nil) {
        self.globalOrientation = globalOrientation
        self.layout = layout
    }
}

/// Full controller info: `GET /api/v1/{token}/`.
public struct NanoleafInfo: Codable, Sendable, Hashable {
    public var name: String?
    public var serialNo: String?
    public var manufacturer: String?
    public var firmwareVersion: String?
    public var hardwareVersion: String?
    /// Model number, e.g. `NL22` (Light Panels), `NL29` (Canvas), `NL42` (Shapes), `NL52` (Elements),
    /// `NL59` (Lines).
    public var model: String?
    public var state: NanoleafState?
    public var effects: NanoleafEffects?
    public var panelLayout: NanoleafPanelLayout?

    public init(
        name: String? = nil,
        serialNo: String? = nil,
        manufacturer: String? = nil,
        firmwareVersion: String? = nil,
        hardwareVersion: String? = nil,
        model: String? = nil,
        state: NanoleafState? = nil,
        effects: NanoleafEffects? = nil,
        panelLayout: NanoleafPanelLayout? = nil
    ) {
        self.name = name
        self.serialNo = serialNo
        self.manufacturer = manufacturer
        self.firmwareVersion = firmwareVersion
        self.hardwareVersion = hardwareVersion
        self.model = model
        self.state = state
        self.effects = effects
        self.panelLayout = panelLayout
    }

    /// Number of panels (from `numPanels`, else `positionData.count`).
    public var panelCount: Int? {
        panelLayout?.layout?.numPanels ?? panelLayout?.layout?.positionData?.count
    }
}

/// `POST /api/v1/new` → `{"auth_token": "..."}`.
public struct NanoleafAuthResponse: Codable, Sendable, Hashable {
    public var authToken: String

    public init(authToken: String) { self.authToken = authToken }

    enum CodingKeys: String, CodingKey {
        case authToken = "auth_token"
    }
}

extension KeyedDecodingContainer {
    /// Decodes an Int that some firmware sends as a Double or numeric string.
    func decodeLenientInt(_ key: Key) throws -> Int? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        if let i = try? decode(Int.self, forKey: key) { return i }
        if let d = try? decode(Double.self, forKey: key), d.isFinite { return Int(d.rounded()) }
        if let s = try? decode(String.self, forKey: key) { return Int(s) }
        return nil
    }
}
