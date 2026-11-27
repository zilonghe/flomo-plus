package xyz.weiji.notes

import androidx.compose.material3.ButtonColors
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.toArgb
import kotlin.math.max
import kotlin.math.min
import org.junit.Assert.*
import org.junit.Test
import org.robolectric.annotation.Config
import xyz.weiji.notes.ui.components.primaryButtonColors
import xyz.weiji.notes.ui.theme.WeijiTheme
import xyz.weiji.notes.ui.theme.weijiColors

@Config(sdk = [34])
class WeijiThemeContrastTest {
    private val paper = listOf(
        "F6F5F0 FFFFFF EEECE5 1C1B18 55524A 6F6B63 E6E3DA",
        "171614 22211E 2B2A26 EDEBE5 B5B0A6 8F8A80 3A3833",
    )
    private val accents = listOf(
        "2D6A4F 2D6A4F E7F1EC 3A8363 7AD4AA 276E50 1C3127 5CC295",
        "2553A6 2553A6 E9EFFB 3669C4 85B0FF 2F62BF 1A2844 6E9EF5",
        "9E4B28 9E4B28 F6EAE4 BA5F38 F0A07B A6502C 352119 E08A64",
        "6A4A96 6A4A96 EFEAF7 7F5CAE C7ADF2 7755A8 292038 B394E6",
        "363430 363430 EAE8E1 52504A DCD9D0 57544D 2E2D29 B5B1A6",
    )
    private val modes = listOf(false, true)
    private fun hex(colors: List<Color>) = colors.joinToString(" ") { "%06X".format(it.toArgb() and 0xFFFFFF) }
    private fun contrast(a: Color, b: Color): Float {
        val (x, y) = a.luminance() to b.luminance()
        return (max(x, y) + 0.05f) / (min(x, y) + 0.05f)
    }

    @Test fun exactPaperAndAccentTokensMatchIos() {
        WeijiTheme.entries.forEachIndexed { index, theme ->
            modes.forEachIndexed { mode, dark ->
                val (p, a) = weijiColors(theme, dark)
                assertEquals(paper[mode], hex(listOf(p.canvas, p.paper, p.subtle, p.ink, p.ink2, p.ink3, p.line)))
                assertEquals(accents[index].split(' ').drop(mode * 4).take(4).joinToString(" "),
                    hex(listOf(a.active, a.accent, a.accentSoft, a.tone)))
            }
        }
    }

    @Test fun whitePrimaryTextPassesAaOnAllTenAccentFills() {
        for (theme in WeijiTheme.entries) for (dark in modes) {
            val colors = weijiColors(theme, dark)
            val cta = primaryButtonColors(colors, ButtonColors(Color.Black, Color.Red, Color.Gray, Color.Gray))
            assertEquals(Color.White, cta.contentColor)
            assertEquals(colors.accent.accent, cta.containerColor)
            assertTrue("$theme $dark contrast", contrast(cta.contentColor, cta.containerColor) >= 4.5f)
        }
    }

    @Test fun activeContentPassesAaOnThirtySurfaces() {
        for (theme in WeijiTheme.entries) for (dark in modes) {
            val (p, a) = weijiColors(theme, dark)
            for (background in listOf(p.canvas, p.paper, a.accentSoft)) {
                assertTrue("$theme $dark on $background", contrast(a.active, background) >= 4.5f)
            }
        }
    }
}
