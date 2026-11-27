package xyz.weiji.notes.core.text

import java.util.Locale

object TagParser {
    private val tag = Regex("""(?<![\p{L}\p{N}_/])#([\p{L}\p{N}_-]+(?:/[\p{L}\p{N}_-]+)*)""")
    private val active = Regex("""(?<![\p{L}\p{N}_/])#([\p{L}\p{N}_/-]*)\z""")
    private val numeric = Regex("""\p{N}+(?:/\p{N}+)*""")
    data class Query(val start: Int, val end: Int, val text: String)
    data class Node(val path: String, val count: Int, val children: List<Node>) {
        val name get() = path.substringAfterLast('/')
    }

    fun tags(text: String) = tag.findAll(text).map { it.groupValues[1].lowercase(Locale.ROOT) }
        .filterNot(numeric::matches).distinct().toList()

    fun counts(bodies: List<String>): Map<String, Int> = bodies
        .flatMap { body -> tags(body).flatMap(::paths).distinct() }.groupingBy { it }.eachCount()

    private fun paths(tag: String): List<String> =
        tag.indices.filter { tag[it] == '/' }.map { tag.substring(0, it) } + tag

    fun tree(counts: Map<String, Int>): List<Node> {
        val byParent = counts.keys.groupBy { it.substringBeforeLast('/', "") }
        fun children(path: String): List<Node> = byParent[path].orEmpty().sorted().map {
            Node(it, counts.getValue(it), children(it))
        }
        return children("")
    }

    fun query(text: String, cursor: Int = text.length): Query? = active.find(text.take(cursor))?.let {
        Query(it.range.first, cursor, it.groupValues[1].lowercase(Locale.ROOT))
    }

    fun suggest(query: String, counts: Map<String, Int>, limit: Int = 8): List<String> {
        fun tier(tag: String) = when {
            tag == query -> 0
            tag.startsWith(query) -> 1
            tag.split('/').any { it.startsWith(query) } -> 2
            query in tag -> 3
            else -> 4
        }
        return counts.keys.filter { tier(it) < 4 }.sortedWith(
            compareBy<String>(::tier).thenByDescending { counts.getValue(it) }
                .thenBy { if (query.isEmpty()) 0 else it.length }.thenBy { it }
        ).take(limit)
    }
}
