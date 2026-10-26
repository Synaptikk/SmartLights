import SwiftUI
import LightCore

/// Hue/saturation wheel: angle = hue (clockwise from 3 o'clock, matching `AngularGradient`),
/// distance from centre = saturation. Drag anywhere on the wheel to pick.
struct ColorWheel: View {
    var hs: HS
    var onChange: (HS) -> Void

    @ScaledMetric(relativeTo: .body) private var knobSize = 30.0

    private static let hueColors: [Color] = stride(from: 0.0, through: 360.0, by: 30.0).map {
        Color(hue: $0 / 360, saturation: 1, brightness: 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let radius = size / 2
            let center = CGPoint(x: radius, y: radius)
            ZStack {
                Circle().fill(AngularGradient(colors: Self.hueColors, center: .center))
                Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: radius))
                Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                knob
                    .position(knobPosition(center: center, radius: radius))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onChange(Self.hs(at: value.location, center: center, radius: radius))
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(Text("Colour wheel"))
        .accessibilityValue(Text("Hue \(Int(hs.clamped.h)) degrees, saturation \(Int((hs.clamped.s * 100).rounded())) percent"))
        .accessibilityHint(Text("Swipe up or down to change the hue."))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(HS(h: hs.h + 15, s: max(hs.s, 0.5)).clamped)
            case .decrement: onChange(HS(h: hs.h - 15, s: max(hs.s, 0.5)).clamped)
            @unknown default: break
            }
        }
    }

    private var knob: some View {
        Circle()
            .fill(hs.color)
            .frame(width: knobSize, height: knobSize)
            .overlay(Circle().strokeBorder(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.3), radius: 3)
    }

    private func knobPosition(center: CGPoint, radius: CGFloat) -> CGPoint {
        let value = hs.clamped
        let angle = value.h * .pi / 180
        let distance = value.s * Double(radius)
        return CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
    }

    static func hs(at point: CGPoint, center: CGPoint, radius: CGFloat) -> HS {
        let dx = Double(point.x - center.x)
        let dy = Double(point.y - center.y)
        var degrees = atan2(dy, dx) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        let saturation = radius > 0 ? min(hypot(dx, dy) / Double(radius), 1) : 0
        return HS(h: degrees, s: saturation).clamped
    }
}

#if DEBUG
#Preview {
    @Previewable @State var hs = HS(h: 200, s: 0.7)
    ColorWheel(hs: hs) { hs = $0 }
        .padding()
}
#endif
