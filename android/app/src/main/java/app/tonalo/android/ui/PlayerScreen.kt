package app.tonalo.android.ui

import androidx.compose.foundation.background
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
import androidx.compose.material3.AlertDialog
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
import androidx.media3.common.Player
import app.tonalo.android.R
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

/** The player's background: the cover's color fading to almost black. */
@Composable
private fun PlayerBackground(coverArt: String?, content: @Composable () -> Unit) {
    val tint = rememberCoverColor(coverArt) ?: Palette.elevated
    Box(
        Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(tint, tint.darken(0.45f), Palette.canvas)))
    ) { content() }
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
private fun SeekBar(position: androidx.compose.runtime.MutableLongState, durationMs: Long, live: Boolean) {
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
            Text(if (live) stringResource(R.string.now_live) else formatTime(shown / 1000), style = MaterialTheme.typography.labelSmall, color = Color.White.copy(alpha = 0.7f))
            Spacer(Modifier.weight(1f))
            if (!live) Text("-" + formatTime((durationMs - shown).coerceAtLeast(0) / 1000), style = MaterialTheme.typography.labelSmall, color = Color.White.copy(alpha = 0.7f))
        }
    }
}

@Composable
private fun PlayButton(size: androidx.compose.ui.unit.Dp = 76.dp) {
    val player = LocalPlayer.current
    val state by player.state.collectAsState()
    Box(
        Modifier.size(size).clip(CircleShape).background(Color.White).clickable { player.toggle() },
        contentAlignment = Alignment.Center,
    ) {
        if (state.buffering && !state.isPlaying) CircularProgressIndicator(Modifier.size(size * 0.42f), color = Color.Black, strokeWidth = 3.dp)
        else Icon(
            if (state.isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
            stringResource(if (state.isPlaying) R.string.cd_pause else R.string.cd_play),
            Modifier.size(size * 0.5f), tint = Color.Black,
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
    var sleepDialog by remember { mutableStateOf(false) }
    var pickPlaylist by remember { mutableStateOf(false) }

    LaunchedEffect(state.hasMedia) { if (!state.hasMedia) onClose() }
    if (!state.hasMedia) return
    val djEnabled by DJ.enabled.collectAsState()
    val djReady = djEnabled && DJ.configured
    val djActive by DJ.active.collectAsState()
    val djLine by DJ.line.collectAsState()
    val song = state.current
    val station = state.station
    val position = rememberPosition(song?.id ?: station?.id, state.isPlaying)

    PlayerBackground(song?.coverArt) {
        Column(Modifier.fillMaxSize().systemBarsPadding().padding(horizontal = 24.dp)) {
            // Header: close, where it's playing from, menu
            Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onClose) { Icon(Icons.Default.KeyboardArrowDown, stringResource(R.string.cd_close), Modifier.size(32.dp)) }
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(
                        (state.tvName?.let { stringResource(if (state.tvGuest) R.string.guest_of else R.string.playing_on, it) } ?: stringResource(R.string.playing_from)).uppercase(),
                        style = MaterialTheme.typography.labelSmall, color = if (state.tvName != null) Palette.accent else Color.White.copy(alpha = 0.7f),
                    )
                    Text(
                        (if (djActive && state.tvName == null) djLine else null) ?: state.context ?: station?.let { stringResource(R.string.stations) } ?: song?.album ?: "",
                        style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                }
                MoreMenu { close ->
                    MenuItem(R.string.devices, Icons.Default.Tv) { close(); onClose(); nav.open("devices") }
                    if (state.tvName == null) MenuItem(R.string.sleep_timer, Icons.Default.Bedtime) { close(); sleepDialog = true }
                    if (state.tvName == null) MenuItem(R.string.equalizer, Icons.Default.GraphicEq) { close(); nav.open("settings/eq") }
                    if (djReady && song != null && (state.tvName == null || !state.tvGuest) && station == null) MenuItem(R.string.dj_from_here, Icons.Default.AutoAwesome) {
                        close()
                        scope.launch {
                            try { DJ.takeOver(song); nav.open("dj") }
                            catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: Exception) { snackbar.showSnackbar(djMessage(context, e)) }
                        }
                    }
                    if (song != null) {
                        MenuItem(R.string.add_to_playlist, Icons.AutoMirrored.Filled.PlaylistAdd) { close(); pickPlaylist = true }
                        val downloaded = Downloads.isDownloaded(context, song.id)
                        MenuItem(if (downloaded) R.string.remove_download else R.string.download, Icons.Default.Download) {
                            close()
                            if (downloaded) Downloads.remove(context, listOf(song.id)) else Downloads.download(context, listOf(song))
                        }
                        song.albumId?.let { id -> MenuItem(R.string.go_to_album, Icons.Default.Album) { close(); onClose(); nav.open(albumRoute(id)) } }
                        song.artistId?.let { id -> MenuItem(R.string.go_to_artist, Icons.Default.Person) { close(); onClose(); nav.open(artistRoute(id)) } }
                    }
                }
            }

            // Cover
            BoxWithConstraints(Modifier.weight(1f).fillMaxWidth().padding(vertical = 24.dp), contentAlignment = Alignment.Center) {
                val side = minOf(maxWidth, maxHeight)
                if (station != null) Box(
                    Modifier.size(side).shadow(24.dp, RoundedCornerShape(8.dp)).clip(RoundedCornerShape(8.dp)).background(Palette.hue(station.name, 0.5f, 0.6f)),
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Default.Radio, null, Modifier.size(side / 3)) }
                else Box(Modifier.shadow(24.dp, RoundedCornerShape(8.dp))) { Cover(song?.coverArt, side, corner = 8.dp, pixels = 1000) }
            }

            // Title, artist, heart
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(song?.title ?: station?.name ?: "", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(
                        song?.artist ?: state.liveTitle ?: stringResource(R.string.live), maxLines = 1, overflow = TextOverflow.Ellipsis,
                        color = Color.White.copy(alpha = 0.7f), style = MaterialTheme.typography.bodyLarge,
                        modifier = song?.artistId?.let { id -> Modifier.clickable { onClose(); nav.open(artistRoute(id)) } } ?: Modifier,
                    )
                }
                if (song != null) {
                    val starred = rememberStarred(song.id, song.starred)
                    IconButton(onClick = { toggleFavorite(context, song, player, scope, snackbar) }) {
                        Icon(if (starred) Icons.Default.Favorite else Icons.Default.FavoriteBorder, stringResource(R.string.cd_favorite),
                            Modifier.size(28.dp), tint = if (starred) Palette.accent else Color.White)
                    }
                }
            }

            Spacer(Modifier.height(8.dp))
            SeekBar(position, state.durationMs, live = station != null)

            // Transport
            Row(
                Modifier.fillMaxWidth().padding(vertical = 12.dp),
                horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = { player.toggleShuffle() }, enabled = station == null) {
                    Icon(Icons.Default.Shuffle, stringResource(R.string.cd_shuffle), tint = if (state.shuffle) Palette.accent else Color.White)
                }
                IconButton(onClick = { player.previous() }, Modifier.size(56.dp), enabled = station == null) {
                    Icon(Icons.Default.SkipPrevious, stringResource(R.string.cd_previous), Modifier.size(40.dp))
                }
                PlayButton()
                IconButton(onClick = { player.next() }, Modifier.size(56.dp), enabled = station == null) {
                    Icon(Icons.Default.SkipNext, stringResource(R.string.cd_next), Modifier.size(40.dp))
                }
                IconButton(onClick = { player.cycleRepeat() }, enabled = station == null) {
                    Icon(
                        if (state.repeatMode == Player.REPEAT_MODE_ONE) Icons.Default.RepeatOne else Icons.Default.Repeat,
                        stringResource(R.string.cd_repeat),
                        tint = if (state.repeatMode != Player.REPEAT_MODE_OFF) Palette.accent else Color.White,
                    )
                }
            }

            state.error?.let {
                Text(stringResource(R.string.error_playback), Modifier.fillMaxWidth(), color = MaterialTheme.colorScheme.error,
                    textAlign = TextAlign.Center, style = MaterialTheme.typography.bodySmall)
            }

            // Lyrics · sleep timer · queue
            Row(Modifier.fillMaxWidth().padding(bottom = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = { nav.open("lyrics") }, enabled = song != null) { Icon(Icons.Default.FormatQuote, stringResource(R.string.lyrics)) }
                Spacer(Modifier.weight(1f))
                val ownTv by TvLink.ownTv.collectAsState()
                when {
                    state.tvName != null -> TextButton(onClick = { player.continueHere() }) {
                        Icon(Icons.Default.PhoneAndroid, null, Modifier.size(18.dp)); Spacer(Modifier.size(6.dp))
                        Text(stringResource(if (state.tvGuest) R.string.leave else R.string.play_here), color = Color.White)
                    }
                    ownTv != null -> TextButton(onClick = { player.playOnTv() }) {
                        Icon(Icons.Default.Tv, null, Modifier.size(18.dp), tint = Palette.accent); Spacer(Modifier.size(6.dp))
                        Text(stringResource(R.string.play_on, ownTv!!.name), color = Palette.accent)
                    }
                }
                if (sleep.active) Text(
                    if (sleep.endOfSong) stringResource(R.string.sleep_active_song)
                    else stringResource(R.string.sleep_active, DateFormat.getTimeInstance(DateFormat.SHORT).format(Date(sleep.endsAt!!))),
                    Modifier.clickable { sleepDialog = true }, style = MaterialTheme.typography.labelMedium, color = Palette.accent,
                )
                Spacer(Modifier.weight(1f))
                if (djReady && state.tvName == null) IconButton(onClick = { nav.open("dj") }) {
                    Icon(Icons.Default.AutoAwesome, stringResource(R.string.dj), tint = if (djActive) Palette.accent else Color.White)
                }
                IconButton(onClick = { nav.open("queue") }, enabled = song != null) { Icon(Icons.AutoMirrored.Filled.FormatListBulleted, stringResource(R.string.queue)) }
            }
        }
    }

    if (sleepDialog) SleepTimerDialog { sleepDialog = false }
    if (pickPlaylist && song != null) PlaylistPicker(listOf(song)) { pickPlaylist = false }
}

