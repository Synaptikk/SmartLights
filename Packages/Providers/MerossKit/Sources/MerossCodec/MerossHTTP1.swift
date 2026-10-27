import Foundation

/// Minimal HTTP/1.1 framing for `POST /config` over a raw TCP connection. The Apple transport
/// uses it with NWConnection so plain-HTTP LAN calls do not depend on an App Transport Security
/// exception; it lives here so the parser is covered by the Linux tests.
public enum MerossHTTP1 {
    public struct Response: Sendable, Hashable {
        public var status: Int
        public var headers: [String: String]
        public var body: Data
    }

    public enum Failure: Error, Sendable, Equatable {
        case malformedStatusLine
        case malformedChunk
    }

    /// `POST <path> HTTP/1.1` with `Connection: close` and a Content-Length.
    public static func request(host: String, port: UInt16 = MerossConstants.httpPort, path: String = MerossConstants.configPath,
                               body: Data, contentType: String) -> Data {
        let hostHeader = port == 80 ? host : "\(host):\(port)"
        var head = "POST \(path) HTTP/1.1\r\n"
        head += "Host: \(hostHeader)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Accept: */*\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    /// Parses a complete response if `data` holds one. Returns nil while more bytes are needed;
    /// pass `complete: true` once the peer closed (then a body without length runs to the end).
    public static func parse(_ data: Data, complete: Bool) throws -> Response? {
        let bytes = [UInt8](data)
        guard let headerEnd = find([13, 10, 13, 10], in: bytes) else {
            if complete, !bytes.isEmpty { throw Failure.malformedStatusLine }
            return nil
        }
        let headText = String(decoding: bytes[..<headerEnd], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else {
            throw Failure.malformedStatusLine
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let rest = Array(bytes[(headerEnd + 4)...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let body = try dechunk(rest) else {
                if complete { throw Failure.malformedChunk }
                return nil
            }
            return Response(status: status, headers: headers, body: Data(body))
        }
        if let lengthText = headers["content-length"], let length = Int(lengthText) {
            guard rest.count >= length else {
                if complete { return Response(status: status, headers: headers, body: Data(rest)) }
                return nil
            }
            return Response(status: status, headers: headers, body: Data(rest.prefix(length)))
        }
        return complete ? Response(status: status, headers: headers, body: Data(rest)) : nil
    }

    /// Decodes a chunked body; nil if incomplete.
    static func dechunk(_ bytes: [UInt8]) throws -> [UInt8]? {
        var out: [UInt8] = []
        var i = 0
        while true {
            guard let lineEnd = find([13, 10], in: bytes, from: i) else { return nil }
            let sizeText = String(decoding: bytes[i..<lineEnd], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { throw Failure.malformedChunk }
            i = lineEnd + 2
            if size == 0 { return out }
            guard bytes.count >= i + size + 2 else { return nil }
            out += bytes[i..<i + size]
            i += size + 2
        }
    }

    static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int = 0) -> Int? {
        guard haystack.count >= needle.count, start <= haystack.count - needle.count else { return nil }
        for i in start...(haystack.count - needle.count) where haystack[i] == needle[0] {
            if Array(haystack[i..<i + needle.count]) == needle { return i }
        }
        return nil
    }
}
