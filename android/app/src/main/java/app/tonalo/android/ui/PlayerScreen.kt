package app.tonalo.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.FormatQuote
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Repeat
import androidx.compose.material.icons.rounded.RepeatOne
import androidx.compose.material.icons.rounded.Shuffle
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.automirrored.filled.FormatListBulleted
import androidx.compose.material.icons.automirrored.filled.PlaylistAdd
import androidx.compose.material.icons.filled.Album
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.FormatQuote
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Radio
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.RepeatOne
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.EaseOut
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Paint
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.semantics.Role
import app.tonalo.android.playback.SleepTimer
import kotlinx.coroutines.CoroutineScope
import androidx.media3.common.Player
import app.tonalo.android.R
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import app.tonalo.android.data.Lyrics
import app.tonalo.android.data.formatTime
import app.tonalo.android.downloads.Downloads
import app.tonalo.android.dj.DJ
import app.tonalo.android.link.TvLink
import kotlinx.coroutines.launch
import app.tonalo.android.playback.Playback
import app.tonalo.android.tonalo
import kotlinx.coroutines.delay
import java.text.DateFormat
import java.util.Date

/**
 * The player's background, like the iPhone: black, the cover's tint over it, then a gradient from clear to
 * black (65 %) towards the bottom. A change of tint fades in half a second; the old color stays until the new one is known.
 */
@Composable
private fun PlayerBackground(coverArt: String?, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val target = rememberCoverColor(coverArt) ?: Color(0.22f, 0.22f, 0.22f)
    val tint by animateColorAsState(target, tween(500, easing = EaseOut), label = "playerTint")
    Box(
        modifier.fillMaxSize()
            .background(Color.Black)
            .background(tint)
            .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.65f))))
    ) { content() }
}

/** A button without press highlight (the iPhone has none); still a button for screen readers and dimmed when disabled. */
@Composable
private fun PlainButton(onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true, content: @Composable () -> Unit) {
    Box(
        modifier.alpha(if (enabled) 1f else 0.38f).clickable(
            interactionSource = remember { MutableInteractionSource() }, indication = null,
            enabled = enabled, role = Role.Button, onClick = onClick,
        ),
        contentAlignment = Alignment.Center,
    ) { content() }
}

/** Shuffle / repeat: the icon with a small dot below it while on, in the accent color. */
@Composable
private fun ToggleIcon(icon: ImageVector, description: String, on: Boolean) {
    val tint = if (on) Palette.accent else Color.White
    Column(Modifier.offset(y = 3.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(icon, description, Modifier.size(27.dp), tint = tint)
        Spacer(Modifier.height(3.dp))
        Box(Modifier.size(4.dp).alpha(if (on) 1f else 0f).background(tint, CircleShape))
    }
}

/** Soft shadow under the cover: black 40 %, blur 20, 10 down (like the iPhone). */
private fun Modifier.coverShadow(): Modifier =
    if (android.os.Build.VERSION.SDK_INT >= 28) drawBehind {
        val r = 8.dp.toPx()
        drawIntoCanvas { canvas ->
            val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)
            paint.color = android.graphics.Color.BLACK
            paint.setShadowLayer(20.dp.toPx(), 0f, 10.dp.toPx(), Color.Black.copy(alpha = 0.4f).toArgb())
            canvas.nativeCanvas.drawRoundRect(0f, 0f, size.width, size.height, r, r, paint)
        }
    } else shadow(14.dp, RoundedCornerShape(8.dp), clip = false, ambientColor = Color.Black.copy(alpha = 0.4f), spotColor = Color.Black.copy(alpha = 0.4f))

/** The player following the finger while it is pulled down; closes past a quarter of the height or when flicked. */
private class DismissDrag(private val scope: CoroutineScope) {
    var offset by mutableFloatStateOf(0f)
    var height = 1f
    var closing = false
    var onClose: () -> Unit = {}

    fun end(translationY: Float, speed: Float) {
        if (closing) return
        if (offset > 0f && (translationY > height * 0.25f || speed > 700f)) {
            // Keep moving at the finger's speed until it is off screen, then close
            closing = true
            val seconds = minOf(0.35f, maxOf(0.15f, (height - offset) / maxOf(speed, 1800f)))
            scope.launch {
                Animatable(offset).animateTo(height, tween((seconds * 1000).toInt(), easing = EaseOut)) { offset = value }
                onClose()
            }
        } else springBack(speed)
    }

    fun springBack(speed: Float = 0f) {
        if (closing) return
        scope.launch {
            Animatable(offset).animateTo(0f, spring(dampingRatio = 0.87f, stiffness = 300f), initialVelocity = speed.coerceIn(-3000f, 3000f)) {
                offset = value.coerceAtLeast(0f)
            }
        }
    }
}