@Composable
private fun SleepTimerDialog(onDone: () -> Unit) {
    val sleep by Playback.sleep.collectAsState()
    AlertDialog(
        onDismissRequest = onDone,
        title = { Text(stringResource(R.string.sleep_timer)) },
        text = {
            Column {
                listOf(5, 15, 30, 45, 60, 90).forEach { m ->
                    Text(stringResource(R.string.sleep_minutes, m), Modifier.fillMaxWidth().clickable { Playback.service?.setSleepTimer(m); onDone() }.padding(vertical = 12.dp))
                }
                Text(stringResource(R.string.sleep_end_of_song), Modifier.fillMaxWidth().clickable { Playback.service?.sleepAtEndOfSong(); onDone() }.padding(vertical = 12.dp))
            }
        },
        confirmButton = {
            if (sleep.active) TextButton(onClick = { Playback.service?.cancelSleepTimer(); onDone() }) { Text(stringResource(R.string.sleep_off)) }
        },
        dismissButton = { TextButton(onClick = onDone) { Text(stringResource(R.string.cancel)) } },
    )
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
                IconButton(onClick = onClose) { Icon(Icons.Default.KeyboardArrowDown, stringResource(R.string.cd_close), Modifier.size(32.dp)) }
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
            IconButton(onClick = onClose) { Icon(Icons.Default.KeyboardArrowDown, stringResource(R.string.cd_close), Modifier.size(32.dp)) }
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
