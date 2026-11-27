import SwiftUI
import UIKit
import XCTest
@testable import Weiji

final class TagAndCitationTests: XCTestCase {
    func testExtractsTagsMatchingBackendAndIgnoresPureDigits() {
        XCTAssertEqual(TagParser.tags(in: "word#skip 汉#跳过 _#no #Work/复盘 #WORK/复盘 #123 #１２３ #Ⅻ #12/34 #A1 #日语_1 #abc//def"),
                       ["work/复盘", "12/34", "a1", "日语_1", "abc"])
    }

    func testHighlightingTagsLinksFullBodyAndSkipsPureDigits() {
        let body = "👨‍👩‍👧‍👦 #碎碎念/职场 #12/34 #2026 #碎碎念/职场 " + String(repeating: "字", count: 500) + " #尾标签"
        let expected = ["#碎碎念/职场", "#12/34", "#碎碎念/职场", "#尾标签"]
        let preview = NoteCardContent.highlightingTags(body, limit: 400, linkTags: false)
        XCTAssertEqual(String(preview.characters), String(body.prefix(400)))
        XCTAssertTrue(preview.runs.allSatisfy { $0.link == nil })
        XCTAssertEqual(preview.runs.filter { $0.foregroundColor != nil }.map { String(preview[$0.range].characters) },
                       Array(expected.dropLast()))

        let reader = NoteCardContent.highlightingTags(body, limit: nil, linkTags: true)
        XCTAssertEqual(String(reader.characters), body)
        let links = reader.runs.filter { $0.link != nil }
        XCTAssertEqual(links.map { String(reader[$0.range].characters) }, expected)
        XCTAssertEqual(links.compactMap { $0.link.flatMap(TagParser.tagPath(from:)) }, expected.map { String($0.dropFirst()) })
        XCTAssertEqual(reader.runs.filter { $0.foregroundColor != nil }.map { String(reader[$0.range].characters) }, expected)
        let traits = UITraitCollection(userInterfaceStyle: .light)
        let active = UIColor(Theme.active).resolvedColor(with: traits)
        for run in links {
            XCTAssertEqual(run.foregroundColor.map { UIColor($0).resolvedColor(with: traits) }, active)
        }
        for url in ["https://tag?name=工作", "weiji://note?name=工作", "weiji://tag?name=", "weiji://tag"] {
            XCTAssertNil(URL(string: url).flatMap(TagParser.tagPath(from:)), url)
        }
    }

    func testNoteDateFormatterFormatsISO8601WithAndWithoutFractionalSeconds() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let locale = Locale(identifier: "zh_Hans_CN")
        for value in ["2026-11-25T06:29:00.123Z", "2026-11-25T06:29:00Z"] {
            XCTAssertEqual(NoteDateFormatter.fullDisplay(from: value, locale: locale, timeZone: zone), "2026年11月25日 周三 14:29")
        }
        XCTAssertEqual(NoteDateFormatter.fullDisplay(from: "2026-11-25", locale: locale, timeZone: zone), "2026-11-25")
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

    func testMarkdownBlocksParseRulesHeadingLevelsAndNestedLists() {
        let text = "# 标题\n## 小节\n### 细节\n---\n***\n_ _ _\n- 一级\n  - 【推测】二级\n    * 三级\n      - 四级\n        - 五级\n1. 第一\n  2) 第二\n> 引用\n```\n- 代码\n```\n普通段落\n#tag 不是标题"
        let blocks = MarkdownBlockView.blocks(text)
        XCTAssertEqual(blocks.map(\.kind), [
            .heading(1), .heading(2), .heading(3), .rule, .rule, .rule,
            .bullet(level: 0), .bullet(level: 1), .bullet(level: 2), .bullet(level: 3), .bullet(level: 4),
            .ordered("1", level: 0), .ordered("2", level: 1),
            .quote, .code, .paragraph, .paragraph,
        ])
        XCTAssertEqual(blocks.map(\.text), [
            "标题", "小节", "细节", "", "", "", "一级", "【推测】二级", "三级", "四级", "五级", "第一", "第二", "引用", "- 代码", "普通段落", "#tag 不是标题",
        ])
        XCTAssertFalse(blocks.contains { $0.text.contains("---") })
    }