/**
 * Pull down to close; on the cover (`skips`) a sideways swipe of more than 60 dp skips songs instead.
 * Starts after 10 dp; the direction is decided by the first move, like on the iPhone.
 */
private fun Modifier.dismissDrag(drag: DismissDrag, skips: Boolean, onNext: () -> Unit = {}, onPrevious: () -> Unit = {}): Modifier {
    return pointerInput(skips) {
        val minDistance = 10.dp.toPx()
        val skipDistance = 60.dp.toPx()
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false)
            if (drag.closing) return@awaitEachGesture
            val tracker = VelocityTracker()
            tracker.addPosition(down.uptimeMillis, down.position)
            var dx = 0f
            var dy = 0f
            var axis = 0 // 0 undecided, 1 vertical, 2 horizontal
            var released = false
            while (true) {
                val event = awaitPointerEvent()
                val change = event.changes.firstOrNull { it.id == down.id } ?: break
                if (axis == 0 && change.isConsumed) break
                tracker.addPosition(change.uptimeMillis, change.position)
                val delta = change.position - change.previousPosition
                dx += delta.x
                dy += delta.y
                if (axis == 0 && kotlin.math.hypot(dx, dy) >= minDistance) {
                    axis = if (skips && kotlin.math.abs(dx) > kotlin.math.abs(dy)) 2 else 1
                }
                if (axis == 1) drag.offset = maxOf(0f, dy)
                if (axis != 0) change.consume()
                if (!change.pressed) { released = true; break }
            }
            when (axis) {
                1 -> if (released) drag.end(dy, tracker.calculateVelocity().y) else drag.springBack()
                2 -> if (released) { if (dx < -skipDistance) onNext() else if (dx > skipDistance) onPrevious() }
            }
        }
    }
}

/** The moon with "zz" of the iPhone's sleep timer button, drawn here. */
private fun moonZzz(filled: Boolean): ImageVector =
    ImageVector.Builder(if (filled) "PlayerMoonZzzFilled" else "PlayerMoonZzz", 24.dp, 24.dp, 24f, 24f)
        .path(
            fill = if (filled) SolidColor(Color.Black) else null, stroke = SolidColor(Color.Black), strokeLineWidth = 1.8f,
            strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round,
        ) {
            moveTo(18.3f, 17.2f)
            arcTo(7.2f, 7.2f, 0f, true, true, 10.5f, 9.4f)
            arcTo(5.6f, 5.6f, 0f, false, false, 18.3f, 17.2f)
            close()
        }
        .path(
            fill = null, stroke = SolidColor(Color.Black), strokeLineWidth = 1.8f,
            strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round,
        ) {
            moveTo(14f, 3.2f); lineTo(18f, 3.2f); lineTo(14f, 8f); lineTo(18f, 8f)
            moveTo(19.4f, 1.8f); lineTo(22f, 1.8f); lineTo(19.4f, 5.2f); lineTo(22f, 5.2f)
        }
        .build()

private val MoonZzz: ImageVector by lazy { moonZzz(false) }
private val MoonZzzFilled: ImageVector by lazy { moonZzz(true) }

