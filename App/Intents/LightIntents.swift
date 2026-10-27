import AppIntents
import Foundation
import LightCore
import UIKit

// All intents run in the app process (`openAppWhenRun = false`; no extension), so they share the
// `AppModel` registered with `AppDependencyManager` in `SmartLightsApp`. HomeKit calls fail while
// the app is in the background for an intent (HMError 80, see HomeKitProvider/README.md), so any
// intent touching an Apple Home light asks to continue in the foreground first.

// MARK: - Shared execution

extension ForegroundContinuableIntent {
    /// Sends `command`, first moving to the foreground if an Apple Home light is involved and the
    /// app is not already active.
    @MainActor
    func run(_ command: LightCommand, on ids: [LightID], model: AppModel) async throws -> IntentOutcome {
        try await continueInForegroundIfNeeded(for: ids.map(\.brand))
        return try await model.performIntent(command, on: ids)
    }

    @MainActor
    func continueInForegroundIfNeeded(for brands: [Brand]) async throws {
        guard brands.contains(.appleHome), UIApplication.shared.applicationState != .active else { return }
        try await requestToContinueInForeground(
            "Apple Home lights can only be changed while SmartLights is open. Continue in SmartLights?"
        ) {}
    }

    @MainActor
    func setPower(_ on: Bool, light entity: LightEntity, model: AppModel) async throws -> String {
        await model.prepareForIntents()
        let light = try model.resolve(entity)
        let outcome = try await run(LightCommand(on: on), on: [light.id], model: model)
        return "\(light.name) is \(on ? "on" : "off").\(outcome.failureSuffix)"
    }

    @MainActor
    func setPower(_ on: Bool, room entity: RoomEntity, model: AppModel) async throws -> String {
        await model.prepareForIntents()
        let (room, lights) = try model.resolve(entity)
        let outcome = try await run(LightCommand(on: on), on: lights.map(\.id), model: model)
        return "\(room.name) is \(on ? "on" : "off").\(outcome.failureSuffix)"
    }

    /// `percent` 0 turns the lights off; otherwise they turn on at that brightness.
    @MainActor
    func setBrightness(_ percent: Int, on lights: [Light], name: String, model: AppModel) async throws -> String {
        let clamped = min(max(percent, 0), 100)
        let command = clamped == 0 ? LightCommand(on: false) : LightCommand(on: true, brightness: Double(clamped) / 100)
        let outcome = try await run(command, on: lights.map(\.id), model: model)
        let what = clamped == 0 ? "off" : "\(clamped)%"
        return "\(name) set to \(what).\(outcome.failureSuffix)"
    }
}

extension AppModel {
    func resolve(_ entity: LightEntity) throws -> Light {
        if let id = entity.lightID, let light = lightsByID[id] { return light }
        // Saved shortcut whose light was re-paired under a new id: fall back to the name.
        if let light = light(named: entity.name) { return light }
        throw IntentFailure.notFound(entity.name)
    }

    func resolve(_ entity: RoomEntity) throws -> (Room, [Light]) {
        let room = rooms.first { $0.id.uuidString == entity.id } ?? room(named: entity.name)
        guard let room else { throw IntentFailure.notFound(entity.name) }
        let lights = lights(inRoom: room.id)
        guard !lights.isEmpty else { throw IntentFailure.noLights(room.name) }
        return (room, lights)
    }

    func resolve(_ entity: SceneEntity) throws -> LightScene {
        if let scene = intentScene(id: entity.id) { return scene }
        if let scene = intentScenes.first(where: { IntentNameMatcher.rank($0.name, query: entity.name) == 0 }) {
            return scene
        }
        throw IntentFailure.notFound(entity.name)
    }
}

// MARK: - Light power

struct ToggleLightIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Toggle Light"
    static let description = IntentDescription("Turns a light on if it is off, or off if it is on.")
    static let openAppWhenRun = false

    @Parameter(title: "Light", requestValueDialog: "Which light?")
    var light: LightEntity

    @Dependency private var model: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Toggle \(\.$light)")
    }

    init() {}

    init(light: LightEntity) {
        self.light = light
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await model.prepareForIntents()
        let target = try model.resolve(light)
        let message = try await setPower(!target.state.isOn, light: light, model: model)
        return .result(dialog: "\(message)")
    }
}

