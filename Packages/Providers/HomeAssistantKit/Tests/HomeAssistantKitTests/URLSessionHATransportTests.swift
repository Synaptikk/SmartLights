#if canImport(Darwin)
import Foundation
import NetKit
import Testing

@testable import HomeAssistantKit

/// Bonjour TXT parsing of the production transport (macOS CI only).
@Suite("URLSessionHATransport")
struct URLSessionHATransportTests {
    @Test func bonjourTXTPrefersInternalURL() throws {
        let service = BonjourService(
            name: "Home", type: "_home-assistant._tcp", domain: "local.", interfaceName: "en0",
            txt: [
                "uuid": "0123456789abcdef0123456789abcdef", "location_name": "Home", "version": "2026.10.1",
                "internal_url": "http://192.168.1.10:8123", "external_url": "https://abc.ui.nabu.casa", "base_url": "",
            ],
            host: "192.168.1.10", port: 8123)
        let instance = try #require(URLSessionHATransport.instance(from: service))
        #expect(instance.uuid == "0123456789abcdef0123456789abcdef")
        #expect(instance.name == "Home")
        #expect(instance.baseURL.absoluteString == "http://192.168.1.10:8123")
        #expect(instance.externalURL?.absoluteString == "https://abc.ui.nabu.casa")
        #expect(instance.version == "2026.10.1")
    }

    @Test func bonjourFallsBackToResolvedHost() throws {
        let service = BonjourService(
            name: "Cabin", type: "_home-assistant._tcp", domain: "local.", interfaceName: nil,
            txt: ["uuid": "", "internal_url": ""], host: "fd00::10", port: 8123)
        let instance = try #require(URLSessionHATransport.instance(from: service))
        #expect(instance.uuid == nil)
        #expect(instance.name == "Cabin")
        #expect(instance.baseURL.absoluteString == "http://[fd00::10]:8123")
    }
}
#endif
