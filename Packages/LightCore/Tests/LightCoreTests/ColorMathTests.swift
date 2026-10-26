import Foundation
import Testing
@testable import LightCore

/// Reference vectors computed from Home Assistant `homeassistant/util/color.py` formulas
/// (see NOTICES.md); xy values are compared with a tolerance because HA rounds to 3 decimals.
func close(_ a: Double, _ b: Double, _ tolerance: Double = 0.001) -> Bool { abs(a - b) <= tolerance }

func close(_ a: XY, _ b: XY, _ tolerance: Double = 0.001) -> Bool { close(a.x, b.x, tolerance) && close(a.y, b.y, tolerance) }

@Suite("ColorMath: Kelvin / mired")
struct KelvinTests {
    @Test("kelvin -> mired (floored)", arguments: [(2700, 370), (6500, 153), (2000, 500), (6535, 153), (4000, 250)])
    func kelvinToMired(kelvin: Int, mired: Int) {
        #expect(ColorMath.kelvinToMired(kelvin) == mired)
    }

    @Test("mired -> kelvin (floored)", arguments: [(153, 6535), (500, 2000), (370, 2702), (454, 2202)])
    func miredToKelvin(mired: Int, kelvin: Int) {
        #expect(ColorMath.miredToKelvin(mired) == kelvin)
    }

    @Test func zeroIsSafe() {
        #expect(ColorMath.kelvinToMired(0) == 0)
        #expect(ColorMath.miredToKelvin(0) == 0)
    }

    @Test("Helland kelvin -> RGB")
    func kelvinToRGB() {
        #expect(ColorMath.kelvinToRGB(2700) == RGB(r: 255, g: 167, b: 87))
        #expect(ColorMath.kelvinToRGB(6500) == RGB(r: 255, g: 254, b: 250))
        #expect(ColorMath.kelvinToRGB(1000) == RGB(r: 255, g: 68, b: 0))
        #expect(ColorMath.kelvinToRGB(500) == ColorMath.kelvinToRGB(1000)) // clamped
    }

    @Test("McCamy xy -> CCT")
    func xyToKelvin() {
        #expect(ColorMath.xyToKelvin(XY(x: 0.4578, y: 0.4101)) == 2724) // illuminant A ~2856 K by McCamy approx
        #expect(ColorMath.xyToKelvin(XY(x: 0.3127, y: 0.3290)) == 6508) // D65
    }

    @Test("Planckian locus kelvin -> xy")
    func kelvinToXY() {
        #expect(close(ColorMath.kelvinToXY(6500), XY(x: 0.3135, y: 0.3237), 0.002))
        #expect(close(ColorMath.kelvinToXY(2700), XY(x: 0.4599, y: 0.4106), 0.002))
        // Round trip through McCamy within 2 %.
        for k in stride(from: 2200, through: 6500, by: 300) {
            let back = ColorMath.xyToKelvin(ColorMath.kelvinToXY(k))
            #expect(abs(back - k) <= k / 50, "\(k) -> \(back)")
        }
    }
}

@Suite("ColorMath: CIE xy and gamut")
struct XYTests {
    @Test("pure red clamps to gamut C red corner")
    func redInGamutC() {
        let xy = ColorMath.rgbToXY(RGB(r: 255, g: 0, b: 0), gamut: .hueC)
        #expect(close(xy, XY(x: 0.6915, y: 0.3083), 0.0005))
    }

    @Test("RGB -> xy without gamut (HA test_color_RGB_to_xy)")
    func rgbToXY() {
        #expect(ColorMath.rgbToXY(.black) == XY(x: 0, y: 0))
        #expect(close(ColorMath.rgbToXY(.white), XY(x: 0.323, y: 0.329)))
        #expect(close(ColorMath.rgbToXY(RGB(r: 0, g: 0, b: 255)), XY(x: 0.136, y: 0.04)))
        #expect(close(ColorMath.rgbToXY(RGB(r: 0, g: 255, b: 0)), XY(x: 0.172, y: 0.747)))
        #expect(close(ColorMath.rgbToXY(RGB(r: 255, g: 0, b: 0)), XY(x: 0.701, y: 0.299)))
        #expect(close(ColorMath.rgbToXY(RGB(r: 128, g: 0, b: 0)), XY(x: 0.701, y: 0.299)))
    }

