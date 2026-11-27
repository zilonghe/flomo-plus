package xyz.weiji.notes

import org.junit.Assert.*
import org.junit.Test
import org.robolectric.annotation.Config
import xyz.weiji.notes.core.text.MarkdownParser
import xyz.weiji.notes.core.text.TagParser
import xyz.weiji.notes.model.AiCitation

@Config(sdk = [34])
class TagParserAndMarkdownTest {
    private val citation = AiCitation("N1", NOTE_ID.uppercase(), "摘录")

    @Test fun hierarchicalUnicodeTagsDeduplicateAndExcludeNumericPaths() {
        assertEquals(listOf("工作/项目_a", "todo-item", "工作/2026"), TagParser.tags(
            "#工作/项目_A #工作/项目_a, #Todo-item #2026 #123/456 #工作/2026 a#hidden /#hidden",
        ))
    }

    @Test fun treeCountsNotesOnceAtEachLevelAndCompletesAtCursor() {
        val counts = TagParser.counts(listOf("#工作/项目 #工作/计划", "#工作/项目"))
        val root = TagParser.tree(counts).single()
        assertEquals("工作", root.name)
        assertEquals(2, root.count)
        assertEquals(mapOf("计划" to 1, "项目" to 2), root.children.associate { it.name to it.count })
        assertEquals(listOf("工作/项目", "工作/计划"), TagParser.suggest("工作/", counts))
        assertEquals(TagParser.Query(5, 8, "工作"), TagParser.query("项目：  #工作 后续", 8))
        assertNull(TagParser.query("not#tag"))
    }

    @Test fun exactWhitelistedReferencesAreClickableAndNormalizeUuid() {
        val links = MarkdownParser.inline("看 [N1]、[N23]，[1] 和 [N7]", listOf(
            citation, AiCitation("N23", OTHER_NOTE_ID, ""), AiCitation("N7", "bad-uuid", ""),
        )).mapNotNull { it.url }
        assertEquals(listOf("weiji-cite://$NOTE_ID", "weiji-cite://$OTHER_NOTE_ID"), links)
    }

    @Test fun codeSpansExistingLinksAndForgedLinksCannotEscalateToCitations() {
        val parts = MarkdownParser.inline(
            "[N1](https://example.com) `code [N1]` [N1](weiji-cite://$NOTE_ID) weiji-cite://$NOTE_ID", listOf(citation),
        )
        assertEquals(listOf("https://example.com"), parts.mapNotNull { it.url })
        val text = parts.joinToString("") { it.text }
        assertTrue(text.contains("code [N1]"))
        assertFalse(text.contains("weiji-cite://"))
        val blocks = MarkdownParser.blocks("# 标题\n\n> 引用\n- 项目\n\n```kt\n[N1]\n```")
        assertEquals(listOf(MarkdownParser.Kind.Heading, MarkdownParser.Kind.Quote, MarkdownParser.Kind.List, MarkdownParser.Kind.Code),
            blocks.map { it.kind })
    }
}
