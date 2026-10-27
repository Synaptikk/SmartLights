import Foundation

/// Base URL handling. Users type `homeassistant.local`, `192.168.1.10:8123`,
/// `http://ha.lan:8123/` or a Nabu Casa URL (`https://<id>.ui.nabu.casa`).
public enum HAURL {
    /// HA's default HTTP port, used when a bare host without scheme is entered.
    public static let defaultPort = 8123

    /// Normalises user input to `scheme://host[:port]` (no path, no trailing slash).
    /// A missing scheme means `http` and, without an explicit port, port 8123.
    /// Only `http`/`https` are accepted (`ws`/`wss` are mapped back to them).
    public static func normalize(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        var defaultedScheme = false
        if !text.contains("://") {
            text = "http://" + text
            defaultedScheme = true
        }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty,
            var scheme = components.scheme?.lowercased()
        else { return nil }
        switch scheme {
        case "ws": scheme = "http"
        case "wss": scheme = "https"
        case "http", "https": break
        default: return nil
        }
        components.scheme = scheme
        if defaultedScheme, components.port == nil { components.port = defaultPort }
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }

    /// `ws(s)://host[:port]/api/websocket` for a normalised base URL.
    public static func websocketURL(for base: URL) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme?.lowercased() == "https" ? "wss" : "ws"
        components.path = "/api/websocket"
        return components.url
    }

    /// True for Nabu Casa remote UI URLs (`*.ui.nabu.casa`).
    public static func isNabuCasa(_ url: URL) -> Bool {
        url.host?.lowercased().hasSuffix(".ui.nabu.casa") ?? false
    }
}
