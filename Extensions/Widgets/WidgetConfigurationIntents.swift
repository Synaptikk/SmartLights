import AppIntents
import WidgetKit

// What the user picks when editing a widget or control. Resolved in the extension through the
// snapshot-backed queries in WidgetEntityQueries.swift.

struct SelectLightIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Light"
    static let description = IntentDescription("The light this widget turns on and off.")

    @Parameter(title: "Light")
    var light: LightEntity?

    init() {}
}

struct SelectRoomIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Room"
    static let description = IntentDescription("The room whose lights this widget shows.")

    @Parameter(title: "Room")
    var room: RoomEntity?

    init() {}
}

struct SelectSceneIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Scene"
    static let description = IntentDescription("The scene this widget runs.")

    @Parameter(title: "Scene")
    var scene: SceneEntity?

    init() {}
}

struct SelectLightControlIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Light"
    static let description = IntentDescription("The light this control turns on and off.")

    @Parameter(title: "Light")
    var light: LightEntity?

    init() {}

    func perform() async throws -> some IntentResult { .result() }
}

struct SelectSceneControlIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Scene"
    static let description = IntentDescription("The scene this control runs.")

    @Parameter(title: "Scene")
    var scene: SceneEntity?

    init() {}

    func perform() async throws -> some IntentResult { .result() }
}