/** The sleep timer button: the moon, and while it runs the countdown (or "End of song") in the accent color. */
@Composable
private fun SleepButton(sleep: SleepTimer) {
    var open by remember { mutableStateOf(false) }
    val endsAt = sleep.endsAt
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(endsAt) {
        while (endsAt != null) { now = System.currentTimeMillis(); delay(1000) }
    }
    val tint = if (sleep.active) Palette.accent else Color.White.copy(alpha = 0.8f)
    Box {
    PlainButton({ open = true }, Modifier.height(48.dp).padding(horizontal = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(if (sleep.active) MoonZzzFilled else MoonZzz, stringResource(R.string.sleep_timer), Modifier.size(28.dp), tint = tint)
            if (endsAt != null) {
                val total = ((endsAt - now + 999) / 1000).coerceAtLeast(0)
                val mm = ((total % 3600) / 60).toString()
                val ss = (total % 60).toString().padStart(2, '0')
                Text(
                    if (total >= 3600) "${total / 3600}:" + mm.padStart(2, '0') + ":" + ss else "${total / 60}:$ss",
                    Modifier.padding(start = 5.dp), color = tint, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                    style = MaterialTheme.typography.labelMedium.copy(fontFeatureSettings = "tnum"), maxLines = 1, softWrap = false,
                )
            } else if (sleep.endOfSong) {
                Text(stringResource(R.string.sleep_end_of_song), Modifier.padding(start = 5.dp), color = tint, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
            }
        }
    }
    IosMenu(open, { open = false }) {
        listOf(5, 15, 30, 45, 60, 90).forEach { m ->
            IosMenuItem(stringResource(R.string.sleep_minutes_long, m)) { open = false; Playback.service?.setSleepTimer(m) }
        }
        IosMenuItem(stringResource(R.string.sleep_end_of_song)) { open = false; Playback.service?.sleepAtEndOfSong() }
        if (sleep.active) IosMenuItem(stringResource(R.string.sleep_off), textColor = Palette.accent) { open = false; Playback.service?.cancelSleepTimer() }
    }
    }
}

/** The "playing from ..." line: one text per kind of source, taken from the id the songs were started with. */
private fun contextLabelRes(contextId: String?, context: String?, radio: Boolean, dj: Boolean): Int = when {
    dj || context == "DJ" -> R.string.pl_from_dj
    radio -> R.string.pl_from_radio
    contextId == "favorites" -> R.string.pl_from_favorites
    contextId == "downloads" -> R.string.pl_from_downloads
    contextId == "search" -> R.string.pl_from_search
    contextId != null && contextId.length > 1 && contextId[0] == 'p' -> R.string.pl_from_playlist
    contextId != null && contextId.length > 1 && contextId[0] == 'r' -> R.string.pl_from_artist
    contextId == null && context != null -> R.string.pl_from_mix
    else -> R.string.pl_from_album
}

/** A popup menu in the iPhone's style: rounded, dark and slightly see-through, flat (no Material elevation look). */
@Composable
private fun IosMenu(expanded: Boolean, onDismiss: () -> Unit, content: @Composable () -> Unit) {
    DropdownMenu(
        expanded = expanded, onDismissRequest = onDismiss,
        shape = RoundedCornerShape(24.dp),
        containerColor = Color(0xFF2C2C2E).copy(alpha = 0.96f),
        tonalElevation = 0.dp, shadowElevation = 0.dp,
        modifier = Modifier.widthIn(min = 230.dp),
    ) { content() }
}

/** One row of such a menu: 17 sp text, an optional symbol at the end. */
@Composable
private fun IosMenuItem(text: String, icon: ImageVector? = null, iconTint: Color = Color.White, textColor: Color = Color.White, onClick: () -> Unit) {
    DropdownMenuItem(
        text = { Text(text, fontSize = 17.sp, color = textColor, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        trailingIcon = if (icon == null) null else { { Icon(icon, null, Modifier.size(20.dp), tint = iconTint) } },
        onClick = onClick,
    )
}

@Composable
private fun IosMenuItem(text: Int, icon: ImageVector, onClick: () -> Unit) = IosMenuItem(stringResource(text), icon, onClick = onClick)

/** The "..." menu of the player: 20 dp symbol in a 40 dp box, no press highlight. */
@Composable
private fun PlayerMoreMenu(items: @Composable (close: () -> Unit) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        PlainButton(onClick = { open = true }, Modifier.size(40.dp)) {
            Icon(TonaloGlyphs.MoreHorizontal, stringResource(R.string.cd_more), Modifier.size(20.dp), tint = Color.White)
        }
        IosMenu(open, { open = false }) { items { open = false } }
    }
}

/** Position asked a few times a second while playing; `seek` moves it right away. */
@Composable
private fun rememberPosition(songId: String?, playing: Boolean): androidx.compose.runtime.MutableLongState {
    val player = LocalPlayer.current
    val position = remember { mutableLongStateOf(0L) }
    LaunchedEffect(songId, playing) {
        while (true) {
            position.longValue = player.position()
            // Paused: keep asking slowly, so seeks from the notification, Bluetooth or a TV show up too
            delay(if (playing) 250 else 750)
        }
    }
    return position
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun SeekBar(position: androidx.compose.runtime.MutableLongState, durationMs: Long, live: Boolean, badge: String? = null) {
    val player = LocalPlayer.current
    var dragging by remember { mutableStateOf(false) }
    var dragValue by remember { mutableFloatStateOf(0f) }
    val pos = position.longValue
    Column {
        val fraction = if (durationMs > 0) (pos.toFloat() / durationMs).coerceIn(0f, 1f) else 0f
        // Slim line with a small dot, like the iPhone app
        val colors = SliderDefaults.colors(
            thumbColor = Color.White, activeTrackColor = Color.White, inactiveTrackColor = Color.White.copy(alpha = 0.25f),
            disabledThumbColor = Color.White, disabledActiveTrackColor = Color.White.copy(alpha = 0.6f),
            disabledInactiveTrackColor = Color.White.copy(alpha = 0.25f),
        )
        Slider(
            value = if (live) 1f else if (dragging) dragValue else fraction,
            onValueChange = { dragging = true; dragValue = it },
            onValueChangeFinished = {
                val target = (dragValue * durationMs).toLong()
                player.seek(target)
                position.longValue = target
                dragging = false
            },
            enabled = durationMs > 0 && !live,
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
            val shown = if (dragging) (dragValue * durationMs).toLong() else pos
            // Tabular digits, so the numbers do not jiggle while counting
            val timeStyle = MaterialTheme.typography.labelSmall.copy(fontSize = 11.sp, fontFeatureSettings = "tnum")
            Text(if (live) stringResource(R.string.now_live) else formatTime(shown / 1000), style = timeStyle, color = Color.White.copy(alpha = 0.7f))
            Spacer(Modifier.weight(1f))
            // What is played: format and bitrate, in a small capsule
            if (badge != null) Text(
                badge, Modifier.border(1.dp, Color.White.copy(alpha = 0.35f), CircleShape).padding(horizontal = 9.dp, vertical = 2.dp),
                fontSize = 10.sp, fontWeight = FontWeight.Bold, color = Color.White.copy(alpha = 0.75f), maxLines = 1,
            )
            Spacer(Modifier.weight(1f))
            if (!live) Text("-" + formatTime((durationMs - shown).coerceAtLeast(0) / 1000), style = timeStyle, color = Color.White.copy(alpha = 0.7f))
        }
    }
}

@Composable
private fun PlayButton(size: androidx.compose.ui.unit.Dp = 66.dp) {
    val player = LocalPlayer.current
    val state by player.state.collectAsState()
    Box(
        Modifier.size(size).clip(CircleShape).background(Color.White).clickable(
            interactionSource = remember { MutableInteractionSource() }, indication = null, role = Role.Button,
        ) { player.toggle() },
        contentAlignment = Alignment.Center,
    ) {
        if (state.buffering && !state.isPlaying) CircularProgressIndicator(Modifier.size(size * 0.42f), color = Color.Black, strokeWidth = 3.dp)
        else Icon(
            if (state.isPlaying) TonaloIcons.Pause else TonaloIcons.Play,
            stringResource(if (state.isPlaying) R.string.cd_pause else R.string.cd_play),
            // The triangle looks centered when nudged to the right, like on the iPhone
            Modifier.size(size * 0.56f).offset(x = if (state.isPlaying) 0.dp else size * 0.03f), tint = Color.Black,
        )
    }
}

@Composable
fun PlayerScreen(onClose: () -> Unit) {
    val context = LocalContext.current
    val player = LocalPlayer.current
    val nav = LocalNav.current
    val snackbar = LocalSnackbar.current
    val scope = rememberCoroutineScope()
    val state by player.state.collectAsState()
    val sleep by Playback.sleep.collectAsState()
    var showQueue by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(false) }
    var pickPlaylist by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(false) }

    // Only once the connection has been asked: after a rotation the new connection starts empty, and the player must stay
    LaunchedEffect(state.hasMedia, state.connected) { if (state.connected && !state.hasMedia) onClose() }
    if (!state.hasMedia) return
    val djEnabled by DJ.enabled.collectAsState()
    val djReady = djEnabled && DJ.configured
    val djActive by DJ.active.collectAsState()
    val djLine by DJ.line.collectAsState()
    val song = state.current
    val station = state.station
    val position = rememberPosition(song?.id ?: station?.id, state.isPlaying)

    val radio by Playback.radio.collectAsState()
    val drag = remember { DismissDrag(scope) }
    drag.onClose = onClose

    // The tint follows the cover; a station has none (grey)
    PlayerBackground(
        if (station != null) null else song?.coverArt,
        Modifier.onSizeChanged { drag.height = it.height.toFloat().coerceAtLeast(1f) }.graphicsLayer { translationY = drag.offset.coerceAtLeast(0f) },
    ) {
        Column(Modifier.fillMaxSize().systemBarsPadding().padding(start = 24.dp, end = 24.dp, bottom = 32.dp)) {
            // Header: close, where it's playing from, menu. Pulling it down closes the player.
            Row(Modifier.fillMaxWidth().padding(top = 8.dp).dismissDrag(drag, skips = false), verticalAlignment = Alignment.CenterVertically) {
                PlainButton(onClick = onClose, Modifier.size(40.dp)) {
                    Icon(TonaloGlyphs.ChevronDown, stringResource(R.string.cd_close), Modifier.size(20.dp), tint = Color.White)
                }
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        state.tvName?.let { stringResource(if (state.tvGuest) R.string.guest_of else R.string.playing_on, it).uppercase() }
                            ?: stringResource(contextLabelRes(state.contextId, state.context, radio, djActive && state.tvName == null)),
                        fontSize = 11.sp, fontWeight = FontWeight.Medium, letterSpacing = 1.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        color = if (state.tvName != null) Palette.accent else Color.White.copy(alpha = 0.75f),
                    )
                    Text(
                        (if (djActive && state.tvName == null) djLine else null) ?: state.context ?: station?.let { stringResource(R.string.stations) } ?: song?.album ?: "",
                        fontSize = 13.sp, fontWeight = FontWeight.Bold, color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                }
                PlayerMoreMenu { close ->
                    IosMenuItem(R.string.devices, Icons.Default.Tv) { close(); onClose(); nav.open("devices") }
                    if (state.tvName == null) IosMenuItem(R.string.equalizer, Icons.Default.GraphicEq) { close(); nav.open("settings/eq") }
                    if (djReady && song != null && (state.tvName == null || !state.tvGuest) && station == null) IosMenuItem(R.string.dj_from_here, Icons.Default.AutoAwesome) {
                        close()
                        scope.launch {
                            try { DJ.takeOver(song); nav.open("dj") }
                            catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: Exception) { snackbar.showSnackbar(djMessage(context, e)) }
                        }
                    }
                    if (song != null) {
                        IosMenuItem(R.string.add_to_playlist, Icons.AutoMirrored.Filled.PlaylistAdd) { close(); pickPlaylist = true }
                        val downloaded = Downloads.isDownloaded(context, song.id)
                        IosMenuItem(if (downloaded) R.string.remove_download else R.string.download, Icons.Default.Download) {
                            close()
                            if (downloaded) Downloads.remove(context, listOf(song.id)) else Downloads.download(context, listOf(song))
                        }
                        song.albumId?.let { id -> IosMenuItem(R.string.go_to_album, Icons.Default.Album) { close(); onClose(); nav.open(albumRoute(id)) } }
                        song.artistId?.let { id -> IosMenuItem(R.string.go_to_artist, Icons.Default.Person) { close(); onClose(); nav.open(artistRoute(id)) } }
                    }
                }
            }

            // Cover: pull down to close, swipe sideways to skip
            BoxWithConstraints(
                Modifier.weight(1f).fillMaxWidth().padding(vertical = 16.dp)
                    .dismissDrag(drag, skips = station == null, onNext = { player.next() }, onPrevious = { player.previous() }),
                contentAlignment = Alignment.Center,
            ) {
                val side = minOf(maxWidth, maxHeight)
                if (station != null) Box(
                    Modifier.size(side).coverShadow().clip(RoundedCornerShape(8.dp)).background(Palette.hue(station.name, 0.5f, 0.6f)),
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Default.Radio, null, Modifier.size(side / 3)) }
                else Box(Modifier.coverShadow()) { Cover(song?.coverArt, side, corner = 8.dp, pixels = 1000) }
            }

            // Title, artist, heart
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(song?.title ?: station?.name ?: "", fontSize = 22.sp, lineHeight = 28.sp, fontWeight = FontWeight.Bold, color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(
                        song?.artist ?: state.liveTitle ?: stringResource(R.string.live), maxLines = 1, overflow = TextOverflow.Ellipsis,
                        color = Color.White.copy(alpha = 0.7f), fontSize = 16.sp, lineHeight = 22.sp,
                        modifier = song?.artistId?.let { id ->
                            Modifier.clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { onClose(); nav.open(artistRoute(id)) }
                        } ?: Modifier,
                    )
                }
                if (song != null) {
                    val starred = rememberStarred(song.id, song.starred)
                    PlainButton(onClick = { toggleFavorite(context, song, player, scope, snackbar) }, Modifier.size(44.dp)) {
                        Icon(if (starred) Icons.Rounded.Favorite else TonaloGlyphs.Heart, stringResource(R.string.cd_favorite),
                            Modifier.size(26.dp), tint = if (starred) Palette.accent else Color.White)
                    }
                }
            }

            Spacer(Modifier.height(18.dp))
            SeekBar(position, state.durationMs, live = station != null, badge = song?.let { sg -> sg.suffix?.takeIf { it.isNotBlank() }?.let { it.uppercase() + (sg.bitRate?.takeIf { b -> b > 0 }?.let { b -> " $b" } ?: "") } })
            Spacer(Modifier.height(14.dp))

            // Transport
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                val stateOn = stringResource(R.string.state_on)
                val stateOff = stringResource(R.string.state_off)
                val repeatState = stringResource(when (state.repeatMode) {
                    Player.REPEAT_MODE_ONE -> R.string.state_repeat_one
                    Player.REPEAT_MODE_ALL -> R.string.state_repeat_all
                    else -> R.string.state_off
                })
                // The outer buttons are 48 dp wide to hit easily; shifted out so their symbols line up with the margins
                PlainButton(
                    onClick = { player.toggleShuffle() },
                    Modifier.size(48.dp).offset(x = (-13).dp).semantics { stateDescription = if (state.shuffle) stateOn else stateOff },
                    enabled = station == null,
                ) { ToggleIcon(TonaloGlyphs.Shuffle, stringResource(R.string.cd_shuffle), state.shuffle) }
                PlainButton(onClick = { player.previous() }, Modifier.size(48.dp), enabled = station == null) {
                    Icon(TonaloIcons.Previous, stringResource(R.string.cd_previous), Modifier.size(38.dp), tint = Color.White)
                }
                PlayButton()
                PlainButton(onClick = { player.next() }, Modifier.size(48.dp), enabled = station == null) {
                    Icon(TonaloIcons.Next, stringResource(R.string.cd_next), Modifier.size(38.dp), tint = Color.White)
                }
                PlainButton(
                    onClick = { player.cycleRepeat() },
                    Modifier.size(48.dp).offset(x = 13.dp).semantics { stateDescription = repeatState },
                    enabled = station == null,
                ) {
                    ToggleIcon(
                        if (state.repeatMode == Player.REPEAT_MODE_ONE) TonaloGlyphs.RepeatOne else TonaloGlyphs.Repeat,
                        stringResource(R.string.cd_repeat), state.repeatMode != Player.REPEAT_MODE_OFF,
                    )
                }
            }
            Spacer(Modifier.height(20.dp))

            state.error?.let {
                Text(stringResource(R.string.error_playback), Modifier.fillMaxWidth(), color = MaterialTheme.colorScheme.error,
                    textAlign = TextAlign.Center, style = MaterialTheme.typography.bodySmall)
            }

            // Lyrics, sleep timer, device, DJ, queue: five symbols spread over the width, like the iPhone
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                PlainButton(onClick = { nav.open("lyrics") }, Modifier.size(48.dp).offset(x = (-14).dp), enabled = song != null) {
                    Icon(TonaloGlyphs.Lyrics, stringResource(R.string.lyrics), Modifier.size(28.dp), tint = Color.White.copy(alpha = 0.8f))
                }
                Spacer(Modifier.weight(1f))
                SleepButton(sleep)
                Spacer(Modifier.weight(1f))
                val onDevice = state.tvName != null
                DeviceButton(onDevice) { nav.open("devices") }
                Spacer(Modifier.weight(1f))
                if (djReady && !onDevice) {
                    PlainButton(onClick = { nav.open("dj") }, Modifier.size(48.dp)) {
                        DJMark(Modifier.size(27.dp), if (djActive) Palette.accent else Color.White.copy(alpha = 0.8f))
                    }
                    Spacer(Modifier.weight(1f))
                }
                PlainButton(onClick = { showQueue = true }, Modifier.size(48.dp).offset(x = 14.dp), enabled = song != null) {
                    Icon(TonaloGlyphs.Queue, stringResource(R.string.queue), Modifier.size(28.dp), tint = Color.White.copy(alpha = 0.8f))
                }
            }
            Spacer(Modifier.height(12.dp))
        }
    }

    if (showQueue && song != null) QueueSheet(onDismiss = { showQueue = false }, onClose = onClose)
    if (pickPlaylist && song != null) PlaylistPicker(listOf(song)) { pickPlaylist = false }
}

