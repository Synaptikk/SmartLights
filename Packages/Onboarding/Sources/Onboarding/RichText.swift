import Foundation

/// Guide copy with a tiny markdown subset, stored as its source string (so guides stay readable JSON).
///
/// Supported syntax:
/// - `**bold**` for UI labels the user must find ("tap **Allow**"),
/// - `` `code` `` for protocol names, ports, JSON keys,
/// - `[label](https://...)` links,
/// - lines starting with `- ` are bullets; every other non-empty line is a paragraph.
///
/// Anything else is shown literally. Unclosed markers are treated as plain text.
public struct RichText: Codable, Sendable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    public enum Inline: Sendable, Hashable {
        case text(String)
        case bold(String)
        case code(String)
        case link(label: String, url: String)
    }

    public enum Block: Sendable, Hashable {
        case paragraph([Inline])
        case bullet([Inline])
    }

    public var source: String

    public init(_ source: String) { self.source = source }
    public init(stringLiteral value: String) { self.source = value }

    public init(from decoder: any Decoder) throws {
        source = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(source)
    }

    public var description: String { source }
    public var isEmpty: Bool { source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Parsed blocks, in order.
    public var blocks: [Block] {
        source.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            if line.hasPrefix("- ") {
                return .bullet(Self.inlines(in: line.dropFirst(2)))
            }
            return .paragraph(Self.inlines(in: Substring(line)))
        }
    }

    /// Text without markup (bullets prefixed with "- "), lines joined by "\n".
    public var plainText: String {
        blocks.map { block in
            switch block {
            case .paragraph(let inlines): Self.plain(inlines)
            case .bullet(let inlines): "- " + Self.plain(inlines)
            }
        }.joined(separator: "\n")
    }

    /// All link targets in the text (for link-out validation).
    public var links: [String] {
        blocks.flatMap { block -> [Inline] in
            switch block {
            case .paragraph(let i), .bullet(let i): i
            }
        }.compactMap { if case .link(_, let url) = $0 { url } else { nil } }
    }

    static func plain(_ inlines: [Inline]) -> String {
        inlines.map { inline in
            switch inline {
            case .text(let s), .bold(let s), .code(let s): s
            case .link(let label, _): label
            }
        }.joined()
    }

    /// Parses one line into inline runs.
    static func inlines(in line: Substring) -> [Inline] {
        var result: [Inline] = []
        var buffer = ""
        var i = line.startIndex

        func flush() {
            if !buffer.isEmpty { result.append(.text(buffer)); buffer = "" }
        }

        while i < line.endIndex {
            let rest = line[i...]
            if rest.hasPrefix("**"),
               let close = rest.dropFirst(2).range(of: "**"),
               close.lowerBound > rest.index(i, offsetBy: 2) {
                flush()
                result.append(.bold(String(line[line.index(i, offsetBy: 2)..<close.lowerBound])))
                i = close.upperBound
                continue
            }
            if rest.hasPrefix("`"),
               let close = rest.dropFirst().firstIndex(of: "`"),
               close > line.index(after: i) {
                flush()
                result.append(.code(String(line[line.index(after: i)..<close])))
                i = line.index(after: close)
                continue
            }
            if rest.hasPrefix("["),
               let mid = rest.range(of: "]("),
               let close = rest[mid.upperBound...].firstIndex(of: ")") {
                let label = String(line[line.index(after: i)..<mid.lowerBound])
                let url = String(line[mid.upperBound..<close])
                if !label.isEmpty, !url.isEmpty, !label.contains("[") {
                    flush()
                    result.append(.link(label: label, url: url))
                    i = line.index(after: close)
                    continue
                }
            }
            buffer.append(line[i])
            i = line.index(after: i)
        }
        flush()
        return result
    }
}
