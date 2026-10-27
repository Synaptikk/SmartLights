import Foundation

/// A device found by discovery: an SSDP search response (`HTTP/1.1 200 OK`) or an unsolicited
/// advertisement (`NOTIFY * HTTP/1.1`), both carrying the same headers:
///
/// ```
/// HTTP/1.1 200 OK
/// Cache-Control: max-age=3600
/// Location: yeelight://192.168.1.239:55443
/// Server: POSIX UPnP/1.0 YGLC/1
/// id: 0x000000000015243f
/// model: color
/// fw_ver: 18
/// support: get_prop set_default set_power toggle set_bright start_cf stop_cf set_scene ...
/// power: on
/// bright: 100
/// color_mode: 2
/// ct: 4000
/// rgb: 16711680
/// hue: 100
/// sat: 35
/// name: my_bulb
/// ```
public struct YeelightAdvertisement: Sendable, Hashable {
    /// Device id, lower-cased (`0x000000000015243f`). Stable; used as the light's stable id.
    public var id: String
    public var host: String
    public var port: UInt16
    public var model: String?
    public var firmwareVersion: String?
    /// Methods the device accepts.
    public var support: Set<String>
    /// Initial property values (`power`, `bright`, `color_mode`, `ct`, `rgb`, `hue`, `sat`, `name`).
    public var properties: [String: YeelightValue]
    /// Name stored on the device via `set_name` (may be empty, may be Base64 for non-ASCII names).
    public var name: String?
    /// True for `NOTIFY` advertisements, false for search responses.
    public var isNotify: Bool

    public init(
        id: String,
        host: String,
        port: UInt16 = YeelightProtocol.controlPort,
        model: String? = nil,
        firmwareVersion: String? = nil,
        support: Set<String> = [],
        properties: [String: YeelightValue] = [:],
        name: String? = nil,
        isNotify: Bool = false
    ) {
        self.id = id
        self.host = host
        self.port = port
        self.model = model
        self.firmwareVersion = firmwareVersion
        self.support = support
        self.properties = properties
        self.name = name
        self.isNotify = isNotify
    }
}

/// SSDP-style discovery messages (Yeelight Inter-Operation Spec §3).
public enum YeelightSSDP {
    /// The search request. Send to `239.255.255.250:1982` (multicast) or `<ip>:1982` (unicast probe
    /// of one known host; no multicast entitlement needed). Devices answer unicast to the sender.
    public static func searchRequest(host: String = YeelightProtocol.ssdpGroup) -> Data {
        Data(searchRequestText(host: host).utf8)
    }

    public static func searchRequestText(host: String = YeelightProtocol.ssdpGroup) -> String {
        "M-SEARCH * HTTP/1.1\r\n"
            + "HOST: \(host):\(YeelightProtocol.ssdpPort)\r\n"
            + "MAN: \"ssdp:discover\"\r\n"
            + "ST: \(YeelightProtocol.searchTarget)\r\n"
    }

    /// Header names whose values are reported as device properties.
    static let propertyHeaders = ["power", "bright", "color_mode", "ct", "rgb", "hue", "sat", "name"]

