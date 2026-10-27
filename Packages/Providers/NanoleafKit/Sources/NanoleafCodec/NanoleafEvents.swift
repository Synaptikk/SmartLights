import Foundation
import NetKit

// Server-Sent Events from `GET /api/v1/{token}/events?id=1,2,3,4`. Each SSE message carries the event
// class in `id:` and a JSON body in `data:`:
//
//   id: 1
//   data: {"events":[{"attr":2,"value":65}]}
//
// State (id 1) attrs: 1 on, 2 brightness, 3 hue, 4 sat, 5 ct, 6 colorMode.
// Layout (id 2) attrs: 1 layout, 2 globalOrientation.
// Effects (id 3) attr 1: selected effect name.
// Touch (id 4): `{"events":[{"panelId":7397,"gesture":0}]}`.

/// A loosely typed JSON value (event `value`s are bools, numbers, strings or objects).
public enum NanoleafJSONValue: Decodable, Sendable, Hashable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case object([String: NanoleafJSONValue])
    case array([NanoleafJSONValue])
    case null

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([NanoleafJSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: NanoleafJSONValue].self))
        }
    }

    public var intValue: Int? {
        switch self {
        case .number(let d) where d.isFinite: Int(d.rounded())
        case .string(let s): Int(s)
        case .object(let o): o["value"]?.intValue
        default: nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): b
        case .number(let d): d != 0
        case .object(let o): o["value"]?.boolValue
        default: nil
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// One change inside a state event.
public enum NanoleafStateChange: Sendable, Hashable {
    case on(Bool)
    case brightness(Int)
    case hue(Int)
    case saturation(Int)
    case colorTemperature(Int)
    case colorMode(String)
}

/// Touch gesture codes.
public enum NanoleafGesture: Int, Sendable, Hashable {
    case singleTap = 0
    case doubleTap = 1
    case swipeUp = 2
    case swipeDown = 3
    case swipeLeft = 4
    case swipeRight = 5
}

public struct NanoleafTouch: Sendable, Hashable, Decodable {
    /// Panel touched; `-1` for swipes that are not tied to a panel.
    public var panelId: Int
    /// Raw gesture code (see `NanoleafGesture`).
    public var gesture: Int

    public init(panelId: Int, gesture: Int) {
        self.panelId = panelId
        self.gesture = gesture
    }

    public var kind: NanoleafGesture? { NanoleafGesture(rawValue: gesture) }
}

/// A decoded Nanoleaf SSE message.
public enum NanoleafEvent: Sendable, Hashable {
    case state([NanoleafStateChange])
    /// Layout or orientation changed (attr 1 layout, 2 globalOrientation); re-read `panelLayout`.
    case layout(attributes: [Int])
    /// Effect selection changed; `nil` when the event carried no name.
    case effects(selected: String?)
    case touch([NanoleafTouch])
    /// Anything else (unknown id, keep-alive payloads).
    case unknown(id: String?, data: String)
}

public enum NanoleafEventDecoder {
    private struct Envelope: Decodable {
        var events: [Item]
    }

    private struct Item: Decodable {
        var attr: Int?
        var value: NanoleafJSONValue?
        var panelId: Int?
        var gesture: Int?
    }

    /// Decodes one dispatched SSE event. Throws `NanoleafCodecError.decoding` for malformed JSON of a
    /// known event class; unknown classes become `.unknown`.
    public static func decode(_ event: SSEEvent) throws -> NanoleafEvent {
        guard let id = event.id.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }),
              let type = NanoleafEventType(rawValue: id) else {
            return .unknown(id: event.id, data: event.data)
        }
        let envelope = try NanoleafAPI.decode(Envelope.self, from: Data(event.data.utf8))
        switch type {
        case .state:
            return .state(envelope.events.compactMap(stateChange))
        case .layout:
            return .layout(attributes: envelope.events.compactMap(\.attr))
        case .effects:
            let name = envelope.events.last { $0.attr == 1 || $0.attr == nil }?.value?.stringValue
            return .effects(selected: name)
        case .touch:
            return .touch(envelope.events.compactMap { item in
                guard let gesture = item.gesture else { return nil }
                return NanoleafTouch(panelId: item.panelId ?? -1, gesture: gesture)
            })
        }
    }

    /// Feeds raw bytes through `parser` and decodes every completed event (malformed ones are skipped).
    public static func feed<S: Sequence>(_ bytes: S, into parser: inout SSEParser) -> [NanoleafEvent]
    where S.Element == UInt8 {
        parser.feed(bytes).compactMap { try? decode($0) }
    }

    private static func stateChange(_ item: Item) -> NanoleafStateChange? {
        guard let attr = item.attr, let value = item.value else { return nil }
        switch attr {
        case 1: return value.boolValue.map { .on($0) }
        case 2: return value.intValue.map { .brightness($0) }
        case 3: return value.intValue.map { .hue($0) }
        case 4: return value.intValue.map { .saturation($0) }
        case 5: return value.intValue.map { .colorTemperature($0) }
        case 6: return value.stringValue.map { .colorMode($0) }
        default: return nil
        }
    }
}

extension NanoleafState {
    /// Applies SSE state changes.
    public func applying(_ changes: [NanoleafStateChange]) -> NanoleafState {
        var next = self
        for change in changes {
            switch change {
            case .on(let v): next.on = NanoleafBoolValue(value: v)
            case .brightness(let v): next.brightness = next.brightness.updated(v, default: 0...100)
            case .hue(let v): next.hue = next.hue.updated(v, default: 0...360)
            case .saturation(let v): next.sat = next.sat.updated(v, default: 0...100)
            case .colorTemperature(let v): next.ct = next.ct.updated(v, default: 1200...6500)
            case .colorMode(let v): next.colorMode = v
            }
        }
        return next
    }

    /// Applies a write we just made (optimistic update until the device's SSE echo arrives).
    public func applying(_ update: NanoleafStateUpdate) -> NanoleafState {
        var changes: [NanoleafStateChange] = []
        if let on = update.on { changes.append(.on(on)) }
        if let b = update.brightness {
            changes.append(.brightness(b))
            if update.on == nil { changes.append(.on(true)) }
        }
        if let h = update.hue { changes.append(.hue(h)) }
        if let s = update.sat { changes.append(.saturation(s)) }
        if update.hue != nil || update.sat != nil { changes.append(.colorMode(NanoleafColorMode.hs.rawValue)) }
        if let ct = update.ct {
            changes.append(contentsOf: [.colorTemperature(ct), .colorMode(NanoleafColorMode.ct.rawValue)])
        }
        return applying(changes)
    }
}

extension Optional where Wrapped == NanoleafRange {
    fileprivate func updated(_ value: Int, default range: ClosedRange<Int>) -> NanoleafRange {
        var r = self ?? NanoleafRange(value: value, min: range.lowerBound, max: range.upperBound)
        r.value = value
        return r
    }
}
