import Foundation
import LightCore
@testable import Onboarding
import Testing

@Suite("GuideCatalog")
struct CatalogTests {
    let catalog = GuideCatalog.standard

    @Test func everyBrandHasAGuideOrStub() {
        #expect(catalog.brandsWithoutGuide.isEmpty)
        for brand in Brand.allCases {
            let guide = catalog.guide(for: brand)
            #expect(guide?.brand == brand, "\(brand)")
            #expect(guide?.listing == .brand, "\(brand)")
            #expect(guide?.summary.isEmpty == false, "\(brand)")
        }
    }

    @Test func guideIDsAreUnique() {
        let ids = catalog.guides.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func stepIDsAreUniqueWithinEachGuide() {
        for guide in catalog.guides {
            let ids = guide.steps.map(\.id)
            #expect(Set(ids).count == ids.count, "\(guide.id)")
        }
    }

    static let phaseOneBrands: [Brand] = [.hue, .wiz, .aidot, .appleHome]
    static let phaseTwoBrands: [Brand] = [.lifx, .govee, .nanoleaf, .tplink, .yeelight, .elgato, .shelly, .wled, .magicHome]

    @Test func phaseOneBrandsHaveFullGuides() throws {
        for brand in Self.phaseOneBrands {
            let guide = try #require(catalog.guide(for: brand))
            #expect(guide.phase == 1)
            #expect(!guide.isStub, "\(brand) should have steps")
        }
    }

    @Test func phaseTwoBrandsHaveFullGuides() throws {
        for brand in Self.phaseTwoBrands {
            let guide = try #require(catalog.guide(for: brand))
            #expect(guide.phase == 2, "\(brand)")
            #expect(!guide.isStub, "\(brand) should have steps")
            #expect(guide.section != nil, "\(brand)")
            #expect(guide.facts != nil, "\(brand)")
            #expect(guide.prerequisites == [GuideCatalog.iPhoneSetupID], "\(brand)")
            // Every phase-2 guide finds devices and ends up pairing one (the app stores it).
            #expect(guide.steps.contains { $0.callback == GuideCallback.discover && $0.actionKind == .scan }, "\(brand)")
            #expect(guide.steps.contains { $0.callback == GuideCallback.pair }, "\(brand)")
            #expect(guide.step(id: "verify")?.callback == GuideCallback.verify, "\(brand)")
            #expect(guide.steps.first?.id == "before", "\(brand)")
        }
        // No phase-2 brand guide is left as a stub, and the list above is complete.
        let phaseTwo = catalog.guides.filter { $0.phase == 2 && $0.listing == .brand }
        #expect(phaseTwo.allSatisfy { !$0.isStub })
        #expect(Set(phaseTwo.compactMap(\.brand)) == Set(Self.phaseTwoBrands))
        #expect(GuideCatalog.phase2.map(\.brand) == Self.phaseTwoBrands)
    }

    @Test func onlyPhaseThreeBrandsAreStubs() {
        for brand in Brand.allCases where !(Self.phaseOneBrands + Self.phaseTwoBrands).contains(brand) {
            let guide = catalog.guide(for: brand)
            #expect(guide?.isStub == true, "\(brand) should be a stub for now")
            #expect(guide?.phase == 3, "\(brand)")
        }
    }

    @Test func phaseTwoPairingStepsFollowTheMatrix() throws {
        let nanoleaf = try #require(catalog.guide(for: .nanoleaf)?.step(id: "hold-power"))
        #expect(nanoleaf.actionKind == .confirm(button: "Continue"))
        #expect(nanoleaf.callback == GuideCallback.pair)
        let tplink = try #require(catalog.guide(for: .tplink)?.step(id: "credentials"))
        #expect(tplink.callback == GuideCallback.pair)
        let govee = try #require(catalog.guide(for: .govee)?.step(id: "api-key"))
        #expect(govee.callback == GuideCallback.importKey)
        #expect(govee.isOptional)
        if case .secureText(let field) = govee.actionKind {
            #expect(field.contentType == .token)
        } else {
            Issue.record("Govee API key must be secure text")
        }
        let lifxToken = try #require(catalog.guide(for: .lifx)?.step(id: "cloud-token"))
        #expect(lifxToken.isOptional)
        let wled = try #require(catalog.guide(for: .wled)?.step(id: "wifi-setup"))
        #expect(wled.isOptional)
    }

    @Test func genericAppleSideGuidesExist() throws {
        let setup = try #require(catalog.guide(id: GuideCatalog.iPhoneSetupID))
        let matter = try #require(catalog.guide(id: GuideCatalog.matterIntoAppleHomeID))
        #expect(setup.brand == nil && setup.listing == .setup && setup.section == "§0")
        #expect(matter.brand == nil && matter.listing == .setup && matter.section == "§0.1")
        #expect(setup.step(id: "local-network")?.callback == GuideCallback.localNetworkPermission)
        #expect(catalog.setupGuides.map(\.id) == [GuideCatalog.iPhoneSetupID, GuideCatalog.matterIntoAppleHomeID])
        #expect(!catalog.addBrandList.contains { $0.listing == .setup })
    }

    @Test func crossReferencesResolve() {
        for guide in catalog.guides {
            for alt in guide.alternatives {
                if let target = alt.targetGuideID {
                    #expect(catalog.guide(id: target) != nil, "\(guide.id) -> \(target)")
                }
            }
            for prerequisite in guide.prerequisites {
                #expect(catalog.guide(id: prerequisite) != nil, "\(guide.id) needs \(prerequisite)")
            }
        }
    }

    @Test func verifyMarkersFollowTheDoc() throws {
        let hue = try #require(catalog.guide(for: .hue))
        #expect(hue.alternatives.first?.needsVerification == true) // "[verify path]" on the Matter/Apple Home route
        #expect(hue.step(id: "link-button")?.needsVerification == true) // link-button window length
        let ble = try #require(catalog.guide(id: GuideCatalog.hueBluetoothID))
        #expect(ble.step(id: "recommended")?.needsVerification == true)
        let wiz = try #require(catalog.guide(for: .wiz))
        #expect(wiz.step(id: "control-mode")?.needsVerification == true)
        #expect(catalog.guide(for: .govee)?.needsVerification == true)
        #expect(catalog.guide(for: .nanoleaf)?.needsVerification == true)
        #expect(catalog.guide(for: .dirigera)?.needsVerification == true)
        // Plain facts carry no marker.
        let govee = try #require(catalog.guide(for: .govee))
        #expect(govee.step(id: "before")?.containsUnverifiedCopy == true) // "[verify path]" on LAN Control
        let nanoleaf = try #require(catalog.guide(for: .nanoleaf))
        #expect(nanoleaf.step(id: "hold-power")?.needsVerification == true) // hold time 5 s vs 5-7 s
        for brand in [Brand.elgato, .lifx, .tplink, .yeelight, .shelly, .wled, .magicHome] {
            #expect(catalog.guide(for: brand)?.needsVerification == false, "\(brand)")
        }
        #expect(hue.step(id: "before")?.containsUnverifiedCopy == false)
    }

    @Test func hueLinkButtonIsAConfirmWithPairCallback() throws {
        let step = try #require(catalog.guide(for: .hue)?.step(id: "link-button"))
        #expect(step.actionKind == .confirm(button: "Continue"))
        #expect(step.callback == GuideCallback.pair)
        #expect(step.isProviderDriven)
    }

    @Test func addBrandListIsGroupedByPhase() {
        let groups = catalog.addBrandListByPhase
        #expect(groups.map(\.phase) == [1, 2, 3])
        let phase1 = Set(groups[0].guides.map(\.id))
        #expect(phase1.isSuperset(of: ["hue", "wiz", "aidot", "applehome"]))
        #expect(catalog.guides(for: .hue).map(\.id) == ["hue", GuideCatalog.hueBluetoothID])
    }
}

@Suite("RichText")
struct RichTextTests {
    @Test func parsesBoldCodeLinksAndBullets() {
        let text: RichText = """
        Tap **Allow** then send `POST /api`.
        - see [docs](https://example.com/x)
        """
        #expect(text.blocks == [
            .paragraph([.text("Tap "), .bold("Allow"), .text(" then send "), .code("POST /api"), .text(".")]),
            .bullet([.text("see "), .link(label: "docs", url: "https://example.com/x")]),
        ])
        #expect(text.plainText == "Tap Allow then send POST /api.\n- see docs")
        #expect(text.links == ["https://example.com/x"])
    }

    @Test func unclosedMarkersStayLiteral() {
        let text: RichText = "5 ** 2 and [not a link and `tick"
        #expect(text.blocks == [.paragraph([.text("5 ** 2 and [not a link and `tick")])])
    }
}