    @Test("RGB -> xy with gamut A")
    func rgbToXYGamutA() {
        #expect(close(ColorMath.rgbToXY(RGB(r: 0, g: 0, b: 255), gamut: .hueA), XY(x: 0.138, y: 0.08)))
        #expect(close(ColorMath.rgbToXY(RGB(r: 0, g: 255, b: 0), gamut: .hueA), XY(x: 0.2151, y: 0.7106)))
        #expect(close(ColorMath.rgbToXY(RGB(r: 255, g: 0, b: 0), gamut: .hueA), XY(x: 0.7004, y: 0.2991)))
    }

    @Test("RGB -> xy brightness")
    func luminance() {
        let red = ColorMath.rgbToXYBrightness(RGB(r: 255, g: 0, b: 0))
        #expect(close(red.brightness, 0.283881, 1e-6))
        #expect(close(ColorMath.rgbToXYBrightness(.white).brightness, 1, 1e-6))
    }

    @Test("xy + brightness -> RGB (HA test_color_xy_brightness_to_RGB)")
    func xyToRGB() {
        #expect(ColorMath.xyToRGB(XY(x: 1, y: 1), brightness: 0) == .black)
        #expect(ColorMath.xyToRGB(XY(x: 0.35, y: 0.35), brightness: 128.0 / 255) == RGB(r: 194, g: 186, b: 169))
        #expect(ColorMath.xyToRGB(XY(x: 0.35, y: 0.35)) == RGB(r: 255, g: 243, b: 222))
        #expect(ColorMath.xyToRGB(XY(x: 1, y: 0)) == RGB(r: 255, g: 0, b: 60))
        #expect(ColorMath.xyToRGB(XY(x: 0, y: 1)) == RGB(r: 0, g: 255, b: 0))
        #expect(ColorMath.xyToRGB(XY(x: 0, y: 0)) == RGB(r: 0, g: 63, b: 255))
    }

    @Test("xy -> RGB with gamut A")
    func xyToRGBGamutA() {
        #expect(ColorMath.xyToRGB(XY(x: 1, y: 0), gamut: .hueA) == RGB(r: 255, g: 0, b: 3))
        #expect(ColorMath.xyToRGB(XY(x: 0, y: 1), gamut: .hueA) == RGB(r: 82, g: 255, b: 0))
        #expect(ColorMath.xyToRGB(XY(x: 0, y: 0), gamut: .hueA) == RGB(r: 9, g: 85, b: 255))
    }

    @Test("HS -> xy (HA test_color_hs_to_xy)", arguments: [
        (180.0, 1.0, 0.151, 0.343),
        (350.0, 0.125, 0.356, 0.321),
        (140.0, 0.5, 0.230, 0.474),
        (0.0, 0.4, 0.474, 0.317),
        (360.0, 0.0, 0.323, 0.329),
    ])
    func hsToXY(h: Double, s: Double, x: Double, y: Double) {
        #expect(close(ColorMath.hsToXY(HS(h: h, s: s)), XY(x: x, y: y)))
    }

    @Test func gamutGeometry() {
        for gamut in [Gamut.hueA, .hueB, .hueC] {
            #expect(gamut.isValid)
            #expect(gamut.contains(XY(x: 0.32, y: 0.33)))
            #expect(gamut.contains(gamut.red))
            #expect(!gamut.contains(XY(x: 0.8, y: 0.2)))
            let clamped = gamut.clamp(XY(x: 0.8, y: 0.2))
            #expect(gamut.contains(clamped))
            #expect(gamut.clamp(XY(x: 0.32, y: 0.33)) == XY(x: 0.32, y: 0.33))
        }
        #expect(!Gamut(red: XY(x: 0, y: 0), green: XY(x: 0.5, y: 0.5), blue: XY(x: 1, y: 1)).isValid)
    }

