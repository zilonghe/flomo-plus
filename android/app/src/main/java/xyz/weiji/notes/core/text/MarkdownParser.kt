package xyz.weiji.notes.core.text

import java.util.Locale
import xyz.weiji.notes.model.AiCitation

object MarkdownParser {
    private const val CITE = "weiji-cite://"
    private val uuid = Regex("[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}")
    private val ref = Regex("""\[(N[0-9]+)\]""")
    private val spans = Regex("""(`+)([^\n]*?)\1(?!`)|\[([^\]\n]+)\]\(([^\n)]*)\)|\[(N[0-9]+)\]|\*\*([^*]+)\*\*|`""")
    private val forged = Regex("""(?i)weiji-cite://[^\s<>()\]]*""")
    enum class Style { Text, Code, Bold }
    data class Inline(val text: String, val url: String? = null, val style: Style = Style.Text)
    enum class Kind { Paragraph, Heading, Quote, Code, List, Rule }
    data class Block(val kind: Kind, val text: String)

    fun inline(text: String, citations: List<AiCitation> = emptyList()): List<Inline> {
        val allowed = citations.filter { uuid.matches(it.noteId) }
            .groupBy { it.ref }.mapValues { (_, hits) -> hits.first().noteId.lowercase(Locale.ROOT) }
        fun cite(token: String): String? = ref.matchEntire(token)?.groupValues?.get(1)?.let(allowed::get)?.let { CITE + it }
        fun strip(value: String) = value.replace(forged, "")
        return buildList {
            var offset = 0
            for (span in spans.findAll(text)) {
                if (span.range.first > offset) add(Inline(strip(text.substring(offset, span.range.first))))
                offset = span.range.last + 1
                val (_, code, label, url, reference, bold) = span.destructured
                when {
                    span.groups[1] != null -> add(Inline(strip(code), cite(code), Style.Code))
                    label.isNotEmpty() -> add(Inline(strip(label), url.takeIf {
                        it.startsWith("https://", ignoreCase = true) || it.startsWith("http://", ignoreCase = true)
                    }))
                    reference.isNotEmpty() -> {
                        val escaped = span.range.first > 0 && text[span.range.first - 1] == '\\'
                        val link = text.getOrNull(offset) == '(' || text.getOrNull(offset) == '['
                        add(Inline(span.value, if (escaped || link) null else cite(span.value)))
                    }
                    bold.isNotEmpty() -> addAll(inline(bold, citations).map { it.copy(style = Style.Bold) })
                    else -> add(Inline(span.value))
                }
            }
            if (offset < text.length) add(Inline(strip(text.substring(offset))))
        }
    }

    fun blocks(text: String): List<Block> = buildList {
        var fence: String? = null
        val code = mutableListOf<String>()
        val heading = Regex("""^#{1,6}\s+""")
        val list = Regex("""^(?:[-*+] |\d+[.)] )""")
        for (line in text.lineSequence()) {
            val trimmed = line.trimStart()
            val mark = trimmed.takeWhile { it == '`' || it == '~' }
            when {
                fence != null && mark.startsWith(fence) && trimmed.drop(mark.length).isBlank() -> {
                    add(Block(Kind.Code, code.joinToString("\n")))
                    fence = null
                    code.clear()
                }
                fence != null -> code.add(line)
                mark.length >= 3 && mark.all { it == mark.first() } -> fence = mark
                trimmed.isBlank() -> Unit
                heading.containsMatchIn(trimmed) -> add(Block(Kind.Heading, trimmed.replaceFirst(heading, "")))
                trimmed in setOf("---", "***", "___") -> add(Block(Kind.Rule, ""))
                trimmed.startsWith(">") -> add(Block(Kind.Quote, trimmed.drop(1).trimStart()))
                list.containsMatchIn(trimmed) -> add(Block(Kind.List, if (trimmed.first().isDigit()) trimmed else "• " + trimmed.drop(2)))
                else -> add(Block(Kind.Paragraph, line))
            }
        }
        if (fence != null) add(Block(Kind.Code, code.joinToString("\n")))
    }
}
