import SwiftUI
import LightCore

/// One light in the Lights list: swatch, name, brand badge, power toggle and brightness.
/// Tapping the name area opens the detail view (the toggle and slider stay independent).
struct LightRow: View {
    let light: Light
    var onOpen: () -> Void

    @Environment(AppModel.self) private var model
    @ScaledMetric(relativeTo: .body) private var swatchSize = 32.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button(action: onOpen) {
                    HStack(spacing: 12) {
                        LightSwatch(light: light)
                            .frame(width: swatchSize, height: swatchSize)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(light.name)
                                .font(.body)
                                .foregroundStyle(.primary)
                            HStack(spacing: 6) {
                                BrandBadge(light: light)
                                Text(light.stateSummary)
                                    .font(.caption)
                                    .foregroundStyle(light.state.reachable ? Color.secondary : Color.orange)
                            }
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
                .accessibilityLabel(Text(light.name))
                .accessibilityValue(Text("\(light.badgeText), \(light.stateSummary)"))
                .accessibilityHint(Text("Opens light controls"))
                .accessibilityAddTraits(.isButton)

                Toggle(isOn: power) {
                    Text("Power")
                }
                .labelsHidden()
                .accessibilityLabel(Text("\(light.name) power"))
            }

            if light.capabilities.supportsBrightness && light.state.isOn {
                BrightnessSlider(name: light.name, value: brightness)
            }
        }
        .padding(.vertical, 2)
        .opacity(light.state.reachable ? 1 : 0.6)
    }

    private var power: Binding<Bool> {
        Binding(
            get: { model.lightsByID[light.id]?.state.isOn ?? false },
            set: { model.setPower($0, for: light.id) }
        )
    }

    private var brightness: Binding<Double> {
        Binding(
            get: { model.lightsByID[light.id]?.state.brightness ?? 1 },
            set: { model.setBrightness($0, for: light.id) }
        )
    }
}

/// Brightness slider `1...100 %` (0 would mean "off"; use the power toggle for that).
struct BrightnessSlider: View {
    let name: String
    @Binding var value: Double

    var body: some View {
        Slider(value: $value, in: 0.01...1) {
            Text("Brightness")
        } minimumValueLabel: {
            Image(systemName: "sun.min")
        } maximumValueLabel: {
            Image(systemName: "sun.max.fill")
        }
        .accessibilityLabel(Text("\(name) brightness"))
        .accessibilityValue(Text("\(Int((value * 100).rounded())) percent"))
    }
}

#if DEBUG
#Preview {
    let model = PreviewRegistry.model()
    List {
        ForEach(model.sortedLights) { light in
            LightRow(light: light) {}
        }
    }
    .environment(model)
}
#endif