    func testThemeContrastMeetsWCAGInLightAndDarkMode() {
        func luminance(_ color: UIColor) -> Double {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a))
            func linear(_ c: CGFloat) -> Double {
                let v = Double(c)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        func contrast(_ a: Color, _ b: Color, style: UIUserInterfaceStyle) -> Double {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let la = luminance(UIColor(a).resolvedColor(with: traits))
            let lb = luminance(UIColor(b).resolvedColor(with: traits))
            return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
        }
        for style: UIUserInterfaceStyle in [.light, .dark] {
            let mode = style == .light ? "light" : "dark"
            XCTAssertGreaterThanOrEqual(contrast(Theme.ink, Theme.canvas, style: style), 7.0, "body-on-canvas contrast (\(mode))")
            XCTAssertGreaterThanOrEqual(contrast(Theme.ink, Theme.paper, style: style), 7.0, "body-on-paper contrast (\(mode))")
            XCTAssertGreaterThanOrEqual(contrast(Theme.ink2, Theme.canvas, style: style), 4.5, "ink2-on-canvas contrast (\(mode))")
            XCTAssertGreaterThanOrEqual(contrast(Theme.ink2, Theme.paper, style: style), 4.5, "ink2-on-paper contrast (\(mode))")
            XCTAssertGreaterThanOrEqual(contrast(Theme.ink3, Theme.canvas, style: style), 4.5, "ink3-on-canvas contrast (\(mode))")
            XCTAssertGreaterThanOrEqual(contrast(Theme.ink3, Theme.paper, style: style), 4.5, "ink3-on-paper contrast (\(mode))")
            for accent in ThemeAccent.allCases {
                let tag = "\(accent.rawValue)/\(mode)"
                XCTAssertGreaterThanOrEqual(contrast(.white, accent.accent, style: style), 4.5, "white-on-accent (\(tag))")
                XCTAssertGreaterThanOrEqual(contrast(accent.active, accent.accentSoft, style: style), 4.5, "active-on-soft (\(tag))")
                XCTAssertGreaterThanOrEqual(contrast(accent.active, Theme.paper, style: style), 4.5, "active-on-paper (\(tag))")
                XCTAssertGreaterThanOrEqual(contrast(accent.active, Theme.canvas, style: style), 4.5, "active-on-canvas (\(tag))")
            }
        }
    }

    func testThemeContrastMeetsWCAGInHighContrastMode() {
        for style: UIUserInterfaceStyle in [.light, .dark] {
            let traits = UITraitCollection(traitsFrom: [
                UITraitCollection(userInterfaceStyle: style),
                UITraitCollection(accessibilityContrast: .high)
            ])
            func luminance(_ color: Color) -> Double {
                let resolved = UIColor(color).resolvedColor(with: traits)
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                XCTAssertTrue(resolved.getRed(&r, green: &g, blue: &b, alpha: &a))
                XCTAssertEqual(a, 1)
                func linear(_ channel: CGFloat) -> Double {
                    let c = Double(channel)
                    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
                }
                return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
            }
            func assertContrast(_ foreground: Color, _ background: Color, _ role: String, line: UInt = #line) {
                let fg = luminance(foreground), bg = luminance(background)
                let ratio = (max(fg, bg) + 0.05) / (min(fg, bg) + 0.05)
                XCTAssertGreaterThanOrEqual(ratio, 7, "\(role), \(style == .dark ? "dark" : "light")", line: line)
            }
            for (ink, name) in [(Theme.ink, "ink"), (Theme.ink2, "ink2"), (Theme.ink3, "ink3")] {
                assertContrast(ink, Theme.canvas, "\(name)-on-canvas")
                assertContrast(ink, Theme.paper, "\(name)-on-paper")
            }
            for accent in ThemeAccent.allCases {
                assertContrast(.white, accent.accent, "\(accent.rawValue) white-on-accent")
                assertContrast(accent.active, accent.accentSoft, "\(accent.rawValue) active-on-soft")
                assertContrast(accent.active, Theme.paper, "\(accent.rawValue) active-on-paper")
                assertContrast(accent.active, Theme.canvas, "\(accent.rawValue) active-on-canvas")
            }
        }
    }

    func testThemeManagerPersistsSelectedAccent() throws {
        let suiteName = "weiji.tests.theme.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = ThemeManager(defaults: defaults)
        XCTAssertEqual(manager.accent, .pine)

        manager.accent = .plum
        XCTAssertEqual(defaults.string(forKey: ThemeManager.storageKey), ThemeAccent.plum.rawValue)

        let reloaded = ThemeManager(defaults: defaults)
        XCTAssertEqual(reloaded.accent, .plum)

        defaults.set("unknown-accent", forKey: ThemeManager.storageKey)
        XCTAssertEqual(ThemeManager(defaults: defaults).accent, .pine)
    }

