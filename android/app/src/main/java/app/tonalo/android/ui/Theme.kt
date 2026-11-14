package app.tonalo.android.ui

import android.graphics.Bitmap
import android.util.LruCache
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.palette.graphics.Palette as ColorPalette
import app.tonalo.android.data.Backdrop
import app.tonalo.android.data.CardShape
import androidx.compose.ui.unit.Dp
import app.tonalo.android.tonalo
import coil3.SingletonImageLoader
import coil3.request.ImageRequest
import coil3.request.SuccessResult
import coil3.toBitmap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Same look as the iPhone app: a black (or dark gray) canvas, lifted tiles, an accent color the user picks.
 * The values are Compose state, so every screen follows a change in the settings at once.
 */
object Palette {
    var accent by mutableStateOf(Color(0xFF5B9DFF))
        internal set
    private var lift by mutableStateOf(0.07f)
    private var cornerScale by mutableStateOf(1f)

    /** A corner radius after the "Corners" setting: [base] at Standard, none at Sharp, double at Rounded. */
    fun corner(base: Dp): Dp = base * cornerScale

    /** The page background, and the surfaces on it that keep their distance from it. */
    val canvas: Color get() = gray(0f)
    val surface: Color get() = gray(0.07f)
    /** Grouped cards (settings) and the side menu – a little above the page. */
    val card: Color get() = gray(0.075f)
    val panel: Color get() = gray(0.11f)
    val elevated: Color get() = gray(0.16f)
    val secondaryText = Color(0xFFA7A7A7)
    val subtle = Color(0xFF7A7A7A)

    private fun gray(base: Float): Color { val v = (base + lift).coerceIn(0f, 1f); return Color(v, v, v) }

    internal fun apply(accentHex: String, backdrop: Backdrop, shape: CardShape) {
        accent = parse(accentHex) ?: Color(0xFF5B9DFF)
        lift = if (backdrop == Backdrop.GRAY) 0.07f else 0f
        cornerScale = shape.scale
    }

    fun parse(hex: String): Color? {
        val s = hex.trim().removePrefix("#")
        if (s.length != 6) return null
        return s.toLongOrNull(16)?.let { Color(0xFF000000 or it) }
    }

    /** A pleasant color from a name (genres, mixes) – fixed per name, like the iPhone's hues. */
    /** The avatar's color: one of a few bright colors, fixed per name (same pick as the iPhone). */
    fun avatar(name: String): Color {
        val colors = listOf(accent, Color(0xFFFF9F0A), Color(0xFF30D158), Color(0xFFFF375F), Color(0xFFBF5AF2),
            Color(0xFFFF453A), Color(0xFF64D2FF), Color(0xFFFFD60A), Color(0xFF66D4CF), Color(0xFF5E5CE6))
        var h = 0
        name.lowercase().forEach { h = (h * 31 + it.code) and 0x7fffffff }
        return colors[h % colors.size]
    }

    fun hue(name: String, saturation: Float = 0.62f, value: Float = 0.62f): Color {
        val h = (name.hashCode().toLong() and 0xffffffffL) % 360
        return Color.hsv(h.toFloat(), saturation, value)
    }
}

@Composable
fun TonaloTheme(content: @Composable () -> Unit) {
    val settings = LocalContext.current.tonalo.settings
    val accent by settings.accent.collectAsState()
    val backdrop by settings.backdrop.collectAsState()
    val shape by settings.cardShape.collectAsState()
    // Same values write nothing (structural equality), so this only changes state when a setting changed
    Palette.apply(accent, backdrop, shape)
    val scheme = darkColorScheme(
        primary = Palette.accent,
        onPrimary = Color.Black,
        secondary = Palette.accent,
        background = Palette.canvas,
        onBackground = Color.White,
        surface = Palette.canvas,
        onSurface = Color.White,
        surfaceVariant = Palette.panel,
        onSurfaceVariant = Palette.secondaryText,
        surfaceContainer = Palette.surface,
        surfaceContainerHigh = Palette.panel,
        surfaceContainerHighest = Palette.elevated,
        surfaceContainerLow = Palette.surface,
        surfaceContainerLowest = Palette.canvas,
        secondaryContainer = Palette.accent.copy(alpha = 0.25f),
        onSecondaryContainer = Color.White,
        outline = Color(0xFF555555),
        outlineVariant = Color(0xFF333333),
    )
    MaterialTheme(colorScheme = scheme, content = content)
}

// region Colors from covers

private val coverColors = LruCache<String, Int>(200)

/**
 * The cover's main color, darkened so white text stays readable on it – for the player's background,
 * album pages and the mini player. Null while loading, without a cover, or when switched off in the settings.
 */
@Composable
fun rememberCoverColor(coverArt: String?): Color? {
    val context = LocalContext.current
    val app = context.tonalo
    val enabled by app.settings.coverTint.collectAsState()
    val state = produceState<Color?>(initialValue = coverArt?.let { coverColors.get(it) }?.let { Color(it) }, coverArt, enabled) {
        value = null
        if (!enabled || coverArt.isNullOrEmpty()) { return@produceState }
        coverColors.get(coverArt)?.let { value = Color(it); return@produceState }
        val url = app.client()?.coverURL(coverArt, 120) ?: return@produceState
        val result = SingletonImageLoader.get(context).execute(ImageRequest.Builder(context).data(url).build())
        val bitmap: Bitmap = (result as? SuccessResult)?.image?.toBitmap() ?: return@produceState
        val color = withContext(Dispatchers.Default) { pick(bitmap) }
        coverColors.put(coverArt, color.toArgb())
        value = color
    }
    return if (enabled) state.value else null
}

private fun pick(bitmap: Bitmap): Color {
    val p = ColorPalette.from(bitmap).maximumColorCount(16).generate()
    val swatch = p.vibrantSwatch ?: p.darkVibrantSwatch ?: p.dominantSwatch ?: p.mutedSwatch
    val hsv = FloatArray(3)
    android.graphics.Color.colorToHSV(swatch?.rgb ?: 0xFF404040.toInt(), hsv)
    // Dark enough for white text, but still clearly the cover's color
    hsv[1] = hsv[1].coerceIn(0.25f, 0.75f)
    hsv[2] = hsv[2].coerceIn(0.32f, 0.5f)
    return Color(android.graphics.Color.HSVToColor(hsv))
}

// endregion
