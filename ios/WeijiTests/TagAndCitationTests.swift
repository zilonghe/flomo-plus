import XCTest
@testable import Weiji

final class TagAndCitationTests: XCTestCase {
    func testExtractsTagsMatchingBackendAndIgnoresPureDigits() {
        XCTAssertEqual(TagParser.tags(in: "word#skip 汉#跳过 _#no #Work/复盘 #WORK/复盘 #123 #１２３ #Ⅻ #12/34 #A1 #日语_1 #abc//def"),
                       ["work/复盘", "12/34", "a1", "日语_1", "abc"])
    }

    func testBuildsTagTreeAnd84DayHeatmap() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3600))
        let iso = ISO8601DateFormatter()
        let now = try XCTUnwrap(iso.date(from: "2025-04-01T02:00:00Z"))
        let index = NoteIndex([
            Note(id: "a", body: "#工作/复盘 #工作/执行", createdAt: "2025-03-31T18:00:00Z", revision: 1),
            Note(id: "b", body: "#工作", createdAt: "2025-03-31T14:00:00Z", revision: 1),
            Note(id: "c", body: "#生活", createdAt: "2024-12-30T14:00:00Z", revision: 1),
        ], now: now, calendar: calendar)
        XCTAssertEqual(index.heatmap.count, 84)
        XCTAssertEqual(index.heatmap.first?.id, "2025-01-08")
        XCTAssertEqual(index.heatmap.suffix(2).map(\.id), ["2025-03-31", "2025-04-01"])
        XCTAssertEqual(index.heatmap.reduce(0) { $0 + $1.count }, 2)
        XCTAssertEqual(index.heatmap.last?.count, 1)
        let work = try XCTUnwrap(index.tags.first { $0.path == "工作" })
        XCTAssertEqual(work.count, 2)
        XCTAssertEqual(work.children.map(\.path), ["工作/复盘", "工作/执行"])
        XCTAssertEqual(index.search("", filter: NoteFilter(tag: "工作")).map(\.id), ["a", "b"])
    }

    func testPlainAndExactCodeCitationTokensLinkOnlyKnownNotes() {
        let noteId = "B894267D-D55D-4F48-83D6-D67B092ED652"
        let citations = [
            Citation(ref: "N1", noteId: noteId, excerpt: ""),
            Citation(ref: "N2", noteId: "not-a-uuid", excerpt: ""),
            Citation(ref: "N1", noteId: "FC3F0355-17E5-4B86-8BF1-362C27E8D29F", excerpt: ""),
        ]
        let rich = MarkdownBlockView.buildCitedAttributedString("笔记👨‍👩‍👧‍👦 [N1] · `[N1]` · `code [N1]` · `code` · [N2] · [N3]", citations: citations)
        let linkedRuns = rich.runs.filter { $0.link != nil }
        XCTAssertEqual(linkedRuns.map { String(rich[$0.range].characters) }, ["[N1]", "[N1]"])
        XCTAssertEqual(linkedRuns.compactMap { $0.link?.absoluteString },
                       Array(repeating: "weiji-cite://" + noteId.lowercased(), count: 2))
        XCTAssertTrue(String(rich.characters).contains("code [N1]"))

        let adjacent = MarkdownBlockView.buildCitedAttributedString("[N1][N4]", citations: citations + [
            Citation(ref: "N4", noteId: "FC3F0355-17E5-4B86-8BF1-362C27E8D29F", excerpt: ""),
        ])
        XCTAssertEqual(adjacent.runs.filter { $0.link != nil }.map { String(adjacent[$0.range].characters) },
                       ["[N1]", "[N4]"])
    }

    func testModelSuppliedCitationURLsAreNeverActiveEvenWithAnAllowedDestination() {
        let allowed = "b894267d-d55d-4f48-83d6-d67b092ed652"
        let citations = [Citation(ref: "N1", noteId: allowed, excerpt: "")]
        let samples = [
            "[N1](weiji-cite://00000000-0000-0000-0000-000000000000)",
            "[N1](WEIJI-CITE://\(allowed))",
            "[other](weiji-cite://\(allowed))",
            "<weiji-cite://\(allowed)>",
            "[N1](weiji-cite://bad host)",
            "[N1](not a URL)",
        ]
        for sample in samples {
            let rich = MarkdownBlockView.buildCitedAttributedString(sample, citations: citations)
            XCTAssertTrue(rich.runs.allSatisfy { $0.link == nil }, sample)
        }
        let normal = MarkdownBlockView.buildCitedAttributedString("[Docs](https://example.org)", citations: citations)
        XCTAssertEqual(normal.runs.first?.link?.absoluteString, "https://example.org")
    }

    func testSplitsCitationRefs() {
        XCTAssertEqual(CitationParser.split("甲[N1][N20]乙 [N0] [n3] [N]"),
                       [.text("甲"), .reference("N1"), .reference("N20"), .text("乙 "), .reference("N0"), .text(" [n3] [N]")])
        XCTAssertEqual(CitationParser.split(""), [])
    }
}