struct TurnLightOnOffIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Turn Light On or Off"
    static let description = IntentDescription("Turns a light on or off.")
    static let openAppWhenRun = false

    @Parameter(title: "Light", requestValueDialog: "Which light?")
    var light: LightEntity

    @Parameter(title: "Power", default: .on)
    var power: LightPower

    @Dependency private var model: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Turn \(\.$light) \(\.$power)")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await setPower(power.isOn, light: light, model: model)
        return .result(dialog: "\(message)")
    }
}

/// One-parameter variant for App Shortcut phrases ("Turn on <light> in SmartLights").
struct TurnOnLightIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Turn On Light"
    static let description = IntentDescription("Turns a light on.")
    static let openAppWhenRun = false

    @Parameter(title: "Light", requestValueDialog: "Which light?")
    var light: LightEntity

    @Dependency private var model: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Turn on \(\.$light)")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await setPower(true, light: light, model: model)
        return .result(dialog: "\(message)")
    }
}

/// One-parameter variant for App Shortcut phrases ("Turn off <light> in SmartLights").
struct TurnOffLightIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Turn Off Light"
    static let description = IntentDescription("Turns a light off.")
    static let openAppWhenRun = false

    @Parameter(title: "Light", requestValueDialog: "Which light?")
    var light: LightEntity

    @Dependency private var model: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Turn off \(\.$light)")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await setPower(false, light: light, model: model)
        return .result(dialog: "\(message)")
    }
}

// MARK: - Brightness, colour, temperature

struct SetBrightnessIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Set Brightness"
    static let description = IntentDescription("Sets the brightness of a light or of every light in a room. 0% turns them off.")
    static let openAppWhenRun = false

    @Parameter(title: "Light")
    var light: LightEntity?

    @Parameter(title: "Room")
    var room: RoomEntity?

    @Parameter(title: "Brightness (%)", requestValueDialog: "What brightness, in percent?")
    var percent: Int

    @Dependency private var model: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$light) to \(\.$percent)%") {
            \.$room
        }
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await model.prepareForIntents()
        let message: String
        if let light {
            let target = try model.resolve(light)
            message = try await setBrightness(percent, on: [target], name: target.name, model: model)
        } else if let room {
            let (resolved, lights) = try model.resolve(room)
            message = try await setBrightness(percent, on: lights, name: resolved.name, model: model)
        } else {
            throw $light.needsValueError("Which light?")
        }
        return .result(dialog: "\(message)")
    }
}

struct SetColorIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Set Light Colour"
    static let description = IntentDescription(
        "Sets a light to a named colour or an RGB hex colour such as #FF8800. White-only bulbs pick the closest white."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Light", requestValueDialog: "Which light?")
    var light: LightEntity

    @Parameter(title: "Colour", requestValueDialog: "Which colour?")
    var color: ColorChoice?

    @Parameter(title: "Hex Colour", description: "RGB hex such as #FF8800. Overrides the named colour.")
    var hex: String?

    @Dependency private var model: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$light) to \(\.$color)") {
            \.$hex
        }
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await model.prepareForIntents()
        let target = try model.resolve(light)
        let attribute: ColorAttribute
        let spoken: String
        if let hex, !hex.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let rgb = HexColor.parse(hex) else {
                throw IntentFailure.unsupported("\(hex) isn't a hex colour like #FF8800.")
            }
            attribute = .rgb(rgb)
            spoken = hex
        } else if let color {
            attribute = color.attribute
            spoken = color.spokenName
        } else {
            throw $color.needsValueError("Which colour?")
        }
        let caps = target.capabilities
        guard caps.supportsColor || caps.supportsColorTemp else {
            throw IntentFailure.unsupported("\(target.name) can't change colour.")
        }
        let outcome = try await run(LightCommand(on: true, color: attribute), on: [target.id], model: model)
        return .result(dialog: "\(target.name) set to \(spoken).\(outcome.failureSuffix)")
    }
}

