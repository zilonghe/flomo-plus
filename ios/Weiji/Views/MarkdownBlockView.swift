import SwiftUI

struct MarkdownBlockView: View {
    let text: String
    var citations: [Citation] = []
    var openCitation: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block.kind {
                case .code:
                    ScrollView(.horizontal) {
                        Text(block.text).font(.system(.callout, design: .monospaced))
                            .padding(10).textSelection(.enabled)
                    }.background(Theme.line.opacity(0.45), in: .rect(cornerRadius: 8))
                case .heading:
                    styled(block.text).font(.headline)
                case .quote:
                    HStack(alignment: .top, spacing: 8) {
                        Rectangle().fill(Theme.green).frame(width: 2)
                        styled(block.text).foregroundStyle(.secondary)
                    }.fixedSize(horizontal: false, vertical: true)
                case .paragraph:
                    styled(block.text)
                }
            }
            let cited = references
            if !cited.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(cited, id: \.ref) { citation in
                            Button {
                                openCitation(citation.noteId)
                            } label: {
                                Label("[\(citation.ref)]", systemImage: "arrow.up.right").font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("citation-pill-" + citation.ref)
                            .accessibilityHint(citation.excerpt)
                        }
                    }
                }.scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var references: [Citation] {
        var seen = Set<String>()
        let shown = Set(CitationParser.split(text).compactMap { item -> String? in
            if case .reference(let ref) = item { return ref }
            return nil
        })
        return citations.filter { shown.contains($0.ref) && seen.insert($0.ref).inserted }
    }

    private func styled(_ value: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let rich = try? AttributedString(markdown: value, options: options) {
            return Text(rich)
        }
        return Text(value)
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
