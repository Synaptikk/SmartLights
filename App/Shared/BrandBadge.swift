import SwiftUI
import LightCore

/// Small capsule naming the light's brand (text only, no logos).
struct BrandBadge: View {
    let light: Light

    var body: some View {
        Text(light.badgeText)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .accessibilityLabel(Text("Brand: \(light.brand == .appleHome ? light.badgeText : light.brand.displayName)"))
    }
}

/// Round swatch showing the light's current colour; dimmed when off.
struct LightSwatch: View {
    let light: Light

    var body: some View {
        Circle()
            .fill(light.state.isOn ? light.displayColor : Color.secondary.opacity(0.25))
            .overlay {
                Image(systemName: light.state.isOn ? "lightbulb.fill" : "lightbulb")
                    .font(.caption)
                    .foregroundStyle(light.state.isOn ? Color.black.opacity(0.55) : Color.secondary)
            }
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
            .accessibilityHidden(true)
    }
}

/// Transient bottom message.
struct ToastView: View {
    let toast: Toast

    var body: some View {
        Label(toast.message, systemImage: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.subheadline)
            .foregroundStyle(toast.isError ? Color.red : Color.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.horizontal, 16)
            .accessibilityAddTraits(.isStaticText)
    }
}
