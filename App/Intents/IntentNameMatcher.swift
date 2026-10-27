import Foundation

/// Fuzzy name matching for Siri / Shortcuts entity queries.
///
/// Siri hands us whatever the user said ("the sofa lamp", "kitchen lights", "Living"), so the
/// matcher is forgiving: case-, diacritic- and width-insensitive, whitespace collapsed, and it
/// ranks candidates so the most plausible match comes first:
///
/// 0. exact name
/// 1. name starts with the query ("Liv" -> "Living Room")
/// 2. a word in the name starts with the query ("lamp" -> "Sofa Lamp")
/// 3. name contains the query ("ofa" -> "Sofa Lamp")
/// 4. the query contains the whole name ("the bedroom lights" -> "Bedroom")
///
/// Pure Swift so it is unit-tested without the App Intents runtime.
enum IntentNameMatcher {
    /// Lower-cased, diacritic-free, single-spaced form used for comparisons.
    static func normalize(_ string: String) -> String {
        let folded = string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return folded
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Match rank of `candidate` for `query` (lower is better), or nil if it does not match.
    static func rank(_ candidate: String, query: String) -> Int? {
        let name = normalize(candidate)
        let needle = normalize(query)
        guard !name.isEmpty, !needle.isEmpty else { return nil }
        if name == needle { return 0 }
        if name.hasPrefix(needle) { return 1 }
        if name.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) { return 2 }
        if name.contains(needle) { return 3 }
        // "turn on the bedroom lights": the spoken phrase wraps the name. Require a whole-word
        // hit and a minimum length so "a" or "on" never match everything.
        if name.count >= 3, " \(needle) ".contains(" \(name) ") {
            return 4
        }
        return nil
    }

    /// Items whose name matches `query`, best rank first, then by name.
    static func filter<Item>(_ items: [Item], matching query: String, name: (Item) -> String) -> [Item] {
        items
            .compactMap { item -> (Item, Int, String)? in
                let itemName = name(item)
                guard let rank = rank(itemName, query: query) else { return nil }
                return (item, rank, itemName)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.2.localizedStandardCompare(rhs.2) == .orderedAscending
            }
            .map(\.0)
    }
}
