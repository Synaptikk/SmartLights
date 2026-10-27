import Foundation

/// Paths of the WLED JSON API (HTTP port 80, no authentication).
/// Source: https://kno.wled.ge/interfaces/json-api/
public enum WLEDAPI {
    public static let defaultPort: UInt16 = 80
    /// `GET` -> `WLEDState`; `POST` a `WLEDStateUpdate` (with `"v": true` the reply is the new state).
    public static let state = "/json/state"
    /// `GET` -> `WLEDInfo` (version, LED capabilities, MAC).
    public static let info = "/json/info"
    /// `GET` -> effect names; the index is the effect id (`fx`).
    public static let effects = "/json/effects"
    /// `GET` -> configuration; only `id.mdns` (the mDNS host name) is read.
    public static let config = "/json/cfg"
}

/// `/json/state` (only the fields SmartLights uses; others are ignored).
public struct WLEDState: Codable, Sendable, Equatable {
    public var on: Bool?
    /// Master brightness `0...255`.
    public var bri: Int?
    /// Default transition in 100 ms units.
    public var transition: Int?
    /// Active preset id, -1 for none.
    public var ps: Int?
    public var mainseg: Int?
    public var seg: [WLEDSegment]?

    public init(on: Bool? = nil, bri: Int? = nil, transition: Int? = nil, ps: Int? = nil, mainseg: Int? = nil, seg: [WLEDSegment]? = nil) {
        self.on = on
        self.bri = bri
        self.transition = transition
        self.ps = ps
        self.mainseg = mainseg
        self.seg = seg
    }

    public static func decode(_ data: Data) throws -> WLEDState {
        try JSONDecoder().decode(WLEDState.self, from: data)
    }

    /// Segment 0 (SmartLights controls a WLED device as one light through its first segment).
    public var primarySegment: WLEDSegment? { seg?.first }

    /// Overlays an executed update (used when the device does not echo its state).
    public func merging(_ update: WLEDStateUpdate) -> WLEDState {
        var out = self
        if let v = update.on { out.on = v }
        if let v = update.bri { out.bri = v }
        if let changes = update.seg?.first {
            var s = out.seg?.first ?? WLEDSegment(id: 0)
            if let col = changes.col { s.col = col }
            if let fx = changes.fx { s.fx = fx }
            if let on = changes.on { s.on = on }
            if out.seg?.isEmpty ?? true { out.seg = [s] } else { out.seg?[0] = s }
        }
        return out
    }
}

/// One segment of `/json/state`.
public struct WLEDSegment: Codable, Sendable, Equatable {
    public var id: Int?
    public var start: Int?
    public var stop: Int?
    public var len: Int?
    public var on: Bool?
    public var bri: Int?
    /// Up to three colour slots; each `[r, g, b]` or `[r, g, b, w]` (`0...255`).
    public var col: [[Int]]?
    /// Effect id (index into `/json/effects`, 0 = Solid).
    public var fx: Int?
    /// Effect speed / intensity / palette.
    public var sx: Int?
    public var ix: Int?
    public var pal: Int?

    public init(id: Int? = nil, start: Int? = nil, stop: Int? = nil, len: Int? = nil, on: Bool? = nil, bri: Int? = nil,
                col: [[Int]]? = nil, fx: Int? = nil, sx: Int? = nil, ix: Int? = nil, pal: Int? = nil) {
        self.id = id
        self.start = start
        self.stop = stop
        self.len = len
        self.on = on
        self.bri = bri
        self.col = col
        self.fx = fx
        self.sx = sx
        self.ix = ix
        self.pal = pal
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id)
        start = try c.decodeIfPresent(Int.self, forKey: .start)
        stop = try c.decodeIfPresent(Int.self, forKey: .stop)
        len = try c.decodeIfPresent(Int.self, forKey: .len)
        on = try c.decodeIfPresent(Bool.self, forKey: .on)
        bri = try c.decodeIfPresent(Int.self, forKey: .bri)
        fx = try c.decodeIfPresent(Int.self, forKey: .fx)
        sx = try c.decodeIfPresent(Int.self, forKey: .sx)
        ix = try c.decodeIfPresent(Int.self, forKey: .ix)
        pal = try c.decodeIfPresent(Int.self, forKey: .pal)
        // Colour slots are arrays, but WLED also accepts (and some builds report) hex strings "FF0000".
        if let arrays = try? c.decodeIfPresent([[Int]].self, forKey: .col) {
            col = arrays
        } else if let mixed = try? c.decodeIfPresent([WLEDColorSlot].self, forKey: .col) {
            col = mixed.map(\.values)
        } else {
            col = nil
        }
    }
}