    @Test("xy -> HS -> xy round trip inside gamut C")
    func xyRoundTrip() {
        for xy in [XY(x: 0.4, y: 0.4), XY(x: 0.25, y: 0.3), XY(x: 0.5, y: 0.35)] {
            let back = ColorMath.hsToXY(ColorMath.xyToHS(xy, gamut: .hueC), gamut: .hueC)
            #expect(close(back, xy, 0.01), "\(xy) -> \(back)")
        }
    }
}

@Suite("ColorMath: HSV")
struct HSVTests {
    @Test("RGB -> HSV (HA test_color_RGB_to_hsv)")
    func rgbToHSV() {
        let cases: [(RGB, Double, Double, Double)] = [
            (.black, 0, 0, 0),
            (.white, 0, 0, 1),
            (RGB(r: 0, g: 0, b: 255), 240, 1, 1),
            (RGB(r: 0, g: 255, b: 0), 120, 1, 1),
            (RGB(r: 255, g: 0, b: 0), 0, 1, 1),
        ]
        for (rgb, h, s, v) in cases {
            let hsv = ColorMath.rgbToHSV(rgb)
            #expect(close(hsv.h, h) && close(hsv.s, s) && close(hsv.v, v), "\(rgb)")
        }
    }

    @Test("HSV -> RGB (HA test_color_hsv_to_RGB / hs_to_RGB)")
    func hsvToRGB() {
        #expect(ColorMath.hsvToRGB(h: 0, s: 0, v: 0) == .black)
        #expect(ColorMath.hsvToRGB(h: 0, s: 0, v: 1) == .white)
        #expect(ColorMath.hsvToRGB(h: 240, s: 1, v: 1) == RGB(r: 0, g: 0, b: 255))
        #expect(ColorMath.hsvToRGB(h: 120, s: 1, v: 1) == RGB(r: 0, g: 255, b: 0))
        #expect(ColorMath.hsvToRGB(h: 0, s: 1, v: 1) == RGB(r: 255, g: 0, b: 0))
        #expect(ColorMath.hsToRGB(HS(h: 180, s: 1)) == RGB(r: 0, g: 255, b: 255))
        #expect(ColorMath.hsToRGB(HS(h: 350, s: 0.125)) == RGB(r: 255, g: 223, b: 228))
        #expect(ColorMath.hsToRGB(HS(h: 140, s: 0.5)) == RGB(r: 128, g: 255, b: 170))
        #expect(ColorMath.hsToRGB(HS(h: 0, s: 0.4)) == RGB(r: 255, g: 153, b: 153))
        #expect(ColorMath.hsToRGB(HS(h: 360, s: 1)) == RGB(r: 255, g: 0, b: 0))
        #expect(ColorMath.hsToRGB(HS(h: -120, s: 1)) == RGB(r: 0, g: 0, b: 255))
    }

    @Test("RGB -> HSV -> RGB is lossless")
    func rgbRoundTrip() {
        for r in stride(from: 0, through: 255, by: 17) {
            for g in stride(from: 0, through: 255, by: 51) {
                for b in stride(from: 0, through: 255, by: 85) {
                    let rgb = RGB(r: UInt8(r), g: UInt8(g), b: UInt8(b))
                    let hsv = ColorMath.rgbToHSV(rgb)
                    #expect(ColorMath.hsvToRGB(h: hsv.h, s: hsv.s, v: hsv.v) == rgb)
                }
            }
        }
    }

    @Test("HS -> RGB -> HS within quantisation error")
    func hsRoundTrip() {
        for h in stride(from: 0.0, to: 360.0, by: 7.0) {
            for s in [0.25, 0.5, 1.0] {
                let back = ColorMath.rgbToHS(ColorMath.hsToRGB(HS(h: h, s: s)))
                var dh = abs(back.h - h)
                dh = min(dh, 360 - dh)
                #expect(dh < 1.5 / s && close(back.s, s, 0.01), "h=\(h) s=\(s) -> \(back)")
            }
        }
    }

    @Test func hsClamped() {
        #expect(HS(h: 370, s: 2).clamped == HS(h: 10, s: 1))
        #expect(HS(h: -30, s: -1).clamped == HS(h: 330, s: 0))
        #expect(HS(h: .nan, s: .nan).clamped == HS(h: 0, s: 0))
    }
}

