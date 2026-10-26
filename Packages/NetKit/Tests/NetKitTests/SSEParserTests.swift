import Foundation
import Testing
@testable import NetKit

@Suite("SSEParser")
struct SSEParserTests {
    // Shape of a Hue CLIP v2 /eventstream/clip/v2 message (research_ios_platform.md A6).
    static let huePayload = """
    : hi

    id: 1634576695:0
    data: [{"creationtime":"2021-10-18T17:04:55Z","data":[{"id":"e706416a-8c92-46ef-8589-3453f3235b13","on":{"on":true},"owner":{"rid":"3f4ac4e9-d67a-4dbd-8a16-5ea7e373f281","rtype":"device"},"type":"light"}],"id":"9de116fc-5fd2-4b74-8414-0f30cb2cc94e","type":"update"}]

    id: 1634576696:0
    data: [{"creationtime":"2021-10-18T17:04:56Z","data":[{"dimming":{"brightness":42.0},"id":"e706416a-8c92-46ef-8589-3453f3235b13","type":"light"}],"id":"aa16fc-0000","type":"update"}]


    """

    struct HueEnvelope: Decodable, Equatable {
        struct Resource: Decodable, Equatable { let id: String; let type: String }
        let id: String
        let type: String
        let data: [Resource]
    }

    @Test func hueEventsWholeChunk() throws {
        var parser = SSEParser()
        let events = parser.feed(Self.huePayload)
        #expect(events.count == 2)
        #expect(parser.commentCount == 1)
        #expect(events[0].id == "1634576695:0")
        #expect(events[0].type == "message")
        #expect(events[1].id == "1634576696:0")
        #expect(parser.lastEventID == "1634576696:0")

        let first = try events[0].decodeData([HueEnvelope].self)
        #expect(first.count == 1)
        #expect(first[0].type == "update")
        #expect(first[0].data == [.init(id: "e706416a-8c92-46ef-8589-3453f3235b13", type: "light")])
    }

    @Test func hueEventsByteByByteMatchesWholeChunk() {
        var whole = SSEParser()
        let expected = whole.feed(Self.huePayload)
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for byte in Self.huePayload.utf8 { events += parser.feed([byte]) }
        #expect(events == expected)
    }

    @Test func crlfAndCrLineEndingsIncludingSplitCRLF() {
        var parser = SSEParser()
        var events = parser.feed("data: a\r")
        #expect(events.isEmpty)
        events += parser.feed("\ndata: b\r\n\r")   // CRLF split across chunks; then CR-only blank line
        #expect(events == [SSEEvent(data: "a\nb")])
        events += parser.feed("\ndata: c\r\r")        // LF continuing the previous CR is swallowed
        #expect(events == [SSEEvent(data: "a\nb"), SSEEvent(data: "c")])
    }

    @Test func multiLineDataEventTypeAndRetry() {
        var parser = SSEParser()
        let events = parser.feed("retry: 2500\nevent: update\ndata: line1\ndata:line2\ndata\n\n")
        #expect(events == [SSEEvent(type: "update", data: "line1\nline2\n")])
        #expect(parser.reconnectionTime == .milliseconds(2500))
    }

    @Test func invalidRetryIgnored() {
        var parser = SSEParser()
        _ = parser.feed("retry: 10s\n\nretry:\n\n")
        #expect(parser.reconnectionTime == nil)
    }

    @Test func eventTypeResetsAfterDispatchAndEmptyDataDoesNotDispatch() {
        var parser = SSEParser()
        let events = parser.feed("event: ping\n\ndata: x\n\n")
        #expect(events == [SSEEvent(type: "message", data: "x")])
    }

    @Test func idPersistsAndCanBeCleared() {
        var parser = SSEParser()
        var events = parser.feed("id: 7\ndata: a\n\ndata: b\n\nid\ndata: c\n\n")
        #expect(events.map(\.id) == ["7", "7", nil])
        #expect(parser.lastEventID == "")
        events = parser.feed("id: bad\u{0}id\ndata: d\n\n")
        #expect(events.map(\.id) == [nil])
    }

    @Test func idOnlyBlockUpdatesLastEventID() {
        var parser = SSEParser(lastEventID: "start")
        #expect(parser.feed("id: 42\n\n").isEmpty)
        #expect(parser.lastEventID == "42")
    }

    @Test func leadingBOMIsStripped() {
        var parser = SSEParser()
        let events = parser.feed([0xEF, 0xBB, 0xBF] + Array("data: x\n\n".utf8))
        #expect(events == [SSEEvent(data: "x")])
    }

    @Test func onlyOneLeadingSpaceRemovedAndColonsInValueKept() {
        var parser = SSEParser()
        let events = parser.feed("data:  two spaces: yes\n\n")
        #expect(events == [SSEEvent(data: " two spaces: yes")])
    }

    @Test func incompleteEventDiscardedOnFinish() {
        var parser = SSEParser()
        #expect(parser.feed("id: 1\ndata: partial\n").isEmpty)
        parser.finish()
        #expect(parser.feed("\n").isEmpty)
        #expect(parser.feed("data: next\n\n") == [SSEEvent(id: nil, data: "next")])
    }

    @Test func unknownFieldsAndUTF8() {
        var parser = SSEParser()
        let events = parser.feed("foo: bar\ndata: Küche 💡\n\n")
        #expect(events == [SSEEvent(data: "Küche 💡")])
    }
}
