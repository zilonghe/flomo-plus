import Foundation

enum TagParser {
    private static let matcher = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])#([\p{L}\p{N}_]+(?:/[\p{L}\p{N}_]+)*)"#)
    private static let nonNumber = try! NSRegularExpression(pattern: #"[^\p{N}]"#)

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
