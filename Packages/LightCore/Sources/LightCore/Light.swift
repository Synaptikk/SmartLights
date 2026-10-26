import Foundation

/// Last known state of a light. Exactly one of `kelvin`/`hs`/`rgb`/`rgbw`/`rgbww`/`xy`
/// should be authoritative, as indicated by `colorMode`; others may be filled as hints.
public struct LightState: Codable, Sendable, Equatable {
    public var isOn: Bool
    /// `0...1`; nil if unknown or not dimmable.
    public var brightness: Double?
    public var colorMode: ColorMode?
    public var kelvin: Int?
    /// Hue `0..<360`, saturation `0...1`.
    public var hs: HS?
    public var rgb: RGB?
    public var rgbw: RGBW?
    public var rgbww: RGBWW?
    public var xy: XY?
    /// Active effect id (matches `EffectDescriptor.id`), if any.
    public var effect: String?
    public var reachable: Bool
    public var updatedAt: Date

    public init(
        isOn: Bool = false,
        brightness: Double? = nil,
        colorMode: ColorMode? = nil,
        kelvin: Int? = nil,
        hs: HS? = nil,
        rgb: RGB? = nil,
        rgbw: RGBW? = nil,
        rgbww: RGBWW? = nil,
        xy: XY? = nil,
        effect: String? = nil,
        reachable: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.isOn = isOn
        self.brightness = brightness
        self.colorMode = colorMode
        self.kelvin = kelvin
        self.hs = hs
        self.rgb = rgb
        self.rgbw = rgbw
        self.rgbww = rgbww
        self.xy = xy
        self.effect = effect
        self.reachable = reachable
        self.updatedAt = updatedAt
    }

    /// The authoritative colour as a command attribute (per `colorMode`), if any.
    public var colorAttribute: ColorAttribute? {
        switch colorMode {
        case .colorTemp: kelvin.map { .kelvin($0) }
        case .hs: hs.map { .hs($0) }
        case .rgb: rgb.map { .rgb($0) }
        case .rgbw: rgbw.map { .rgbw($0) }
        case .rgbww: rgbww.map { .rgbww($0) }
        case .xy: xy.map { .xy($0) }
        case .onOff, .brightness, .white, nil: nil
        }
    }

    /// A command that would reproduce this state (used for app scenes).
    public var asCommand: LightCommand {
        LightCommand(on: isOn, brightness: isOn ? brightness : nil, color: isOn ? colorAttribute : nil, effect: isOn ? effect : nil)
    }

    /// Optimistically applies a command (UI updates before the device confirms).
    public func applying(_ command: LightCommand, at date: Date = Date()) -> LightState {
        var next = self
        if let on = command.on { next.isOn = on }
        if let b = command.brightness {
            next.brightness = min(max(b, 0), 1)
            if command.on == nil { next.isOn = b > 0 }
        }
        if let color = command.color {
            next.colorMode = color.colorMode
            next.kelvin = nil; next.hs = nil; next.rgb = nil; next.rgbw = nil; next.rgbww = nil; next.xy = nil
            switch color {
            case .kelvin(let k): next.kelvin = k
            case .hs(let v): next.hs = v
            case .rgb(let v): next.rgb = v
            case .rgbw(let v): next.rgbw = v
            case .rgbww(let v): next.rgbww = v
            case .xy(let v): next.xy = v
            }
            next.effect = nil
        }
        if let effect = command.effect { next.effect = effect }
        next.updatedAt = date
        return next
    }
}

/// One controllable light (or plug/strip treated as a light).
public struct Light: Identifiable, Codable, Sendable, Equatable {
    /// `"<brand>:<stable-id>"`.
    public var id: LightID
    public var brand: Brand
    public var name: String
    public var roomHint: String?
    public var capabilities: LightCapabilities
    public var state: LightState
    /// Provider-specific handle (bridge id + resource id, cached IP, ...). Opaque to the app.
    public var providerRef: String
    /// Hardware maker when it differs from the brand vendor (e.g. HomeKit accessory manufacturer).
    public var manufacturer: String?
    /// Vendor model id / moduleName, for diagnostics.
    public var model: String?

    public init(
        id: LightID,
        name: String,
        roomHint: String? = nil,
        capabilities: LightCapabilities,
        state: LightState = LightState(),
        providerRef: String = "",
        manufacturer: String? = nil,
        model: String? = nil
    ) {
        self.id = id
        self.brand = id.brand
        self.name = name
        self.roomHint = roomHint
        self.capabilities = capabilities
        self.state = state
        self.providerRef = providerRef
        self.manufacturer = manufacturer
        self.model = model
    }
}
