import SwiftUI

struct MarkdownBlockView: View {
    let text: String
    var citations: [Citation] = []
    var openCitation: (String) -> Void = { _ in }

    var body: some View {
        let validMap = Self.validCitations(citations)
        let rendered = blocks.map { block in
            (block, block.kind == .code ? nil : Self.buildCitedAttributedString(block.text, validMap: validMap))
        }
        let shown = Set<String>(rendered.compactMap { $0.1 }.flatMap { rich in
            rich.runs.compactMap { run in
                run.link?.scheme == Self.citationScheme ? String(rich[run.range].characters) : nil
            }.flatMap { tokens in
                CitationParser.split(tokens).compactMap {
                    if case .reference(let ref) = $0 { return ref }
                    return nil
                }
            }
        })
        let allowedIDs = Set(validMap.values)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(rendered.enumerated()), id: \.offset) { _, row in
                let (block, rich) = row
                switch block.kind {
                case .code:
                    ScrollView(.horizontal) {
                        Text(block.text).font(.system(.callout, design: .monospaced))
                            .padding(10).textSelection(.enabled)
                    }.background(Theme.line.opacity(0.45), in: .rect(cornerRadius: 8))
                case .heading:
                    Text(rich ?? AttributedString(block.text)).font(.headline)
                case .quote:
                    HStack(alignment: .top, spacing: 8) {
                        Rectangle().fill(Theme.green).frame(width: 2)
                        Text(rich ?? AttributedString(block.text)).foregroundStyle(.secondary)
                    }.fixedSize(horizontal: false, vertical: true)
                case .paragraph:
                    Text(rich ?? AttributedString(block.text))
                }
            }
            let cited = references(shown: shown, validMap: validMap)
            if !cited.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(cited, id: \.ref) { citation in
                            Button {
                                if let id = validMap[citation.ref] { openCitation(id) }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 6) {
                                        Text("[\(citation.ref)]").font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6).padding(.vertical, 3)
                                            .foregroundStyle(Theme.active)
                                            .background(Theme.green.opacity(0.13), in: Capsule())
                                        Text(citation.bookTitle ?? citation.createdAt.map { String($0.prefix(10)) } ?? "笔记")
                                            .font(.caption.weight(.medium)).lineLimit(1)
                                        Spacer(minLength: 0)
                                        Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Text(citation.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .padding(9).frame(width: 200, alignment: .leading)
                                .background(Theme.green.opacity(0.06), in: .rect(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("citation-pill-" + citation.ref)
                        }
                    }
                }.scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme?.lowercased() == Self.citationScheme else { return .systemAction }
            guard let id = url.host()?.lowercased(), allowedIDs.contains(id),
                  url.absoluteString == "\(Self.citationScheme)://\(id)" else { return .discarded }
            openCitation(id)
            return .handled
        })
    }

    private static let citationScheme = "weiji-cite"
    private static let citationPattern = try! NSRegularExpression(pattern: #"\[(N[0-9]+)\]"#)

    private static func validCitations(_ citations: [Citation]) -> [String: String] {
        Dictionary(citations.compactMap { citation in
            UUID(uuidString: citation.noteId).map { (citation.ref, $0.uuidString.lowercased()) }
        }, uniquingKeysWith: { first, _ in first })
    }

    private func references(shown: Set<String>, validMap: [String: String]) -> [Citation] {
        var seen = Set<String>()
        return citations.filter {
            shown.contains($0.ref) && validMap[$0.ref] == $0.noteId.lowercased() && seen.insert($0.ref).inserted
        }
    }

    static func buildCitedAttributedString(_ value: String, citations: [Citation]) -> AttributedString {
        buildCitedAttributedString(value, validMap: validCitations(citations))
    }

    private static func buildCitedAttributedString(_ value: String, validMap: [String: String]) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var rich = (try? AttributedString(markdown: value, options: options)) ?? AttributedString(value)
        let plain = String(rich.characters)
        let matches = citationPattern.matches(in: plain, range: NSRange(plain.startIndex..., in: plain))
        let links: [(Range<AttributedString.Index>, URL)] = matches.compactMap { match in
            guard let token = Range(match.range, in: plain), let ref = Range(match.range(at: 1), in: plain),
                  let id = validMap[String(plain[ref])], let url = URL(string: citationScheme + "://" + id),
                  plain[token.upperBound...].first != "(",
                  let start = AttributedString.Index(token.lowerBound, within: rich),
                  let end = AttributedString.Index(token.upperBound, within: rich) else { return nil }
            let range = start..<end
            // Existing Markdown links never grant a citation, and longer code spans stay literal.
            for run in rich.runs where run.range.overlaps(range) {
                if run.link != nil { return nil }
                if run.inlinePresentationIntent?.contains(.code) == true, run.range != range { return nil }
            }
            return (range, url)
        }
        for run in rich.runs where run.link?.scheme?.lowercased() == citationScheme {
            rich[run.range].link = nil
        }
        for (range, url) in links {
            rich[range].link = url
            rich[range].foregroundColor = Theme.active
            rich[range].backgroundColor = Theme.green.opacity(0.13)
        }
        return rich
    }

    private struct Block {
        enum Kind { case heading, quote, code, paragraph }
        let kind: Kind
        let text: String
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var code: [String]? = nil
        for piece in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(piece)
            if line.hasPrefix("```") {
                if let lines = code { result.append(Block(kind: .code, text: lines.joined(separator: "\n"))); code = nil }
                else { code = [] }
            } else if code != nil {
                code?.append(line)
            } else if line.hasPrefix("#"), let space = line.firstIndex(of: " "),
                      line[..<space].allSatisfy({ $0 == "#" }) {
                result.append(Block(kind: .heading, text: String(line[line.index(after: space)...])))
            } else if line.hasPrefix("> ") {
                result.append(Block(kind: .quote, text: String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                result.append(Block(kind: .paragraph, text: "• " + line.dropFirst(2)))
            } else if !line.isEmpty {
                result.append(Block(kind: .paragraph, text: line))
            }
        }
        if let code { result.append(Block(kind: .code, text: code.joined(separator: "\n"))) }
        return result
    }
}