@Suite("ColorMath: white channels")
struct WhiteChannelTests {
    @Test("RGB -> RGBW (HA test_color_rgb_to_rgbw)")
    func rgbToRGBW() {
        #expect(ColorMath.rgbToRGBW(.black) == RGBW(r: 0, g: 0, b: 0, w: 0))
        #expect(ColorMath.rgbToRGBW(.white) == RGBW(r: 0, g: 0, b: 0, w: 255))
        #expect(ColorMath.rgbToRGBW(RGB(r: 255, g: 0, b: 0)) == RGBW(r: 255, g: 0, b: 0, w: 0))
        #expect(ColorMath.rgbToRGBW(RGB(r: 127, g: 127, b: 127)) == RGBW(r: 0, g: 0, b: 0, w: 127))
        #expect(ColorMath.rgbToRGBW(RGB(r: 255, g: 127, b: 0)) == RGBW(r: 255, g: 127, b: 0, w: 0))
        #expect(ColorMath.rgbToRGBW(RGB(r: 200, g: 150, b: 100)) == RGBW(r: 200, g: 100, b: 0, w: 200))
    }

    @Test("RGBW -> RGB")
    func rgbwToRGB() {
        #expect(ColorMath.rgbwToRGB(RGBW(r: 0, g: 0, b: 0, w: 255)) == .white)
        #expect(ColorMath.rgbwToRGB(RGBW(r: 255, g: 0, b: 0, w: 0)) == RGB(r: 255, g: 0, b: 0))
        #expect(ColorMath.rgbwToRGB(RGBW(r: 0, g: 0, b: 0, w: 0)) == .black)
        // Round trip.
        for rgb in [RGB(r: 200, g: 150, b: 100), RGB(r: 255, g: 127, b: 0), RGB(r: 10, g: 200, b: 90)] {
            let back = ColorMath.rgbwToRGB(ColorMath.rgbToRGBW(rgb))
            #expect(abs(Int(back.r) - Int(rgb.r)) <= 1 && abs(Int(back.g) - Int(rgb.g)) <= 1 && abs(Int(back.b) - Int(rgb.b)) <= 1)
        }
    }

    @Test("RGB -> RGBWW (2000-6535 K)")
    func rgbToRGBWW() {
        #expect(ColorMath.rgbToRGBWW(.white, minKelvin: 2000, maxKelvin: 6535) == RGBWW(r: 0, g: 76, b: 141, cw: 255, ww: 255))
        #expect(ColorMath.rgbToRGBWW(RGB(r: 255, g: 0, b: 0), minKelvin: 2000, maxKelvin: 6535) == RGBWW(r: 255, g: 0, b: 0, cw: 0, ww: 0))
        #expect(ColorMath.rgbToRGBWW(RGB(r: 200, g: 150, b: 100), minKelvin: 2000, maxKelvin: 6535) == RGBWW(r: 0, g: 9, b: 10, cw: 200, ww: 200))
    }

    @Test("RGBWW -> RGB round trip")
    func rgbwwRoundTrip() {
        for rgb in [RGB(r: 255, g: 255, b: 255), RGB(r: 255, g: 0, b: 0), RGB(r: 200, g: 150, b: 100)] {
            let back = ColorMath.rgbwwToRGB(ColorMath.rgbToRGBWW(rgb, minKelvin: 2000, maxKelvin: 6535), minKelvin: 2000, maxKelvin: 6535)
            #expect(abs(Int(back.r) - Int(rgb.r)) <= 2 && abs(Int(back.g) - Int(rgb.g)) <= 2 && abs(Int(back.b) - Int(rgb.b)) <= 2, "\(rgb) -> \(back)")
        }
    }