    /// Parses headers into a lower-cased dictionary (first `:` separates name from value).
    public static func headers(_ text: String) -> (startLine: String, headers: [String: String]) {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
        let start = lines.isEmpty ? "" : lines.removeFirst().trimmingCharacters(in: .whitespaces)
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, headers[key] == nil else { continue }
            headers[key] = value
        }
        return (start, headers)
    }

    /// Parses a search response or NOTIFY advertisement. Returns nil for M-SEARCH requests (our own
    /// multicast echo), other SSDP traffic, or messages missing `id`/`Location`.
    /// - Parameter sourceHost: datagram source, used when `Location` has no usable host.
    public static func parse(_ data: Data, sourceHost: String? = nil) -> YeelightAdvertisement? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        return parse(text, sourceHost: sourceHost)
    }

    public static func parse(_ text: String, sourceHost: String? = nil) -> YeelightAdvertisement? {
        let (start, h) = headers(text)
        let upper = start.uppercased()
        let isNotify = upper.hasPrefix("NOTIFY")
        guard upper.hasPrefix("HTTP/1.1 200") || upper.hasPrefix("HTTP/1.0 200") || isNotify else { return nil }
        guard let rawID = h["id"], !rawID.isEmpty else { return nil }
        guard let location = h["location"], let endpoint = parseLocation(location) ?? sourceHost.map({ ($0, YeelightProtocol.controlPort) })
        else { return nil }

        var properties: [String: YeelightValue] = [:]
        for key in propertyHeaders {
            if let value = h[key] { properties[key] = .string(value) }
        }
        let support = Set((h["support"] ?? "").split(separator: " ").map(String.init))
        let name = h["name"].flatMap { $0.isEmpty ? nil : $0 }
        return YeelightAdvertisement(
            id: normalizeID(rawID),
            host: endpoint.host,
            port: endpoint.port,
            model: h["model"].flatMap { $0.isEmpty ? nil : $0 },
            firmwareVersion: h["fw_ver"].flatMap { $0.isEmpty ? nil : $0 },
            support: support,
            properties: properties,
            name: name,
            isNotify: isNotify
        )
    }

    /// `yeelight://192.168.1.239:55443` -> ("192.168.1.239", 55443). Port defaults to 55443.
    public static func parseLocation(_ location: String) -> (host: String, port: UInt16)? {
        let trimmed = location.trimmingCharacters(in: .whitespaces)
        guard let schemeEnd = trimmed.range(of: "://") else { return nil }
        guard trimmed[..<schemeEnd.lowerBound].lowercased() == "yeelight" else { return nil }
        var rest = trimmed[schemeEnd.upperBound...]
        if let slash = rest.firstIndex(of: "/") { rest = rest[..<slash] }
        guard !rest.isEmpty else { return nil }
        if let colon = rest.lastIndex(of: ":") {
            let host = String(rest[..<colon])
            guard !host.isEmpty, let port = UInt16(rest[rest.index(after: colon)...]) else { return nil }
            return (host, port)
        }
        return (String(rest), YeelightProtocol.controlPort)
    }

    /// Lower-cases ids and adds a `0x` prefix if missing (`0x000000000015243f`).
    public static func normalizeID(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return t.hasPrefix("0x") ? t : "0x" + t
    }
}

/// Parsed Bonjour instance name of a Yeelight device, e.g. `yeelink-light-color1_miio123456789`.
public struct YeelightBonjourName: Sendable, Hashable {
    /// Model suffix after `yeelink-light-` (e.g. `color1`), if present.
    public var model: String?
    /// miio device id (decimal) after `_miio`, if present.
    public var miioDeviceID: UInt64?

    /// Returns nil unless the name starts with `yeelink-` (case-insensitive).
    public init?(_ name: String) {
        let lower = name.lowercased()
        guard lower.hasPrefix("yeelink-") else { return nil }
        var body = Substring(lower.dropFirst("yeelink-".count))
        if let miio = body.range(of: "_miio") {
            miioDeviceID = UInt64(body[miio.upperBound...].prefix(while: { $0.isNumber }))
            body = body[..<miio.lowerBound]
        }
        if body.hasPrefix("light-") { body = body.dropFirst("light-".count) }
        model = body.isEmpty ? nil : String(body)
    }

    /// The SSDP-style id derived from the miio device id (`0x` + 16 hex digits). The SSDP `id` of
    /// Yeelight devices appears to be the miio did in hex [verify on hardware]; used only as a
    /// fallback when the device does not answer a unicast search.
    public var derivedID: String? {
        guard let did = miioDeviceID else { return nil }
        let hex = String(did, radix: 16)
        return "0x" + String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }
}