/// A colour slot given either as `[r, g, b(, w)]` or as a hex string `"RRGGBB"`/`"RRGGBBWW"`.
private struct WLEDColorSlot: Decodable {
    var values: [Int]

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let arr = try? c.decode([Int].self) {
            values = arr
            return
        }
        let hex = try c.decode(String.self).trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if hex.isEmpty {
            values = []
            return
        }
        guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad WLED colour \(hex)")
        }
        let bytes = hex.count / 2
        values = (0..<bytes).map { Int((v >> UInt64(8 * (bytes - 1 - $0))) & 0xFF) }
    }
}

/// Body of `POST /json/state`. Unset fields are omitted (left unchanged by WLED).
public struct WLEDStateUpdate: Codable, Sendable, Equatable {
    public struct Segment: Codable, Sendable, Equatable {
        public var id: Int
        public var on: Bool?
        public var col: [[Int]]?
        public var fx: Int?

        public init(id: Int = 0, on: Bool? = nil, col: [[Int]]? = nil, fx: Int? = nil) {
            self.id = id
            self.on = on
            self.col = col
            self.fx = fx
        }
    }

    public var on: Bool?
    public var bri: Int?
    /// One-shot transition for this call only, in 100 ms units (`transition` would change the default).
    public var tt: Int?
    public var seg: [Segment]?
    /// `true`: reply with the full new state instead of `{"success":true}`.
    public var v: Bool?

    public init(on: Bool? = nil, bri: Int? = nil, tt: Int? = nil, seg: [Segment]? = nil, v: Bool? = nil) {
        self.on = on
        self.bri = bri
        self.tt = tt
        self.seg = seg
        self.v = v
    }

    /// True when the update changes nothing (a bare transition or `v` is not a change).
    public var isEmpty: Bool { on == nil && bri == nil && (seg?.allSatisfy { $0.on == nil && $0.col == nil && $0.fx == nil } ?? true) }

    /// Compact JSON with sorted keys (stable for tests and logs).
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }
}

/// `/json/info` (subset).
public struct WLEDInfo: Codable, Sendable, Equatable {
    public struct LEDs: Codable, Sendable, Equatable {
        public var count: Int?
        /// Pre-0.13 flag: strip has a white channel.
        public var rgbw: Bool?
        /// Light capabilities bit field (0.13+): 1 = RGB, 2 = white channel, 4 = CCT.
        public var lc: Int?
        public var maxseg: Int?

        public init(count: Int? = nil, rgbw: Bool? = nil, lc: Int? = nil, maxseg: Int? = nil) {
            self.count = count
            self.rgbw = rgbw
            self.lc = lc
            self.maxseg = maxseg
        }
    }

    /// Firmware version ("0.14.4").
    public var ver: String?
    /// Build id (yyMMddb).
    public var vid: Int?
    public var leds: LEDs?
    /// Friendly name set in WLED (default "WLED").
    public var name: String?
    /// MAC without separators ("a4cf12fdaea8").
    public var mac: String?
    public var ip: String?
    public var arch: String?
    public var brand: String?
    public var product: String?
    public var fxcount: Int?

    public init(ver: String? = nil, vid: Int? = nil, leds: LEDs? = nil, name: String? = nil, mac: String? = nil, ip: String? = nil,
                arch: String? = nil, brand: String? = nil, product: String? = nil, fxcount: Int? = nil) {
        self.ver = ver
        self.vid = vid
        self.leds = leds
        self.name = name
        self.mac = mac
        self.ip = ip
        self.arch = arch
        self.brand = brand
        self.product = product
        self.fxcount = fxcount
    }

    public static func decode(_ data: Data) throws -> WLEDInfo {
        try JSONDecoder().decode(WLEDInfo.self, from: data)
    }
}

/// `/json/cfg` (only `id`).
public struct WLEDConfig: Codable, Sendable, Equatable {
    public struct Identity: Codable, Sendable, Equatable {
        /// mDNS host name without `.local` ("wled-livingroom").
        public var mdns: String?
        public var name: String?
    }

    public var id: Identity?

    public static func decode(_ data: Data) throws -> WLEDConfig {
        try JSONDecoder().decode(WLEDConfig.self, from: data)
    }
}
