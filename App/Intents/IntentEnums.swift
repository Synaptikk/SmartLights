import AppIntents
import Foundation
import LightCore

/// On / off as a spoken parameter ("Turn the lamp on").
enum LightPower: String, AppEnum {
    case on
    case off

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Power"
    static let caseDisplayRepresentations: [LightPower: DisplayRepresentation] = [
        .on: "on",
        .off: "off",
    ]

    var isOn: Bool { self == .on }
}

/// What `SetRoomIntent` does to a room.
enum RoomAction: String, AppEnum {
    case on
    case off
    case brightness

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Room Action"
    static let caseDisplayRepresentations: [RoomAction: DisplayRepresentation] = [
        .on: "Turn on",
        .off: "Turn off",
        .brightness: "Set brightness",
    ]
}

/// Named colours Siri understands ("set the lamp to blue").
enum ColorChoice: String, AppEnum {
    case red
    case orange
    case yellow
    case green
    case cyan
    case blue
    case purple
    case magenta
    case pink
    case white
    case warmWhite
    case coolWhite

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Colour"
    static let caseDisplayRepresentations: [ColorChoice: DisplayRepresentation] = [
        .red: "red",
        .orange: "orange",
        .yellow: "yellow",
        .green: "green",
        .cyan: "cyan",
        .blue: "blue",
        .purple: "purple",
        .magenta: "magenta",
        .pink: "pink",
        .white: "white",
        .warmWhite: "warm white",
        .coolWhite: "cool white",
    ]

    /// White variants are colour temperatures so tunable-white bulbs can follow them.
    var attribute: ColorAttribute {
        switch self {
        case .red: .rgb(RGB(r: 255, g: 0, b: 0))
        case .orange: .rgb(RGB(r: 255, g: 120, b: 0))
        case .yellow: .rgb(RGB(r: 255, g: 210, b: 0))
        case .green: .rgb(RGB(r: 0, g: 255, b: 0))
        case .cyan: .rgb(RGB(r: 0, g: 255, b: 255))
        case .blue: .rgb(RGB(r: 0, g: 0, b: 255))
        case .purple: .rgb(RGB(r: 140, g: 0, b: 255))
        case .magenta: .rgb(RGB(r: 255, g: 0, b: 255))
        case .pink: .rgb(RGB(r: 255, g: 105, b: 180))
        case .white: .kelvin(4000)
        case .warmWhite: .kelvin(2700)
        case .coolWhite: .kelvin(6000)
        }
    }

    var spokenName: String {
        switch self {
        case .warmWhite: "warm white"
        case .coolWhite: "cool white"
        default: rawValue
        }
    }
}

/// Parses "#FF8800", "ff8800", "0xFF8800" or the short form "#F80".
enum HexColor {
    static func parse(_ text: String) -> RGB? {
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if hex.hasPrefix("#") { hex.removeFirst() } else if hex.hasPrefix("0x") { hex.removeFirst(2) }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit), let value = UInt32(hex, radix: 16) else { return nil }
        return RGB(r: UInt8((value >> 16) & 0xFF), g: UInt8((value >> 8) & 0xFF), b: UInt8(value & 0xFF))
    }
}