    @Test("Kelvin <-> cold/warm (HA test_color_temperature_to_rgbww)")
    func kelvinRGBWW() {
        #expect(ColorMath.kelvinToRGBWW(6535, brightness: 255, minKelvin: 2000, maxKelvin: 6535) == RGBWW(r: 0, g: 0, b: 0, cw: 255, ww: 0))
        #expect(ColorMath.kelvinToRGBWW(2000, brightness: 255, minKelvin: 2000, maxKelvin: 6535) == RGBWW(r: 0, g: 0, b: 0, cw: 0, ww: 255))
        #expect(ColorMath.kelvinToRGBWW(3000, brightness: 255, minKelvin: 2000, maxKelvin: 6535) == RGBWW(r: 0, g: 0, b: 0, cw: 123, ww: 132))
        #expect(ColorMath.kelvinToRGBWW(2700, brightness: 128, minKelvin: 2000, maxKelvin: 6500) == RGBWW(r: 0, g: 0, b: 0, cw: 48, ww: 80))
        let cold = ColorMath.rgbwwToKelvin(RGBWW(r: 0, g: 0, b: 0, cw: 255, ww: 0), minKelvin: 2000, maxKelvin: 6535)
        #expect(cold.kelvin == 6535 && cold.brightness == 255)
        let warm = ColorMath.rgbwwToKelvin(RGBWW(r: 0, g: 0, b: 0, cw: 0, ww: 255), minKelvin: 2000, maxKelvin: 6535)
        #expect(warm.kelvin == 2000 && warm.brightness == 255)
        let off = ColorMath.rgbwwToKelvin(RGBWW(r: 0, g: 0, b: 0, cw: 0, ww: 0), minKelvin: 2000, maxKelvin: 6535)
        #expect(off.kelvin == 2000 && off.brightness == 0)
    }
}

@Suite("ColorMath: brightness and hex")
struct BrightnessTests {
    @Test("brightness -> device range (HA brightness_to_value stepping)")
    func deviceValue() {
        #expect(ColorMath.deviceValue(forBrightness: 1, in: 1...100) == 100)
        #expect(ColorMath.deviceValue(forBrightness: 127.0 / 255, in: 1...100) == 50) // HA: 49.8 -> ceil
        #expect(ColorMath.deviceValue(forBrightness: 10.0 / 255, in: 1...100) == 4) // HA: 3.92 -> ceil
        #expect(ColorMath.deviceValue(forBrightness: 1, in: 10...100) == 100)
        #expect(ColorMath.deviceValue(forBrightness: 0.001, in: 10...100) == 10)
        #expect(ColorMath.deviceValue(forBrightness: 0, in: 1...254) == 1)
        #expect(ColorMath.deviceValue(forBrightness: 2, in: 1...254) == 254)
        #expect(ColorMath.deviceValue(forBrightness: .nan, in: 1...254) == 1)
    }

    @Test("device range -> brightness")
    func fromDevice() {
        #expect(close(ColorMath.brightness(fromDeviceValue: 100, in: 1...100), 1))
        #expect(close(ColorMath.brightness(fromDeviceValue: 50, in: 1...100), 0.5))
        #expect(close(ColorMath.brightness(fromDeviceValue: 100, in: 10...100), 1))
        for v in 10...100 {
            let b = ColorMath.brightness(fromDeviceValue: v, in: 10...100)
            #expect(ColorMath.deviceValue(forBrightness: b, in: 10...100) == v)
        }
    }

    @Test func scale255() {
        #expect(ColorMath.brightness255(1) == 255)
        #expect(ColorMath.brightness255(0.5) == 128)
        #expect(close(ColorMath.brightness(from255: 255), 1))
        #expect(ColorMath.scaled(RGB(r: 255, g: 100, b: 0), by: 0.5) == RGB(r: 128, g: 50, b: 0))
        #expect(close(ColorMath.scale(5, from: 0...10, to: 0...100), 50))
    }

    @Test func hex() {
        #expect(ColorMath.rgb(hex: "#ff8000") == RGB(r: 255, g: 128, b: 0))
        #expect(ColorMath.rgb(hex: "18BCF2") == RGB(r: 24, g: 188, b: 242))
        #expect(ColorMath.rgb(hex: "#fff") == nil)
        #expect(ColorMath.hex(RGB(r: 24, g: 188, b: 242)) == "#18bcf2")
    }
}
