import Foundation

/// One dispatched Server-Sent Event.
public struct SSEEvent: Sendable, Hashable {
    /// The last event id in effect when this event was dispatched (`nil` if none was ever set).
    public var id: String?
    /// The `event:` type, `"message"` when the server did not send one.
    public var type: String
    /// The concatenated `data:` lines, joined with `\n` (no trailing newline).
    public var data: String

    public init(id: String? = nil, type: String = "message", data: String) {
        self.id = id
        self.type = type
        self.data = data
    }

    /// Decodes `data` as JSON (Hue CLIP v2 sends a JSON array per event).
    public func decodeData<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(T.self, from: Data(data.utf8))
    }
}

/// Incremental `text/event-stream` parser following the WHATWG HTML "event stream interpretation"
/// rules: lines end in CRLF, LF or CR (a CRLF split across chunks is handled); a leading UTF-8 BOM
/// is dropped; `:` lines are comments; `event`, `data`, `id`, `retry` fields; an empty line
/// dispatches. Feed arbitrary byte chunks; complete events are returned as they finish.
public struct SSEParser: Sendable {
    /// The last event id string (updated on every dispatch boundary, persists across events).
    public private(set) var lastEventID: String
    /// Reconnection time requested by the server via `retry:`.
    public private(set) var reconnectionTime: Duration?
    /// Number of comment lines seen (servers use them as keep-alives).
    public private(set) var commentCount: Int = 0

    private var lineBuffer: [UInt8] = []
    private var dataBuffer: String = ""
    private var eventTypeBuffer: String = ""
    private var lastEventIDBuffer: String
    private var pendingCR = false
    private var atStreamStart = true

    public init(lastEventID: String = "") {
        self.lastEventID = lastEventID
        self.lastEventIDBuffer = lastEventID
    }

    /// Feeds a chunk of bytes and returns the events completed by it.
    public mutating func feed<S: Sequence>(_ bytes: S) -> [SSEEvent] where S.Element == UInt8 {
        var events: [SSEEvent] = []
        for byte in bytes {
            if pendingCR {
                pendingCR = false
                if byte == 0x0A { continue } // second half of CRLF
            }
            switch byte {
            case 0x0D:
                pendingCR = true
                processLine(into: &events)
            case 0x0A:
                processLine(into: &events)
            default:
                lineBuffer.append(byte)
            }
        }
        return events
    }

    /// Convenience for string input.
    public mutating func feed(_ text: String) -> [SSEEvent] {
        feed(Array(text.utf8))
    }

    /// Call when the connection ends. Per spec an event without its terminating blank line is
    /// discarded (including any `id:` it carried); the last dispatched event id and the retry value
    /// are kept for reconnection.
    public mutating func finish() {
        lastEventIDBuffer = lastEventID
        lineBuffer.removeAll(keepingCapacity: true)
        dataBuffer = ""
        eventTypeBuffer = ""
        pendingCR = false
        atStreamStart = true
    }

    private mutating func processLine(into events: inout [SSEEvent]) {
        var line = lineBuffer
        lineBuffer.removeAll(keepingCapacity: true)
        if atStreamStart {
            atStreamStart = false
            if line.starts(with: [0xEF, 0xBB, 0xBF]) { line.removeFirst(3) }
        }
        if line.isEmpty {
            dispatch(into: &events)
            return
        }
        if line[0] == 0x3A { // ':' comment
            commentCount += 1
            return
        }
        let field: String
        let value: String
        if let colon = line.firstIndex(of: 0x3A) {
            field = String(decoding: line[..<colon], as: UTF8.self)
            var start = colon + 1
            if start < line.endIndex, line[start] == 0x20 { start += 1 }
            value = String(decoding: line[start...], as: UTF8.self)
        } else {
            field = String(decoding: line, as: UTF8.self)
            value = ""
        }
        switch field {
        case "event":
            eventTypeBuffer = value
        case "data":
            dataBuffer += value
            dataBuffer += "\n"
        case "id":
            if !value.unicodeScalars.contains("\u{0}") { lastEventIDBuffer = value }
        case "retry":
            if !value.isEmpty, value.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let ms = Int(value) {
                reconnectionTime = .milliseconds(ms)
            }
        default:
            break // unknown fields are ignored
        }
    }

    private mutating func dispatch(into events: inout [SSEEvent]) {
        lastEventID = lastEventIDBuffer
        guard !dataBuffer.isEmpty else {
            eventTypeBuffer = ""
            return
        }
        var data = dataBuffer
        if data.utf8.last == 0x0A { data = String(data.utf8.dropLast())! }
        events.append(SSEEvent(
            id: lastEventID.isEmpty ? nil : lastEventID,
            type: eventTypeBuffer.isEmpty ? "message" : eventTypeBuffer,
            data: data
        ))
        dataBuffer = ""
        eventTypeBuffer = ""
    }
}
