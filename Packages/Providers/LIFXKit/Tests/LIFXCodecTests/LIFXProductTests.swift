import Testing
import LightCore
@testable import LIFXCodec

@Suite("LIFX product registry")
struct LIFXProductTests {
    @Test func tableHasNoDuplicatesAndCoversKnownProducts() {
        var keys = Set<String>()
        for p in LIFXProduct.all {
            #expect(keys.insert("\(p.vendor)/\(p.product)").inserted, "duplicate \(p.vendor)/\(p.product)")
        }
        #expect(LIFXProduct.all.count > 150)
    }

    @Test func colourBulbWithFirmwareUpgrade() throws {
        let a19 = try #require(LIFXProduct.find(vendor: 1, product: 27))
        #expect(a19.name == "LIFX (A19)")
        #expect(a19.features.contains(.color))
        #expect(a19.kelvinRange == 2500...9000)
        #expect(a19.resolved(firmware: LIFXFirmwareVersion(major: 2, minor: 79)).kelvinRange == 2500...9000)
        #expect(a19.resolved(firmware: LIFXFirmwareVersion(major: 2, minor: 80)).kelvinRange == 1500...9000)
        let caps = LIFXMapping.capabilities(for: a19)
        #expect(caps.supportedColorModes == [.hs, .colorTemp])
        #expect(caps.supportsTransition)
        #expect(caps.effects.map(\.id) == ["breathe", "pulse"])
    }

    @Test func stripGainsExtendedMultizone() throws {
        let z = try #require(LIFXProduct.find(vendor: 1, product: 32))
        #expect(z.name == "LIFX Z")
        #expect(z.features.contains(.multizone))
        #expect(!z.features.contains(.extendedMultizone))
        let upgraded = z.resolved(firmware: LIFXFirmwareVersion(major: 2, minor: 77))
        #expect(upgraded.features.contains(.extendedMultizone))
        #expect(upgraded.kelvinRange == 2500...9000)
        #expect(z.resolved(firmware: LIFXFirmwareVersion("3.70")).kelvinRange == 1500...9000)
    }

    @Test func infraredChainAndMatrixFlags() throws {
        let plusA19 = try #require(LIFXProduct.find(vendor: 1, product: 29))
        #expect(plusA19.features.contains(.infrared))
        #expect(LIFXProduct.all.contains { $0.features.contains(.chain) })
        #expect(LIFXProduct.all.contains { $0.features.contains(.matrix) })
        #expect(LIFXProduct.all.contains { $0.features.contains(.hev) })
    }

    @Test func whiteProductsMapToTemperatureOrBrightness() throws {
        let white800 = try #require(LIFXProduct.find(vendor: 1, product: 10))
        let caps = LIFXMapping.capabilities(for: white800)
        #expect(caps.supportedColorModes == [.colorTemp])
        #expect(caps.kelvinRange == 2700...6500)

        let miniW = try #require(LIFXProduct.find(vendor: 1, product: 51))
        #expect(LIFXMapping.capabilities(for: miniW).supportedColorModes == [.brightness])
    }

    @Test func switchIsOnOffOnly() throws {
        let sw = try #require(LIFXProduct.find(vendor: 1, product: 70))
        #expect(sw.features.contains(.relays))
        #expect(!sw.isLight)
        #expect(LIFXMapping.capabilities(for: sw).supportedColorModes == [.onOff])
    }

    @Test func unknownProductFallsBackToColour() {
        let p = LIFXProduct.lookup(vendor: 1, product: 65000)
        #expect(!p.isKnown)
        #expect(p.features == [.color])
        #expect(p.kelvinRange == 1500...9000)
        #expect(LIFXProduct.find(vendor: 1, product: 65000) == nil)
    }

    @Test func firmwareParsing() {
        #expect(LIFXFirmwareVersion("4.110") == LIFXFirmwareVersion(major: 4, minor: 110))
        #expect(LIFXFirmwareVersion("3.70")! < LIFXFirmwareVersion("3.100")!)
        #expect(LIFXFirmwareVersion("x") == nil)
    }
}
