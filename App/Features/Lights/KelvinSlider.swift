import SwiftUI
import LightCore

/// Colour temperature slider clamped to the light's Kelvin range, with a warm-to-cool strip.
struct KelvinSlider: View {
    let range: ClosedRange<Int>
    let kelvin: Int
    var onChange: (Int) -> Void

    private var gradient: LinearGradient {
        let steps = 6
        let colors = (0...steps).map { i -> Color in
            let k = range.lowerBound + (range.upperBound - range.lowerBound) * i / steps
            return ColorMath.kelvinToRGB(k).color
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Temperature")
                Spacer()
                Text("\(kelvin) K")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Capsule()
                .fill(gradient)
                .frame(height: 8)
                .accessibilityHidden(true)
            Slider(
                value: Binding(
                    get: { Double(min(max(kelvin, range.lowerBound), range.upperBound)) },
                    set: { onChange(Int($0.rounded())) }
                ),
                in: Double(range.lowerBound)...Double(max(range.upperBound, range.lowerBound + 1)),
                step: 50
            ) {
                Text("Temperature")
            } minimumValueLabel: {
                Text("Warm").font(.caption)
            } maximumValueLabel: {
                Text("Cool").font(.caption)
            }
            .accessibilityLabel(Text("Colour temperature"))
            .accessibilityValue(Text("\(kelvin) kelvin"))
        }
    }
}

#if DEBUG
#Preview {
    @Previewable @State var kelvin = 3000
    KelvinSlider(range: 2200...6500, kelvin: kelvin) { kelvin = $0 }
        .padding()
}
#endif