/**
 * The device button of the player: a menu with this phone and the TVs, computers and Jukeboxes the app knows, like the
 * iPhone's. The last entry opens the page with all devices.
 */
@Composable
private fun DeviceButton(onDevice: Boolean, openDevices: () -> Unit) {
    val player = LocalPlayer.current
    val devices by TvLink.devices.collectAsState()
    val pairings by TvLink.pairings.collectAsState()
    val remote by TvLink.remote.collectAsState()
    val ownTv by TvLink.ownTv.collectAsState()
    val guestOnly by TvLink.guestOnly.collectAsState()
    val joined by TvLink.jukebox.collectAsState()
    var open by remember { mutableStateOf(false) }
    // The own TV that is ready, then the Jukeboxes (same rule as the devices page)
    val jukeboxes = devices.filter { d -> d.id != ownTv?.id && (d.isPhone || d.id in guestOnly || pairings.any { it.tv == d.id && it.guest == true }) }
    val known = listOfNotNull(ownTv) + jukeboxes
    Box {
        PlainButton(onClick = { open = true }, Modifier.size(48.dp)) {
            Icon(TonaloGlyphs.Tv, stringResource(R.string.devices), Modifier.size(28.dp), tint = if (onDevice) Palette.accent else Color.White.copy(alpha = 0.8f))
        }
        IosMenu(open, { open = false }) {
            IosMenuItem(
                stringResource(R.string.this_phone), if (!onDevice) TonaloGlyphs.Checkmark else null, Palette.accent,
            ) { open = false; if (onDevice) player.continueHere() }
            known.forEach { d ->
                val here = remote?.device?.id == d.id
                IosMenuItem(d.name, if (here) TonaloGlyphs.Checkmark else TonaloGlyphs.Tv, Palette.accent) {
                    open = false
                    when {
                        here -> Unit
                        d.id == ownTv?.id -> if (!onDevice) player.playOnTv()
                        pairings.any { it.tv == d.id } -> if (joined != d.id) TvLink.join(d)
                        else -> openDevices()
                    }
                }
            }
            IosMenuItem(stringResource(if (known.isEmpty()) R.string.devices_dots else R.string.more_devices)) { open = false; openDevices() }
        }
    }
}

