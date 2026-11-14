package app.tonalo.android.ui

import android.net.Uri
import android.util.LruCache
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.FormatListBulleted
import androidx.compose.material.icons.filled.Album
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.palette.graphics.Palette as ColorPalette
import app.tonalo.android.R
import app.tonalo.android.playback.BookPlayer
import app.tonalo.android.tonalo
import coil3.SingletonImageLoader
import coil3.compose.SubcomposeAsyncImage
import coil3.request.ImageRequest
import coil3.request.SuccessResult
import coil3.toBitmap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.text.DateFormat
import java.text.DecimalFormat
import java.util.Date
import kotlin.math.cos
import kotlin.math.sin

// region Shared helpers (also used by BookMiniBar and BookPlaybackSettings)

/** "1×", "1.25×", "0.8×" – like the iPhone. */
internal fun bplRateText(rate: Float): String = (if (rate == 1f) "1" else DecimalFormat("0.##").format(rate)) + "×"

/** 1:02:03 or 2:03. */
internal fun bplClock(seconds: Double): String {
    val s = seconds.coerceAtLeast(0.0).toLong()
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s % 3600 / 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
}

/** "3 h 20 min" or "45 min". */
@Composable
private fun bplLength(seconds: Double): String {
    val minutes = (seconds.coerceAtLeast(0.0) / 60).toLong()
    return if (minutes >= 60) stringResource(R.string.bpl_hours_minutes, minutes / 60, minutes % 60) else stringResource(R.string.bpl_minutes, minutes)
}

/** An audiobook cover from the Audiobookshelf server (square crop, like the iPhone's BookCover). */
@Composable
internal fun BplCover(itemId: String?, size: Dp, corner: Dp = 4.dp, pixels: Int = 300, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val url = remember(itemId, pixels) { itemId?.let { context.tonalo.books.coverURL(it, pixels) } }
    val fallback = @Composable {
        Box(Modifier.fillMaxSize().background(Palette.elevated), contentAlignment = Alignment.Center) {
            Icon(Icons.Default.Album, null, tint = Palette.secondaryText, modifier = Modifier.size(size / 2.5f))
        }
    }
    Box(modifier.size(size).clip(RoundedCornerShape(corner))) {
        if (url == null) fallback() else SubcomposeAsyncImage(
            model = url, contentDescription = null, contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize(), loading = { fallback() }, error = { fallback() },
        )
    }
}

private val bplColors = LruCache<String, Int>(100)

/** The cover's main color, dark enough for white text (same pick as the music player). Null while loading or switched off. */
@Composable
internal fun rememberBookCoverColor(itemId: String?): Color? {
    val context = LocalContext.current
    val app = context.tonalo
    val enabled by app.settings.coverTint.collectAsState()
    val state = produceState<Color?>(initialValue = itemId?.let { bplColors.get(it) }?.let { Color(it) }, itemId, enabled) {
        value = null
        if (!enabled || itemId == null) return@produceState
        bplColors.get(itemId)?.let { value = Color(it); return@produceState }
        val url = app.books.coverURL(itemId, 120) ?: return@produceState
        val result = SingletonImageLoader.get(context).execute(ImageRequest.Builder(context).data(url).build())
        val bitmap = (result as? SuccessResult)?.image?.toBitmap() ?: return@produceState
        val color = withContext(Dispatchers.Default) {
            val p = ColorPalette.from(bitmap).maximumColorCount(16).generate()
            val swatch = p.vibrantSwatch ?: p.darkVibrantSwatch ?: p.dominantSwatch ?: p.mutedSwatch
            val hsv = FloatArray(3)
            android.graphics.Color.colorToHSV(swatch?.rgb ?: 0xFF404040.toInt(), hsv)
            hsv[1] = hsv[1].coerceIn(0.25f, 0.75f)
            hsv[2] = hsv[2].coerceIn(0.32f, 0.5f)
            Color(android.graphics.Color.HSVToColor(hsv))
        }
        bplColors.put(itemId, color.toArgb())
        value = color
    }
    return if (enabled) state.value else null
}

