import Foundation

enum TagParser {
    private static let matcher = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])#([\p{L}\p{N}_]+(?:/[\p{L}\p{N}_]+)*)"#)
    private static let nonNumber = try! NSRegularExpression(pattern: #"[^\p{N}]"#)

    struct ActiveTagQuery: Equatable, Sendable {
        let range: Range<String.Index>
        let query: String
    }

    static func tags(in text: String) -> [String] {
        var seen = Set<String>()
        return matcher.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            let tag = text[range].lowercased()
            guard nonNumber.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) != nil,
                  seen.insert(tag).inserted else { return nil }
            return tag
        }
    }

    /// Detects an active `#prefix` token immediately preceding `cursor` (defaults to end of `text`).
    static func activeTagQuery(in text: String, cursor: String.Index? = nil) -> ActiveTagQuery? {
        let end = cursor.map { min($0, text.endIndex) } ?? text.endIndex
        guard end > text.startIndex else { return nil }
        var index = end
        while index > text.startIndex {
            let previous = text.index(before: index)
            let ch = text[previous]
            if ch == "#" {
                if previous > text.startIndex {
                    let beforeHash = text[text.index(before: previous)]
                    if isTagWordChar(beforeHash) { return nil }
                }
                let query = String(text[index..<end])
                return ActiveTagQuery(range: previous..<end, query: query)
            }
            if isTagBodyChar(ch) {
                index = previous
            } else {
                return nil
            }
        }
        return nil
    }

    static func suggestTags(for query: String, from candidates: [String], counts: [String: Int] = [:], limit: Int = 8) -> [String] {
        guard limit > 0 else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let unique = Array(Set(candidates))
        if trimmed.isEmpty {
            return unique.sorted { a, b in
                let ca = counts[a, default: 0], cb = counts[b, default: 0]
                return ca != cb ? ca > cb : a < b
            }.prefix(limit).map { $0 }
        }
        let ranked: [(tag: String, tier: Int, count: Int)] = unique.compactMap { tag in
            let lower = tag.lowercased()
            let tier: Int
            if lower == trimmed { tier = 0 }
            else if lower.hasPrefix(trimmed) { tier = 1 }
            else if lower.split(separator: "/").contains(where: { $0.hasPrefix(trimmed) }) { tier = 2 }
            else if lower.contains(trimmed) { tier = 3 }
            else { return nil }
            return (tag, tier, counts[tag, default: 0])
        }
        return ranked.sorted { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            if a.count != b.count { return a.count > b.count }
            if a.tag.count != b.tag.count { return a.tag.count < b.tag.count }
            return a.tag < b.tag
        }.prefix(limit).map(\.tag)
    }

    static func applyTagSuggestion(_ tag: String, in text: String, replacing range: Range<String.Index>) -> (text: String, cursor: String.Index) {
        let needsTrailingSpace = range.upperBound == text.endIndex || !text[range.upperBound].isWhitespace
        let insertion = "#" + tag + (needsTrailingSpace ? " " : "")
        let prefix = text[..<range.lowerBound]
        let suffix = text[range.upperBound...]
        let updated = String(prefix) + insertion + String(suffix)
        let advanceCount = prefix.count + insertion.count + (needsTrailingSpace ? 0 : 1)
        let cursor = updated.index(updated.startIndex, offsetBy: min(advanceCount, updated.count))
        return (updated, cursor)
    }

    private static func isTagWordChar(_ ch: Character) -> Bool {
        ch == "_" || ch.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
    }

    private static func isTagBodyChar(_ ch: Character) -> Bool {
        ch == "/" || isTagWordChar(ch)
    }

    struct Node: Identifiable, Sendable {
        let path: String
        let count: Int
        let children: [Node]
        var id: String { path }
        var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    }

    static func tree(_ counts: [String: Int]) -> [Node] {
        let grouped = Dictionary(grouping: counts.keys) { path in
            path.lastIndex(of: "/").map { String(path[..<$0]) } ?? ""
        }
        func children(of path: String) -> [Node] {
            (grouped[path] ?? []).sorted().map { Node(path: $0, count: counts[$0] ?? 0, children: children(of: $0)) }
        }
        return children(of: "")
    }
}

enum CitationParser {
    enum Segment: Equatable { case text(String), reference(String) }
    private static let matcher = try! NSRegularExpression(pattern: #"\[(N[0-9]+)\]"#)

    static func split(_ text: String) -> [Segment] {
        var parts: [Segment] = []
        var start = text.startIndex
        for hit in matcher.matches(in: text, range: NSRange(start..., in: text)) {
            guard let range = Range(hit.range, in: text), let ref = Range(hit.range(at: 1), in: text) else { continue }
            if start < range.lowerBound { parts.append(.text(String(text[start..<range.lowerBound]))) }
            parts.append(.reference(String(text[ref])))
            start = range.upperBound
        }
        if start < text.endIndex { parts.append(.text(String(text[start...]))) }
        return parts
    }
}