/**
 * What plays now and next, as a sheet over the player (half height, can be pulled to full): the current song, then the
 * upcoming ones. Each row's "..." menu moves (without shuffle), removes or jumps; "Clear" empties the queue after the song.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun QueueSheet(onDismiss: () -> Unit, onClose: () -> Unit) {
    val player = LocalPlayer.current
    val nav = LocalNav.current
    val state by player.state.collectAsState()
    val current = state.current ?: return
    val upNext = state.upNext
    val radio by Playback.radio.collectAsState()
    val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = false)
    val divider = Color.White.copy(alpha = 0.12f)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheet,
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp),
        containerColor = Palette.canvas,
        contentColor = Color.White,
        dragHandle = { androidx.compose.material3.BottomSheetDefaults.DragHandle() },
    ) {
        Box(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp), contentAlignment = Alignment.Center) {
            Text(stringResource(R.string.queue), fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
            if (upNext.isNotEmpty() && state.tvName == null) {
                TextButton(onClick = { player.clearUpNext() }, Modifier.align(Alignment.CenterEnd)) {
                    Text(stringResource(R.string.clear_up_next), color = Palette.accent)
                }
            }
        }
        LazyColumn(Modifier.fillMaxWidth(), contentPadding = PaddingValues(bottom = 24.dp)) {
            item { SectionHeader(stringResource(R.string.now_playing)) }
            item {
                QueueRow(current.title, current.artist, current.coverArt, playing = true, playingNow = state.isPlaying) { close ->
                    current.albumId?.let { id -> IosMenuItem(R.string.go_to_album, Icons.Default.Album) { close(); onDismiss(); onClose(); nav.open(albumRoute(id)) } }
                    current.artistId?.let { id -> IosMenuItem(R.string.go_to_artist, Icons.Default.Person) { close(); onDismiss(); onClose(); nav.open(artistRoute(id)) } }
                }
            }
            item {
                val from = state.context
                SectionHeader(if (from != null && !radio) stringResource(R.string.next_from, from) else stringResource(R.string.up_next))
            }
            if (upNext.isEmpty()) item { Text(stringResource(R.string.queue_empty), Modifier.padding(horizontal = 16.dp), color = Palette.secondaryText) }
            itemsIndexed(upNext, key = { _, index -> "q-$index-" + state.queue[index].id }) { pos, index ->
                val s = state.queue[index]
                Column {
                    if (pos > 0) Box(Modifier.padding(start = 76.dp).fillMaxWidth().height(0.5.dp).background(divider))
                    QueueRow(s.title, s.artist, s.coverArt, playing = false, playingNow = false, onClick = { player.jump(index) }) { close ->
                        if (!state.shuffle && state.tvName == null) {
                            if (pos > 0) IosMenuItem(R.string.cd_move_up, Icons.Default.KeyboardArrowUp) { close(); player.move(index, index - 1) }
                            if (pos < upNext.lastIndex) IosMenuItem(R.string.cd_move_down, Icons.Default.KeyboardArrowDown) { close(); player.move(index, index + 1) }
                        }
                        if (state.tvName == null) IosMenuItem(R.string.remove_from_queue, Icons.Default.Close) { close(); player.remove(index) }
                    }
                }
            }
        }
    }
}

/** A row of the queue sheet: cover 48 dp, title (accent while it plays), artist, bars and the "..." menu. */
@Composable
private fun QueueRow(
    title: String, artist: String?, coverArt: String?, playing: Boolean, playingNow: Boolean,
    onClick: () -> Unit = {}, menu: @Composable (close: () -> Unit) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().plainClickable(onClick = onClick).padding(start = 16.dp, end = 4.dp, top = 7.dp, bottom = 7.dp), verticalAlignment = Alignment.CenterVertically) {
        Cover(coverArt, 48.dp, corner = Palette.corner(4.dp), pixels = 150)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 16.sp, color = if (playing) Palette.accent else Color.White)
            if (!artist.isNullOrEmpty()) Text(artist, maxLines = 1, overflow = TextOverflow.Ellipsis, fontSize = 14.sp, color = Palette.secondaryText)
        }
        if (playing) { Spacer(Modifier.width(8.dp)); PlayingBars(playingNow) }
        Box {
            PlainButton(onClick = { open = true }, Modifier.size(44.dp)) {
                Icon(TonaloGlyphs.MoreHorizontal, stringResource(R.string.cd_more), Modifier.size(20.dp), tint = Palette.secondaryText)
            }
            IosMenu(open, { open = false }) { menu { open = false } }
        }
    }
}