/** The "gobackward.15" / "goforward.30" symbol: a circular arrow with the seconds inside, drawn here. */
@Composable
internal fun BplSkipIcon(forward: Boolean, seconds: Int, size: Dp, color: Color = Color.White) {
    val density = LocalDensity.current
    val fontSize = with(density) { (size.toPx() * if (seconds >= 100) 0.28f else 0.34f).toSp() }
    Box(Modifier.size(size), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(size)) {
            val stroke = this.size.minDimension * 0.075f
            val inset = stroke * 1.6f
            val r = (this.size.minDimension - 2 * inset) / 2
            val c = Offset(this.size.width / 2, this.size.height / 2 + this.size.minDimension * 0.02f)
            // The arc has a gap at the top; the arrow tip sits at one end of it and points away from the arc
            val tipAngle = if (forward) -80.0 else -100.0
            drawArc(
                color, startAngle = if (forward) (tipAngle - 300).toFloat() else tipAngle.toFloat(), sweepAngle = 300f, useCenter = false,
                topLeft = Offset(c.x - r, c.y - r), size = Size(2 * r, 2 * r), style = Stroke(stroke, cap = StrokeCap.Round),
            )
            val rad = Math.toRadians(tipAngle)
            val tip = Offset(c.x + r * cos(rad).toFloat(), c.y + r * sin(rad).toFloat())
            // Direction of travel at the tip: clockwise for forward, counterclockwise for back
            val dir = if (forward) Offset(-sin(rad).toFloat(), cos(rad).toFloat()) else Offset(sin(rad).toFloat(), -cos(rad).toFloat())
            val len = this.size.minDimension * 0.2f
            for (turn in listOf(40.0, -40.0)) {
                val a = Math.toRadians(turn)
                val bx = -dir.x; val by = -dir.y
                val rx = (bx * cos(a) - by * sin(a)).toFloat(); val ry = (bx * sin(a) + by * cos(a)).toFloat()
                drawLine(color, tip, Offset(tip.x + rx * len, tip.y + ry * len), strokeWidth = stroke, cap = StrokeCap.Round)
            }
        }
        Text(seconds.toString(), color = color, fontSize = fontSize, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = size * 0.04f))
    }
}

// endregion

