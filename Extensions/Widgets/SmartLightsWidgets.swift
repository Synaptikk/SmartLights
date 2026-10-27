import SwiftUI
import WidgetKit

/// Widget extension entry point (T2.7). Everything here renders the App Group `WidgetSnapshot`;
/// actions run in the app process (see Shared/WidgetIntents.swift).
@main
struct SmartLightsWidgets: WidgetBundle {
    var body: some Widget {
        LightWidget()
        RoomWidget()
        SceneWidget()
        LightControl()
        SceneControl()
    }
}