    func testActiveTagQueryDetectsValidTriggersAndIgnoresInvalidBoundaries() throws {
        let bare = try XCTUnwrap(TagParser.activeTagQuery(in: "#"))
        XCTAssertEqual(bare.query, "")
        XCTAssertEqual(String("#"[bare.range]), "#")

        let prefixText = "想法 #ar"
        let prefix = try XCTUnwrap(TagParser.activeTagQuery(in: prefixText))
        XCTAssertEqual(prefix.query, "ar")
        XCTAssertEqual(String(prefixText[prefix.range]), "#ar")

        let nestedText = "记录 #工作/复"
        let nested = try XCTUnwrap(TagParser.activeTagQuery(in: nestedText))
        XCTAssertEqual(nested.query, "工作/复")
        XCTAssertEqual(String(nestedText[nested.range]), "#工作/复")

        let midText = "记录 #工作/复 明日继续"
        let midCursor = try XCTUnwrap(midText.range(of: "#工作/复")?.upperBound)
        let mid = try XCTUnwrap(TagParser.activeTagQuery(in: midText, cursor: midCursor))
        XCTAssertEqual(mid.query, "工作/复")
        XCTAssertEqual(String(midText[mid.range]), "#工作/复")

        for nonTrigger in ["", "word#skip", "123#skip", "_#skip", "汉#跳过", "#tag ", "普通文本"] {
            XCTAssertNil(TagParser.activeTagQuery(in: nonTrigger), nonTrigger)
        }
        XCTAssertNil(TagParser.activeTagQuery(in: "#ar", cursor: "#ar".startIndex))
    }

    func testSuggestTagsRanksPrefixAheadOfSubstringWithFrequencyTieBreakAndLimit() {
        let candidates = ["area/思考", "area/产品", "work/area", "bar", "archive", "area/思考"]
        let counts = ["area/思考": 2, "area/产品": 5, "work/area": 10, "bar": 20, "archive": 1]

        XCTAssertEqual(
            TagParser.suggestTags(for: "ar", from: candidates, counts: counts, limit: 8),
            ["area/产品", "area/思考", "archive", "work/area", "bar"]
        )
        XCTAssertEqual(
            TagParser.suggestTags(for: "ar", from: candidates, counts: counts, limit: 2),
            ["area/产品", "area/思考"]
        )
        XCTAssertEqual(
            TagParser.suggestTags(for: "", from: candidates, counts: counts, limit: 3),
            ["bar", "work/area", "area/产品"]
        )
        XCTAssertEqual(TagParser.suggestTags(for: "ar", from: candidates, counts: counts, limit: 0), [])
    }

    func testApplyTagSuggestionInsertsSpaceWithoutDoublingExistingWhitespace() throws {
        let endText = "写点什么 #ar"
        let endQuery = try XCTUnwrap(TagParser.activeTagQuery(in: endText))
        let endApplied = TagParser.applyTagSuggestion("area/思考", in: endText, replacing: endQuery.range)
        XCTAssertEqual(endApplied.text, "写点什么 #area/思考 ")
        XCTAssertEqual(endApplied.cursor, endApplied.text.endIndex)

        let spacedText = "写点什么 #ar 后续"
        let spacedCursor = try XCTUnwrap(spacedText.range(of: "#ar")?.upperBound)
        let spacedQuery = try XCTUnwrap(TagParser.activeTagQuery(in: spacedText, cursor: spacedCursor))
        let spacedApplied = TagParser.applyTagSuggestion("area/思考", in: spacedText, replacing: spacedQuery.range)
        XCTAssertEqual(spacedApplied.text, "写点什么 #area/思考 后续")
        XCTAssertEqual(String(spacedApplied.text[spacedApplied.cursor...]), "后续")

        let tightText = "写点什么 #ar后续"
        let tightCursor = try XCTUnwrap(tightText.range(of: "#ar")?.upperBound)
        let tightQuery = try XCTUnwrap(TagParser.activeTagQuery(in: tightText, cursor: tightCursor))
        let tightApplied = TagParser.applyTagSuggestion("area/思考", in: tightText, replacing: tightQuery.range)
        XCTAssertEqual(tightApplied.text, "写点什么 #area/思考 后续")
        XCTAssertEqual(String(tightApplied.text[tightApplied.cursor...]), "后续")
    }
}
