import Foundation
import Testing
@testable import LightCore

@Suite("LightID")
struct LightIDTests {
    @Test func parsesBrandAndStableId() throws {
        let id = try #require(LightID("wiz:a8bb5006033d"))
        #expect(id.brand == .wiz)
        #expect(id.stableId == "a8bb5006033d")
        #expect(id.rawValue == "wiz:a8bb5006033d")
        #expect(id.description == "wiz:a8bb5006033d")
    }

    @Test func stableIdMayContainColons() throws {
        let id = try #require(LightID("hue:001788fffe123456:3f1c-uuid"))
        #expect(id.brand == .hue)
        #expect(id.stableId == "001788fffe123456:3f1c-uuid")
        #expect(LightID(id.rawValue) == id)
    }

    @Test func brandPrefixIsCaseInsensitiveAndCanonicalised() throws {
        let id = try #require(LightID("HomeAssistant:light.kitchen"))
        #expect(id.brand == .homeAssistant)
        #expect(id.rawValue == "homeassistant:light.kitchen")
    }

    @Test("rejects malformed ids", arguments: ["", "wiz", "wiz:", ":abc", "philips:abc", "wiz:ab cd", "wiz:ab\n"])
    func rejects(_ string: String) {
        #expect(LightID(string) == nil)
        #expect(throws: LightCoreError.invalidLightID(string)) { try LightID.parse(string) }
    }

    @Test func everyBrandRoundTrips() throws {
        for brand in Brand.allCases {
            let id = try #require(LightID(brand: brand, stableId: "x1"))
            #expect(LightID(id.rawValue) == id)
            #expect(!brand.displayName.isEmpty && !brand.vendor.isEmpty)
            #expect(brand.rawValue == brand.rawValue.lowercased())
        }
        #expect(Brand.allCases.count == 19)
    }

    @Test func codableAsStringAndDictionaryKey() throws {
        let id = try #require(LightID("aidot:dev123"))
        let data = try JSONEncoder().encode([id])
        #expect(String(decoding: data, as: UTF8.self) == #"["aidot:dev123"]"#)
        #expect(try JSONDecoder().decode([LightID].self, from: data) == [id])

        let dict: [LightID: LightCommand] = [id: .turnOn]
        let encoded = try JSONEncoder().encode(dict)
        let json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json.keys.sorted() == ["aidot:dev123"])
        #expect(try JSONDecoder().decode([LightID: LightCommand].self, from: encoded) == dict)

        #expect(throws: DecodingError.self) { try JSONDecoder().decode([LightID].self, from: Data(#"["nope"]"#.utf8)) }
    }
}
