import SwiftUI
import LightCore

/// One group in the Lights tab: name and brands (opens the group), all on/off and brightness.
/// Every brand in the group gets the same command at the same time.
struct GroupControlRow: View {
    let group: LightGroup
    var onOpen: () -> Void

    @Environment(AppModel.self) private var model

    private var members: [Light] { model.lights(inGroup: group.id) }
    private var anyOn: Bool { model.isAnyOn(inGroup: group.id) }
    private var hasDimmable: Bool { members.contains { $0.capabilities.supportsBrightness } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Image(systemName: group.isSyncing ? "link.circle.fill" : "square.grid.2x2.fill")
                        .font(.title2)
                        .foregroundStyle(anyOn ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name)
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Group \(group.name)"))
            .accessibilityValue(Text(subtitle))
            .accessibilityHint(Text("Opens group controls"))
            .accessibilityAddTraits(.isButton)

            HStack {
                Button {
                    model.setPower(true, forGroup: group.id)
                } label: {
                    Label("All On", systemImage: "lightbulb.fill")
                }
                .accessibilityLabel(Text("Turn on group \(group.name)"))

                Spacer()

                Button {
                    model.setPower(false, forGroup: group.id)
                } label: {
                    Label("All Off", systemImage: "lightbulb.slash")
                }
                .accessibilityLabel(Text("Turn off group \(group.name)"))
            }
            .buttonStyle(.borderless)
            .font(.subheadline)
            .disabled(members.isEmpty)

            if hasDimmable && anyOn {
                BrightnessSlider(name: group.name, value: Binding(
                    get: { model.averageBrightness(inGroup: group.id) },
                    set: { model.setBrightness($0, forGroup: group.id) }
                ))
            }
        }
        .padding(.vertical, 2)
    }

    /// "4 lights · Hue, WiZ, AiDot" (plus "Light Sync" when mirroring).
    private var subtitle: String {
        let count = members.count
        var parts = ["\(count) \(count == 1 ? "light" : "lights")"]
        let brands = Self.brandNames(members)
        if !brands.isEmpty { parts.append(brands) }
        if group.isSyncing { parts.append("Light Sync") }
        return parts.joined(separator: " · ")
    }

    static func brandNames(_ lights: [Light]) -> String {
        var seen: Set<String> = []
        return lights.map(\.badgeText).filter { seen.insert($0).inserted }.joined(separator: ", ")
    }
}