/** Lyrics on their own page: synced ones follow the song (tap a line to jump there). */
@Composable
fun LyricsScreen(onClose: () -> Unit) {
    val player = LocalPlayer.current
    val state by player.state.collectAsState()
    val song = state.current
    LaunchedEffect(song) { if (song == null) onClose() }
    if (song == null) return
    val position = rememberPosition(song.id, state.isPlaying)
    val loader = rememberLoad("lyrics", song.id) { it.lyrics(song.id) }

    PlayerBackground(song.coverArt) {
        Column(Modifier.fillMaxSize().systemBarsPadding().padding(horizontal = 24.dp)) {
            Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onClose) { Icon(TonaloGlyphs.ChevronDown, stringResource(R.string.cd_close), Modifier.size(32.dp)) }
                Column(Modifier.padding(start = 8.dp)) {
                    Text(song.title, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(song.artist ?: "", color = Color.White.copy(alpha = 0.7f), style = MaterialTheme.typography.bodySmall)
                }
            }
            Box(Modifier.weight(1f).fillMaxWidth().clipToBounds()) {
                LoadView(loader) { lyrics: Lyrics? ->
                    if (lyrics == null) return@LoadView EmptyView(stringResource(R.string.no_lyrics))
                    val list = rememberLazyListState()
                    val pos = position.longValue
                    val active = if (lyrics.synced) lyrics.lines.indexOfLast { (it.start ?: 0) <= pos } else -1
                    LaunchedEffect(active) { if (active >= 0) list.animateScrollToItem((active - 1).coerceAtLeast(0)) }
                    LazyColumn(state = list, contentPadding = PaddingValues(vertical = 48.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                        itemsIndexed(lyrics.lines) { i, line ->
                            Text(
                                line.value.ifBlank { "♪" },
                                style = MaterialTheme.typography.headlineSmall,
                                fontWeight = FontWeight.Bold,
                                color = when {
                                    !lyrics.synced || i == active -> Color.White
                                    i < active -> Color.White.copy(alpha = 0.55f)
                                    else -> Color.White.copy(alpha = 0.4f)
                                },
                                modifier = if (lyrics.synced && line.start != null) Modifier.clickable { player.seek(line.start); position.longValue = line.start } else Modifier,
                            )
                        }
                    }
                }
            }
            SeekBar(position, state.durationMs, live = false)
            Box(Modifier.fillMaxWidth().padding(vertical = 12.dp), contentAlignment = Alignment.Center) { PlayButton(64.dp) }
        }
    }
}

