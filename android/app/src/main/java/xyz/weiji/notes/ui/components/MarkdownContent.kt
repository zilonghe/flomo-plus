package xyz.weiji.notes.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.*
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import xyz.weiji.notes.core.text.MarkdownParser
import xyz.weiji.notes.model.AiCitation
import xyz.weiji.notes.ui.theme.LocalWeijiColors

fun primaryButtonColors(theme: xyz.weiji.notes.ui.theme.WeijiColors, defaults: ButtonColors): ButtonColors =
    defaults.copy(containerColor = theme.accent.accent, contentColor = theme.primaryContent)

@Composable fun WeijiPrimaryButton(label: String, click: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    Button(
        onClick = click,
        modifier = modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp),
        enabled = enabled,
        colors = primaryButtonColors(LocalWeijiColors.current, ButtonDefaults.buttonColors()),
    ) { Text(label) }
}

@Composable fun Action(label: String, click: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    TextButton(click, modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp), enabled = enabled) { Text(label) }
}

@Composable fun MarkdownContent(
    value: String, citations: List<AiCitation> = emptyList(), onCitation: (String) -> Unit = {},
) {
    val colors = LocalWeijiColors.current
    val uriHandler = LocalUriHandler.current
    val density = LocalDensity.current
    val measurer = rememberTextMeasurer()
    val labelStyle = MaterialTheme.typography.labelLarge
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        for (block in MarkdownParser.blocks(value)) {
            when (block.kind) {
                MarkdownParser.Kind.Rule -> HorizontalDivider()
                MarkdownParser.Kind.Code -> Text(
                    block.text, Modifier.fillMaxWidth().background(colors.paper.subtle, RoundedCornerShape(8.dp)).padding(10.dp),
                    fontFamily = FontFamily.Monospace,
                )
                else -> {
                    val style = if (block.kind == MarkdownParser.Kind.Heading) MaterialTheme.typography.titleLarge
                        else MaterialTheme.typography.bodyLarge
                    val inlineContent = mutableMapOf<String, InlineTextContent>()
                    val text = buildAnnotatedString {
                        for ((index, part) in MarkdownParser.inline(block.text, citations).withIndex()) {
                            val span = when (part.style) {
                                MarkdownParser.Style.Code -> SpanStyle(fontFamily = FontFamily.Monospace)
                                MarkdownParser.Style.Bold -> SpanStyle(fontWeight = FontWeight.Bold)
                                else -> SpanStyle()
                            }
                            val url = part.url
                            withStyle(span) {
                                if (url?.startsWith("weiji-cite://") == true) {
                                    val key = "citation-$index"
                                    val width = with(density) {
                                        (measurer.measure(part.text, labelStyle, maxLines = 1).size.width.toDp() + 12.dp)
                                            .coerceAtLeast(48.dp).toSp()
                                    }
                                    val height = with(density) { 20.sp.toDp().coerceAtLeast(48.dp).toSp() }
                                    inlineContent[key] = InlineTextContent(Placeholder(width, height, PlaceholderVerticalAlign.Center)) {
                                        Surface(
                                            onClick = { onCitation(url.removePrefix("weiji-cite://")) },
                                            modifier = Modifier.fillMaxSize(),
                                            shape = MaterialTheme.shapes.small,
                                            color = colors.accent.accentSoft,
                                            contentColor = colors.accent.active,
                                        ) {
                                            Box(contentAlignment = Alignment.Center) { Text(part.text, style = labelStyle, maxLines = 1) }
                                        }
                                    }
                                    appendInlineContent(key, part.text)
                                } else if (url != null) {
                                    withLink(LinkAnnotation.Url(
                                        url, TextLinkStyles(style = SpanStyle(color = colors.accent.active, fontWeight = FontWeight.SemiBold)),
                                    ) { runCatching { uriHandler.openUri(url) } }) { append(part.text) }
                                } else append(part.text)
                            }
                        }
                    }
                    val modifier = if (block.kind == MarkdownParser.Kind.Quote)
                        Modifier.background(colors.paper.subtle, RoundedCornerShape(6.dp)).padding(10.dp) else Modifier
                    Text(text, modifier, style = style, inlineContent = inlineContent)
                }
            }
        }
    }
}

@Composable fun ErrorText(message: String?) {
    if (message != null) Text(message, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
}