/**
 * The audiobook / podcast player, full screen: cover on the cover's color, chapter, seek bar over the current chapter,
 * skip buttons with the chosen seconds, speed, sleep timer and the chapter list.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BookPlayerScreen(onClose: () -> Unit) {
    val nav = LocalNav.current
    val state by BookPlayer.state.collectAsState()
    var sleepDialog by remember { mutableStateOf(false) }
    var chapterSheet by remember { mutableStateOf(false) }
    var speedMenu by remember { mutableStateOf(false) }
    // Finished or stopped: nothing left to show
    LaunchedEffect(state.active) { if (!state.active) onClose() }
    val item = state.item
    if (!state.active || item == null) return

    val chapter = state.chapters.getOrNull(state.chapterIndex)
    val title = state.episode?.title ?: item.title
    val start = chapter?.start ?: 0.0
    val end = chapter?.end ?: state.durationSec
    val span = (end - start).coerceAtLeast(1.0)

    var dragging by remember { mutableStateOf(false) }
    var dragValue by remember { mutableFloatStateOf(0f) }
    val fraction = ((state.positionSec - start) / span).toFloat().coerceIn(0f, 1f)
    val shownFraction = if (dragging) dragValue else fraction
    val shown = start + span * shownFraction

    val tint = rememberBookCoverColor(item.id) ?: Palette.elevated
    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(tint, tint.darken(0.45f), Palette.canvas)))) {
        Column(Modifier.fillMaxSize().systemBarsPadding().padding(horizontal = 24.dp)) {
            // Header: close, the book's title, stop
            Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onClose) { Icon(Icons.Default.KeyboardArrowDown, stringResource(R.string.cd_close), Modifier.size(32.dp)) }
                Text(item.title, Modifier.weight(1f), textAlign = TextAlign.Center, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold)
                IconButton(onClick = { BookPlayer.stop(); onClose() }) { Icon(Icons.Default.Close, stringResource(R.string.bpl_stop)) }
            }

            // Cover
            BoxWithConstraints(Modifier.weight(1f).fillMaxWidth().padding(vertical = 24.dp), contentAlignment = Alignment.Center) {
                val side = minOf(maxWidth, maxHeight, 330.dp)
                Box(Modifier.shadow(24.dp, RoundedCornerShape(8.dp))) { BplCover(item.id, side, corner = 8.dp, pixels = 600) }
            }

            // Chapter (or title), book (or author), where it plays
            val authorId = item.media.metadata.authors?.firstOrNull()?.id
            Column(Modifier.fillMaxWidth()) {
                Text(chapter?.title?.ifBlank { null } ?: title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(
                    if (chapter != null) title else item.creator, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    color = Color.White.copy(alpha = 0.7f), style = MaterialTheme.typography.bodyLarge,
                    modifier = if (chapter == null && authorId != null) Modifier.clickable { onClose(); nav.open("bookauthor/" + Uri.encode(authorId)) } else Modifier,
                )
                if (chapter != null && item.creator.isNotEmpty()) Text(
                    item.creator, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    color = Color.White.copy(alpha = 0.7f), style = MaterialTheme.typography.bodySmall,
                    modifier = if (authorId != null) Modifier.clickable { onClose(); nav.open("bookauthor/" + Uri.encode(authorId)) } else Modifier,
                )
                state.tvName?.let {
                    Row(Modifier.padding(top = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.Tv, null, Modifier.size(16.dp), tint = Palette.accent)
                        Text(stringResource(R.string.playing_on, it), Modifier.padding(start = 6.dp), color = Palette.accent,
                            style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }

            Spacer(Modifier.height(8.dp))
            // Seek bar over the chapter (a bar over 20 hours can't be moved with a finger)
            val colors = SliderDefaults.colors(
                thumbColor = Color.White, activeTrackColor = Color.White, inactiveTrackColor = Color.White.copy(alpha = 0.25f),
                disabledThumbColor = Color.White, disabledActiveTrackColor = Color.White.copy(alpha = 0.6f),
                disabledInactiveTrackColor = Color.White.copy(alpha = 0.25f),
            )
            Slider(
                value = shownFraction,
                onValueChange = { dragging = true; dragValue = it },
                onValueChangeFinished = { BookPlayer.seekTo(start + span * dragValue); dragging = false },
                enabled = state.durationSec > 0,
                colors = colors,
                thumb = { Box(Modifier.size(if (dragging) 16.dp else 12.dp).clip(CircleShape).background(Color.White)) },
                track = { st ->
                    SliderDefaults.Track(
                        sliderState = st, modifier = Modifier.height(4.dp), colors = colors, enabled = true,
                        drawStopIndicator = null, thumbTrackGapSize = 0.dp,
                    )
                },
            )
            Row(Modifier.fillMaxWidth()) {
                val small = MaterialTheme.typography.labelSmall
                val dim = Color.White.copy(alpha = 0.7f)
                Text(bplClock(shown - start), style = small, color = dim)
                Spacer(Modifier.weight(1f))
                if (state.durationSec > 0) Text(stringResource(R.string.bpl_left, bplLength(state.durationSec - shown)), style = small, color = dim)
                Spacer(Modifier.weight(1f))
                Text("-" + bplClock(end - shown), style = small, color = dim)
            }

            // Transport
            Row(
                Modifier.fillMaxWidth().padding(vertical = 12.dp),
                horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = { BookPlayer.previousChapter() }, enabled = state.chapters.isNotEmpty()) {
                    Icon(Icons.Default.SkipPrevious, stringResource(R.string.bpl_prev_chapter), Modifier.size(32.dp))
                }
                IconButton(onClick = { BookPlayer.skip(-state.skipBack) }, Modifier.size(56.dp)) {
                    Box(Modifier.size(44.dp)) { BplSkipIcon(false, state.skipBack, 44.dp) }
                }
                Box(
                    Modifier.size(72.dp).clip(CircleShape).background(Color.White).clickable { BookPlayer.toggle() },
                    contentAlignment = Alignment.Center,
                ) {
                    if (state.loading) CircularProgressIndicator(Modifier.size(30.dp), color = Color.Black, strokeWidth = 3.dp)
                    else Icon(
                        if (state.playing) Icons.Default.Pause else Icons.Default.PlayArrow,
                        stringResource(if (state.playing) R.string.cd_pause else R.string.cd_play),
                        Modifier.size(36.dp), tint = Color.Black,
                    )
                }
                IconButton(onClick = { BookPlayer.skip(state.skipForward) }, Modifier.size(56.dp)) {
                    Box(Modifier.size(44.dp)) { BplSkipIcon(true, state.skipForward, 44.dp) }
                }
                IconButton(onClick = { BookPlayer.nextChapter() }, enabled = state.chapters.isNotEmpty()) {
                    Icon(Icons.Default.SkipNext, stringResource(R.string.bpl_next_chapter), Modifier.size(32.dp))
                }
            }

            state.error?.let {
                Text(it, Modifier.fillMaxWidth(), color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center, style = MaterialTheme.typography.bodySmall)
            }

            // Speed · sleep timer · chapters
            val sleeping = state.sleepEndsAt != null || state.sleepAtChapterEnd
            Row(Modifier.fillMaxWidth().padding(bottom = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Box {
                    TextButton(onClick = { speedMenu = true }, Modifier.widthIn(min = 52.dp)) {
                        Text(bplRateText(state.rate), color = Color.White, fontWeight = FontWeight.SemiBold, style = MaterialTheme.typography.bodyLarge)
                    }
                    DropdownMenu(expanded = speedMenu, onDismissRequest = { speedMenu = false }, modifier = Modifier.background(Palette.elevated)) {
                        BookPlayer.rates.forEach { r ->
                            DropdownMenuItem(
                                text = { Text(bplRateText(r)) },
                                leadingIcon = { if (r == state.rate) Icon(Icons.Default.Check, null, tint = Palette.accent) else Spacer(Modifier.size(24.dp)) },
                                onClick = { BookPlayer.setRate(r); speedMenu = false },
                            )
                        }
                    }
                }
                Spacer(Modifier.weight(1f))
                IconButton(onClick = { sleepDialog = true }) {
                    Icon(Icons.Default.Bedtime, stringResource(R.string.sleep_timer), tint = if (sleeping) Palette.accent else Color.White)
                }
                if (sleeping) Text(
                    if (state.sleepAtChapterEnd) stringResource(R.string.bpl_sleep_active_chapter)
                    else stringResource(R.string.sleep_active, DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(state.sleepEndsAt ?: 0L))),
                    Modifier.clickable { sleepDialog = true }, style = MaterialTheme.typography.labelMedium, color = Palette.accent,
                )
                Spacer(Modifier.weight(1f))
                IconButton(onClick = { chapterSheet = true }, enabled = state.chapters.isNotEmpty()) {
                    Icon(Icons.AutoMirrored.Filled.FormatListBulleted, stringResource(R.string.bpl_chapters))
                }
            }
        }
    }

    if (sleepDialog) BookSleepDialog(state.sleepEndsAt != null || state.sleepAtChapterEnd, state.chapters.isNotEmpty()) { sleepDialog = false }
    if (chapterSheet) ModalBottomSheet(onDismissRequest = { chapterSheet = false }, containerColor = Palette.panel) {
        val list = rememberLazyListState()
        LaunchedEffect(Unit) { if (state.chapterIndex > 0) list.scrollToItem((state.chapterIndex - 2).coerceAtLeast(0)) }
        Text(stringResource(R.string.bpl_chapters), Modifier.padding(horizontal = 24.dp, vertical = 8.dp), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
        LazyColumn(Modifier.navigationBarsPadding(), state = list) {
            itemsIndexed(state.chapters, key = { i, c -> "$i-${c.start}" }) { i, c ->
                BplChapterRow(c.title.orEmpty(), c.end - c.start, i == state.chapterIndex) { BookPlayer.seekTo(c.start); chapterSheet = false }
            }
        }
    }
}

@Composable
private fun BplChapterRow(title: String, length: Double, current: Boolean, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 24.dp, vertical = 11.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f), color = if (current) Palette.accent else Color.White, fontWeight = if (current) FontWeight.SemiBold else FontWeight.Normal,
            maxLines = 2, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyLarge)
        Text(bplClock(length), Modifier.padding(start = 8.dp), color = Palette.subtle, style = MaterialTheme.typography.bodyMedium)
    }
}

@Composable
private fun BookSleepDialog(active: Boolean, hasChapters: Boolean, onDone: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDone,
        title = { Text(stringResource(R.string.sleep_timer)) },
        text = {
            Column {
                if (hasChapters) Text(stringResource(R.string.bpl_sleep_chapter), Modifier.fillMaxWidth().clickable { BookPlayer.setSleepAtChapterEnd(true); onDone() }.padding(vertical = 12.dp))
                listOf(15, 30, 45, 60).forEach { m ->
                    Text(stringResource(R.string.sleep_minutes, m), Modifier.fillMaxWidth().clickable { BookPlayer.setSleepMinutes(m); onDone() }.padding(vertical = 12.dp))
                }
            }
        },
        confirmButton = {
            if (active) TextButton(onClick = { BookPlayer.setSleepMinutes(null); BookPlayer.setSleepAtChapterEnd(false); onDone() }) { Text(stringResource(R.string.sleep_off)) }
        },
        dismissButton = { TextButton(onClick = onDone) { Text(stringResource(R.string.cancel)) } },
    )
}
