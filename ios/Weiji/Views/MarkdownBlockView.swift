import SwiftUI

struct MarkdownBlockView: View {
    let text: String
    var citations: [Citation] = []
    var openCitation: (String) -> Void = { _ in }

    var body: some View {
        let validMap = Self.validCitations(citations)
        let rendered = Self.blocks(text).map { block in
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
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(rendered.enumerated()), id: \.offset) { index, row in
                let (block, rich) = row
                let content = rich ?? AttributedString(block.text)
                switch block.kind {
                case .code:
                    ScrollView(.horizontal) {
                        Text(block.text).font(.system(.callout, design: .monospaced))
                            .padding(12).textSelection(.enabled)
                    }.background(Theme.subtle, in: .rect(cornerRadius: 10))
                case .heading(let level):
                    Text(content)
                        .font(level == 1 ? .title3.weight(.bold) : level == 2 ? .headline : .callout.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .padding(.top, index == 0 ? 0 : level == 1 ? 12 : level == 2 ? 8 : 5)
                        .accessibilityAddTraits(.isHeader)
                case .rule:
                    Divider().padding(.vertical, 6)
                case .quote:
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 1).fill(Theme.green.opacity(0.6)).frame(width: 3)
                        Text(content).foregroundStyle(Theme.ink2)
                    }.fixedSize(horizontal: false, vertical: true)
                case .bullet(let level):
                    listRow(level: level, marker: Text(level == 0 ? "•" : "◦").foregroundStyle(Theme.ink3), content: content)
                case .ordered(let number, let level):
                    listRow(level: level, marker: Text(number + ".").monospacedDigit().foregroundStyle(Theme.ink2), content: content)
                case .paragraph:
                    Text(content)
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
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(spacing: 6) {
                                        Text(citation.ref).font(.caption2.weight(.semibold)).monospacedDigit()
                                            .foregroundStyle(Theme.active)
                                            .padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(Theme.accentSoft, in: .rect(cornerRadius: 5))
                                        Text(citation.bookTitle ?? citation.createdAt.map { String($0.prefix(10)) } ?? "笔记")
                                            .font(.caption.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    Text(citation.excerpt).font(.caption).foregroundStyle(Theme.ink2).lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                }
                                .padding(10).frame(width: 210, height: 72, alignment: .topLeading)
                                .background(Theme.paper, in: .rect(cornerRadius: 12))
                                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline) }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("citation-pill-" + citation.ref)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollClipDisabled()
                .scrollIndicators(.hidden)
                .padding(.top, 4)
            }
        }
        .lineSpacing(4)
        .foregroundStyle(Theme.ink)
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
            rich[range].backgroundColor = Theme.accentSoft
            rich[range].font = .footnote.weight(.semibold)
        }
        return rich
    }

    struct Block: Equatable {
        enum Kind: Equatable {
            case heading(Int), quote, code, rule, paragraph
            case bullet(level: Int)
            case ordered(String, level: Int)
        }
        let kind: Kind
        let text: String
    }

    private static let orderedPattern = try! NSRegularExpression(pattern: #"^([0-9]{1,3})[.)] +(.*)$"#)

    static func blocks(_ text: String) -> [Block] {
        var result: [Block] = []
        var code: [String]? = nil
        for piece in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(piece)
            let body = line.drop { $0 == " " || $0 == "\t" }
            if body.hasPrefix("```") {
                if let lines = code { result.append(Block(kind: .code, text: lines.joined(separator: "\n"))); code = nil }
                else { code = [] }
                continue
            }
            if code != nil { code?.append(line); continue }
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // Two spaces (or a tab) per nesting level, as models usually emit.
            let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
            let level = min(indent / 2, 3)
            let compact = trimmed.filter { $0 != " " }
            if compact.count >= 3, let mark = compact.first, "-*_".contains(mark), compact.allSatisfy({ $0 == mark }) {
                result.append(Block(kind: .rule, text: ""))
            } else if indent < 4, trimmed.hasPrefix("#"), let space = trimmed.firstIndex(of: " "),
                      trimmed[..<space].allSatisfy({ $0 == "#" }) {
                let hashes = trimmed.distance(from: trimmed.startIndex, to: space)
                result.append(Block(kind: .heading(min(hashes, 3)),
                                    text: trimmed[space...].trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix(">") {
                result.append(Block(kind: .quote, text: String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                result.append(Block(kind: .bullet(level: level), text: String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
            } else if let match = orderedPattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                      let number = Range(match.range(at: 1), in: trimmed), let rest = Range(match.range(at: 2), in: trimmed) {
                result.append(Block(kind: .ordered(String(trimmed[number]), level: level), text: String(trimmed[rest])))
            } else {
                result.append(Block(kind: .paragraph, text: trimmed))
            }
        }
        if let code { result.append(Block(kind: .code, text: code.joined(separator: "\n"))) }
        return result
    }

    private func listRow(level: Int, marker: Text, content: AttributedString) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker.frame(minWidth: 14, alignment: .trailing).accessibilityHidden(true)
            Text(content).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(level) * 18)
    }
}