struct SetColorTemperatureIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Set Colour Temperature"
    static let description = IntentDescription("Sets a light's white colour temperature in kelvin (for example 2700 warm, 6500 cool).")
    static let openAppWhenRun = false

    @Parameter(title: "Light", requestValueDialog: "Which light?")
    var light: LightEntity

    @Parameter(title: "Kelvin", requestValueDialog: "What colour temperature, in kelvin?")
    var kelvin: Int

    @Dependency private var model: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$light) to \(\.$kelvin) K")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await model.prepareForIntents()
        let target = try model.resolve(light)
        let caps = target.capabilities
        guard caps.supportsColorTemp || caps.supportsColor else {
            throw IntentFailure.unsupported("\(target.name) can't change colour temperature.")
        }
        let requested = min(max(kelvin, 1000), 10000)
        let applied = caps.supportsColorTemp ? caps.clampKelvin(requested) : requested
        let outcome = try await run(LightCommand(on: true, color: .kelvin(applied)), on: [target.id], model: model)
        return .result(dialog: "\(target.name) set to \(applied) kelvin.\(outcome.failureSuffix)")
    }
}

// MARK: - Rooms

struct SetRoomIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Control Room"
    static let description = IntentDescription("Turns every light in a room on or off, or sets their brightness.")
    static let openAppWhenRun = false

    @Parameter(title: "Room", requestValueDialog: "Which room?")
    var room: RoomEntity

    @Parameter(title: "Action", default: .on)
    var action: RoomAction

    @Parameter(title: "Brightness (%)", requestValueDialog: "What brightness, in percent?")
    var percent: Int?

    @Dependency private var model: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action) \(\.$room)") {
            \.$percent
        }
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message: String
        switch action {
        case .on:
            message = try await setPower(true, room: room, model: model)
        case .off:
            message = try await setPower(false, room: room, model: model)
        case .brightness:
            guard let percent else { throw $percent.needsValueError("What brightness, in percent?") }
            await model.prepareForIntents()
            let (resolved, lights) = try model.resolve(room)
            message = try await setBrightness(percent, on: lights, name: resolved.name, model: model)
        }
        return .result(dialog: "\(message)")
    }
}

/// One-parameter variant for App Shortcut phrases ("Turn on SmartLights lights in <room>").
struct TurnOnRoomIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Turn On Room"
    static let description = IntentDescription("Turns on every light in a room.")
    static let openAppWhenRun = false

    @Parameter(title: "Room", requestValueDialog: "Which room?")
    var room: RoomEntity

    @Dependency private var model: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Turn on \(\.$room)")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await setPower(true, room: room, model: model)
        return .result(dialog: "\(message)")
    }
}

/// One-parameter variant for App Shortcut phrases ("Turn off SmartLights lights in <room>").
struct TurnOffRoomIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Turn Off Room"
    static let description = IntentDescription("Turns off every light in a room.")
    static let openAppWhenRun = false

    @Parameter(title: "Room", requestValueDialog: "Which room?")
    var room: RoomEntity

    @Dependency private var model: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Turn off \(\.$room)")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await setPower(false, room: room, model: model)
        return .result(dialog: "\(message)")
    }
}

// MARK: - Scenes

struct RecallSceneIntent: AppIntent, ForegroundContinuableIntent {
    static let title: LocalizedStringResource = "Run Scene"
    static let description = IntentDescription("Recalls a SmartLights scene or a scene saved on a bridge.")
    static let openAppWhenRun = false

    @Parameter(title: "Scene", requestValueDialog: "Which scene?")
    var scene: SceneEntity

    @Dependency private var model: AppModel

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$scene)")
    }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await model.prepareForIntents()
        let resolved = try model.resolve(scene)
        var brands = Array(resolved.commands.keys.map(\.brand))
        if let brand = resolved.brand { brands.append(brand) }
        try await continueInForegroundIfNeeded(for: brands)
        let outcome = try await model.recallForIntent(resolved)
        return .result(dialog: "\(resolved.name) is on.\(outcome.failureSuffix)")
    }
}
