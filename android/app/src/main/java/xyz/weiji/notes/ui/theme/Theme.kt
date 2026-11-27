package xyz.weiji.notes.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.Color

data class PaperColors(val canvas: Color, val paper: Color, val subtle: Color, val ink: Color, val ink2: Color, val ink3: Color, val line: Color)
data class AccentColors(val active: Color, val accent: Color, val accentSoft: Color, val tone: Color)
data class WeijiColors(val paper: PaperColors, val accent: AccentColors) {
    val primaryContent: Color get() = Color.White
}

enum class WeijiTheme(val label: String, val light: AccentColors, val dark: AccentColors) {
    Pine("松绿", accents(0x2D6A4F, 0x2D6A4F, 0xE7F1EC, 0x3A8363), accents(0x7AD4AA, 0x276E50, 0x1C3127, 0x5CC295)),
    Indigo("靛蓝", accents(0x2553A6, 0x2553A6, 0xE9EFFB, 0x3669C4), accents(0x85B0FF, 0x2F62BF, 0x1A2844, 0x6E9EF5)),
    Clay("陶土", accents(0x9E4B28, 0x9E4B28, 0xF6EAE4, 0xBA5F38), accents(0xF0A07B, 0xA6502C, 0x352119, 0xE08A64)),
    Plum("梅紫", accents(0x6A4A96, 0x6A4A96, 0xEFEAF7, 0x7F5CAE), accents(0xC7ADF2, 0x7755A8, 0x292038, 0xB394E6)),
    Graphite("石墨", accents(0x363430, 0x363430, 0xEAE8E1, 0x52504A), accents(0xDCD9D0, 0x57544D, 0x2E2D29, 0xB5B1A6)),
}

private fun color(rgb: Long) = Color(0xFF000000 or rgb)
private fun accents(active: Long, accent: Long, soft: Long, tone: Long) =
    AccentColors(color(active), color(accent), color(soft), color(tone))

private val lightPaper = PaperColors(color(0xF6F5F0), color(0xFFFFFF), color(0xEEECE5), color(0x1C1B18), color(0x55524A), color(0x6F6B63), color(0xE6E3DA))
private val darkPaper = PaperColors(color(0x171614), color(0x22211E), color(0x2B2A26), color(0xEDEBE5), color(0xB5B0A6), color(0x8F8A80), color(0x3A3833))
fun weijiColors(theme: WeijiTheme, dark: Boolean) = WeijiColors(
    if (dark) darkPaper else lightPaper, if (dark) theme.dark else theme.light,
)
val LocalWeijiColors = staticCompositionLocalOf { weijiColors(WeijiTheme.Pine, false) }

@Composable fun WeijiMaterialTheme(theme: String, mode: String, content: @Composable () -> Unit) {
    val dark = when (mode) { "dark" -> true; "light" -> false; else -> isSystemInDarkTheme() }
    val colors = weijiColors(WeijiTheme.entries.firstOrNull { it.name.equals(theme, ignoreCase = true) } ?: WeijiTheme.Pine, dark)
    val (paper, accent) = colors
    val base = if (dark) darkColorScheme() else lightColorScheme()
    val scheme = base.copy(
        primary = accent.active, onPrimary = paper.canvas, primaryContainer = accent.accentSoft, onPrimaryContainer = accent.active,
        secondary = accent.active, onSecondary = paper.canvas, secondaryContainer = accent.accentSoft, onSecondaryContainer = accent.active,
        background = paper.canvas, onBackground = paper.ink, surface = paper.paper, onSurface = paper.ink,
        surfaceVariant = paper.subtle, onSurfaceVariant = paper.ink2, outline = paper.ink3, outlineVariant = paper.line,
        surfaceContainer = paper.paper, surfaceContainerHigh = paper.paper, surfaceContainerHighest = paper.subtle,
        surfaceContainerLow = paper.canvas, surfaceContainerLowest = paper.canvas, surfaceTint = Color.Transparent,
    )
    CompositionLocalProvider(LocalWeijiColors provides colors) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}