/** What plays now and next: reorder (without shuffle), remove, clear. */
@Composable
fun QueueScreen(onClose: () -> Unit) {
    val player = LocalPlayer.current
    val state by player.state.collectAsState()
    val upNext = state.upNext
    val current = state.current
    LaunchedEffect(current) { if (current == null) onClose() }
    if (current == null) return
    Column(Modifier.fillMaxSize().background(Palette.canvas).systemBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(top = 8.dp, start = 8.dp, end = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onClose) { Icon(TonaloGlyphs.ChevronDown, stringResource(R.string.cd_close), Modifier.size(32.dp)) }
            Text(stringResource(R.string.queue), Modifier.weight(1f), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        }
        LazyColumn(contentPadding = PaddingValues(bottom = 16.dp)) {
            item { SectionHeader(stringResource(R.string.now_playing)) }
            item { ListRow(current.title, current.artist, current.coverArt, highlighted = true) {} }
            item {
                Row(Modifier.fillMaxWidth().padding(end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.weight(1f)) { SectionHeader(stringResource(R.string.up_next)) }
                    if (upNext.isNotEmpty()) TextButton(onClick = { player.clearUpNext() }) { Text(stringResource(R.string.clear_up_next), color = Palette.secondaryText) }
                }
            }
            if (upNext.isEmpty()) item { Text(stringResource(R.string.queue_empty), Modifier.padding(horizontal = 16.dp), color = Palette.secondaryText) }
            itemsIndexed(upNext, key = { _, index -> "q-$index-" + state.queue[index].id }) { pos, index ->
                val s = state.queue[index]
                ListRow(
                    s.title, s.artist, s.coverArt,
                    trailing = {
                        // Moving only makes sense in the queue's own order; with shuffle on the order is the player's
                        if (!state.shuffle && state.tvName == null) {
                            IconButton(onClick = { player.move(index, index - 1) }, enabled = pos > 0) { Icon(Icons.Default.KeyboardArrowUp, stringResource(R.string.cd_move_up)) }
                            IconButton(onClick = { player.move(index, index + 1) }, enabled = pos < upNext.lastIndex) { Icon(Icons.Default.KeyboardArrowDown, stringResource(R.string.cd_move_down)) }
                        }
                        if (state.tvName == null) IconButton(onClick = { player.remove(index) }) { Icon(Icons.Default.Close, stringResource(R.string.remove_from_queue)) }
                    },
                ) { player.jump(index) }
            }
        }
    }
}
