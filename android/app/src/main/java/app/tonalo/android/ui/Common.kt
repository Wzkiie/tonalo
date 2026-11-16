package app.tonalo.android.ui

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.ui.composed
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Favorite
import androidx.compose.material.icons.rounded.FavoriteBorder
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.HeartBroken
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.outlined.ArrowCircleDown
import androidx.compose.material.icons.filled.ArrowCircleDown
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.combinedClickable
import androidx.compose.material.icons.automirrored.filled.PlaylistAdd
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.Album
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Radio
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.navigation.NavController
import app.tonalo.android.R
import app.tonalo.android.data.Playlist
import app.tonalo.android.data.Song
import app.tonalo.android.data.SubsonicClient
import app.tonalo.android.data.SubsonicException
import app.tonalo.android.data.formatTime
import app.tonalo.android.playback.PlayerConnection
import app.tonalo.android.tonalo
import coil3.compose.SubcomposeAsyncImage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import java.io.IOException

// region Shared objects for all screens

val LocalPlayer = compositionLocalOf<PlayerConnection> { error("No player") }
val LocalNav = compositionLocalOf<NavController> { error("No navigation") }
val LocalSnackbar = compositionLocalOf { SnackbarHostState() }
/** Opens the side menu (accounts, downloads, devices, settings) – what the avatar does. */
val LocalMenu = compositionLocalOf<() -> Unit> { {} }

/** Changes to the user's playlists (made, renamed, deleted), so lists showing them load again. */
object Playlists {
    val version = MutableStateFlow(0)
    private val gone = HashSet<String>()
    fun changed() { version.value++ }
    fun deleted(id: String) { synchronized(gone) { gone.add(id) }; changed() }
    fun visible(list: List<Playlist>): List<Playlist> = synchronized(gone) { if (gone.isEmpty()) list else list.filter { it.id !in gone } }
}

/** Hearts set in this session, until the next load of a page shows the server's state. */
object Favorites {
    val overrides = MutableStateFlow<Map<String, Boolean>>(emptyMap())
    fun isStarred(id: String, serverValue: String?): Boolean = overrides.value[id] ?: (serverValue != null)
    fun isStarred(song: Song): Boolean = isStarred(song.id, song.starred)
    private val times = HashMap<String, Long>()
    fun set(id: String, on: Boolean) {
        synchronized(times) { times[id] = System.currentTimeMillis() }
        overrides.value = overrides.value + (id to on)
    }
    /** Fresh server data (requested at [since]) already shows the hearts set before it, so those overrides can go. */
    fun settle(since: Long) {
        val old = synchronized(times) { times.filterValues { it < since - 3000 }.keys.also { k -> k.forEach { times.remove(it) } } }
        if (old.isNotEmpty()) overrides.value = overrides.value - old
    }
}

@Composable
fun rememberStarred(id: String, serverValue: String?): Boolean {
    val map by Favorites.overrides.collectAsState()
    return map[id] ?: (serverValue != null)
}

// endregion

// region Loading

sealed interface Load<out T> {
    data object Loading : Load<Nothing>
    data class Ready<T>(val value: T) : Load<T>
    data class Failed(val message: String) : Load<Nothing>
}

class Loader<T>(val state: Load<T>, val reload: () -> Unit, val refreshing: Boolean = false)

/**
 * Loads something from the server for a page. The saved answer (if any) shows at once,
 * the server's answer replaces it when it arrives.
 */
@Composable
fun <T> rememberLoad(vararg keys: Any?, cached: ((SubsonicClient) -> T?)? = null, refresh: Int = 0, block: suspend (SubsonicClient) -> T): Loader<T> {
    val context = LocalContext.current
    val account by context.tonalo.current.collectAsState()
    var attempt by remember { mutableIntStateOf(0) }
    // The music server is part of the key: an account without one (audiobooks only) can get one, or lose it, under the same id
    val music = account?.serverURL
    var state by remember(*keys, account?.id, music) {
        val client = context.tonalo.client()
        mutableStateOf<Load<T>>(client?.let { c -> cached?.invoke(c)?.let { Load.Ready(it) } } ?: Load.Loading)
    }
    var running by remember { mutableStateOf(false) }
    // `refresh` only re-runs the load: the value on screen stays until the new one arrives
    LaunchedEffect(*keys, account?.id, music, attempt, refresh) {
        // No music server (an audiobooks-only account): nothing to ask, and no wheel that spins for ever
        val client = context.tonalo.client() ?: run {
            state = Load.Failed(context.getString(R.string.bka_no_music))
            return@LaunchedEffect
        }
        if (state is Load.Failed) state = Load.Loading
        running = true
        val since = System.currentTimeMillis()
        try {
            state = try {
                Load.Ready(block(client).also { Favorites.settle(since) })
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (state is Load.Ready) state else Load.Failed(errorText(context, e))
            }
        } finally {
            running = false
        }
    }
    return Loader(state, { attempt++ }, running && state is Load.Ready)
}

fun errorText(context: Context, e: Throwable): String = when (e) {
    is SubsonicException.Server -> when (e.code) {
        40 -> context.getString(R.string.error_wrong_login)
        50 -> context.getString(R.string.error_not_allowed)
        else -> e.message ?: ""
    }
    is SubsonicException.NotSubsonic -> context.getString(R.string.error_not_subsonic, e.status)
    is SubsonicException.Http -> context.getString(R.string.error_http, e.status)
    is SubsonicException.BadUrl -> context.getString(R.string.error_bad_url)
    is IOException -> context.getString(R.string.error_network)
    else -> e.message ?: context.getString(R.string.error_network)
}

@Composable
fun <T> LoadView(loader: Loader<T>, content: @Composable (T) -> Unit) {
    when (val s = loader.state) {
        is Load.Loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        is Load.Failed -> ErrorView(s.message, loader.reload)
        is Load.Ready -> content(s.value)
    }
}

@Composable
fun ErrorView(message: String, retry: () -> Unit) {
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(message, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(16.dp))
        Button(onClick = retry) { Text(stringResource(R.string.retry)) }
    }
}

@Composable
fun EmptyView(text: String = stringResource(R.string.nothing_here)) {
    Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
        Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

// endregion

// region Covers and rows

/** A click without the press ripple: the iPhone's rows, chips, tiles and cards show none. Keeps the button semantics. */
fun Modifier.plainClickable(enabled: Boolean = true, onClick: () -> Unit): Modifier = composed {
    clickable(
        interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() },
        indication = null, enabled = enabled, onClick = onClick,
    )
}

@Composable
fun Cover(coverArt: String?, size: Dp, modifier: Modifier = Modifier, corner: Dp = 4.dp, pixels: Int = 300, placeholder: ImageVector = Icons.Default.MusicNote) {
    val context = LocalContext.current
    val account by context.tonalo.current.collectAsState()
    val url = remember(coverArt, pixels, account?.id, account?.serverURL) { context.tonalo.client()?.coverURL(coverArt, pixels) }
    val shape = RoundedCornerShape(corner)
    val fallback = @Composable {
        Box(Modifier.fillMaxSize().background(Palette.elevated), contentAlignment = Alignment.Center) {
            // The iPhone's placeholder: a symbol in white at 45 % on the elevated colour
            Icon(placeholder, null, tint = Color.White.copy(alpha = 0.45f), modifier = Modifier.size(minOf(28.dp, size / 2)))
        }
    }
    Box(modifier.size(size).clip(shape)) {
        if (url == null) fallback() else SubcomposeAsyncImage(
            model = url,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize(),
            loading = { fallback() },
            error = { fallback() },
        )
    }
}

@Composable
fun SectionTitle(text: String, modifier: Modifier = Modifier, action: (@Composable () -> Unit)? = null) {
    Row(modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp, top = 20.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(text, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
        action?.invoke()
    }
}

@Composable
fun AlbumCard(title: String, subtitle: String?, coverArt: String?, size: Dp = 150.dp, onClick: () -> Unit) {
    Column(Modifier.width(size).plainClickable(onClick = onClick)) {
        Cover(coverArt, size, corner = Palette.corner(6.dp))
        Spacer(Modifier.height(6.dp))
        Text(title, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (!subtitle.isNullOrEmpty()) {
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = Palette.secondaryText, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
fun ListRow(
    title: String,
    subtitle: String? = null,
    coverArt: String? = null,
    showCover: Boolean = true,
    leading: (@Composable () -> Unit)? = null,
    placeholder: ImageVector = Icons.Default.MusicNote,
    round: Boolean = false,
    highlighted: Boolean = false,
    coverSize: Dp = 52.dp,
    subtitleContent: (@Composable () -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
    onClick: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().plainClickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        when {
            leading != null -> leading()
            showCover -> Cover(coverArt, coverSize, corner = if (round) coverSize / 2 else Palette.corner(4.dp), pixels = 150, placeholder = placeholder)
        }
        if (leading != null || showCover) Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                title, maxLines = 1, overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.bodyLarge,
                color = if (highlighted) Palette.accent else Color.Unspecified,
            )
            when {
                subtitleContent != null -> subtitleContent()
                !subtitle.isNullOrEmpty() -> Text(subtitle, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium, color = Palette.secondaryText)
            }
        }
        trailing?.invoke()
    }
}

/**
 * A song in a list, like the iPhone's SongRow: number or cover, title (accent while it plays), a heart and the
 * download state before the artist, and "…" with the song's menu – which a long press opens too.
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun SongRow(
    song: Song,
    showCover: Boolean = true,
    number: Int? = null,
    padded: Boolean = true,
    extraMenu: (@Composable (close: () -> Unit) -> Unit)? = null,
    /** Swipe right: play next. Swipe left: choose a playlist. Off where rows have their own gestures. */
    swipe: Boolean = true,
    onClick: () -> Unit,
) {
    val context = LocalContext.current
    val player = LocalPlayer.current
    val snackbar = LocalSnackbar.current
    val scope = rememberCoroutineScope()
    var pickPlaylist by remember { mutableStateOf(false) }
    val playsNext = stringResource(R.string.plays_next)
    val state by player.state.collectAsState()
    val downloads by app.tonalo.android.downloads.Downloads.all.collectAsState()
    val account by context.tonalo.current.collectAsState()
    val isCurrent = state.current?.id == song.id
    val starred = rememberStarred(song.id, song.starred)
    val download = account?.let { downloads[app.tonalo.android.downloads.Downloads.key(it.id, song.id)] }
    var menu by remember { mutableStateOf(false) }
    val swipeState = rememberSongSwipe(swipe,
        onRight = {
            val playing = state.current != null
            player.playNext(listOf(song))
            if (playing) scope.launch { snackbar.showSnackbar(playsNext) }
        },
        onLeft = { pickPlaylist = true },
    )
    if (pickPlaylist) PlaylistPicker(listOf(song)) { pickPlaylist = false }
    Box(Modifier.fillMaxWidth()) {
    SongSwipeBackdrop(swipeState)
    Row(
        Modifier.fillMaxWidth().songSwipe(swipeState).combinedClickable(
            interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }, indication = null,
            onClick = onClick, onLongClick = { menu = true },
        ).padding(horizontal = if (padded) 16.dp else 0.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (number != null) {
            Text("$number", Modifier.widthIn(min = 18.dp), color = Palette.secondaryText, fontSize = 15.sp)
            Spacer(Modifier.width(12.dp))
        }
        if (showCover) {
            Cover(song.coverArt, 48.dp, corner = Palette.corner(2.dp), pixels = 120, placeholder = Icons.Default.MusicNote)
            Spacer(Modifier.width(12.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(song.title, fontSize = 16.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, color = if (isCurrent) Palette.accent else Color.White)
            Row(Modifier.padding(top = 3.dp), verticalAlignment = Alignment.CenterVertically) {
                if (starred) { Icon(TonaloGlyphs.HeartFilled, stringResource(R.string.favorites), tint = Palette.accent, modifier = Modifier.size(11.dp)); Spacer(Modifier.width(5.dp)) }
                when {
                    download?.done == true -> { Icon(TonaloGlyphs.Downloaded, null, tint = Palette.accent, modifier = Modifier.size(12.dp)); Spacer(Modifier.width(5.dp)) }
                    download != null && !download.failed -> {
                        if (download.progress > 0) CircularProgressIndicator(progress = { download.progress }, Modifier.size(11.dp), color = Palette.accent, strokeWidth = 2.dp, trackColor = Palette.elevated)
                        else Icon(TonaloGlyphs.Download, null, tint = Palette.secondaryText, modifier = Modifier.size(12.dp))
                        Spacer(Modifier.width(5.dp))
                    }
                }
                song.artist?.let { Text(it, fontSize = 13.sp, color = Palette.secondaryText, maxLines = 1, overflow = TextOverflow.Ellipsis) }
            }
        }
        Spacer(Modifier.width(8.dp))
        // Says "this one plays right now" – in a playlist, an album and in the search alike
        if (isCurrent) PlayingBars(state.isPlaying, Modifier.size(width = 14.dp, height = 12.dp))
        SongMenu(song, extraMenu, open = menu, onOpen = { menu = it })
    }
    }
}

/**
 * A song row you can swipe like in other music apps: right plays it next, left opens the playlists to add it to.
 * The row follows the finger and shows the action in the gap; letting go far enough triggers it, otherwise it springs back.
 * Only a sideways move counts, so the list still scrolls when the finger starts on a row.
 */
class SongSwipe(val enabled: Boolean, val onRight: () -> Unit, val onLeft: () -> Unit, val offset: androidx.compose.animation.core.Animatable<Float, androidx.compose.animation.core.AnimationVector1D>) {
    var armed by mutableStateOf(false)
}

@Composable
fun rememberSongSwipe(enabled: Boolean, onRight: () -> Unit, onLeft: () -> Unit): SongSwipe {
    val offset = remember { androidx.compose.animation.core.Animatable(0f) }
    val right by androidx.compose.runtime.rememberUpdatedState(onRight)
    val left by androidx.compose.runtime.rememberUpdatedState(onLeft)
    return remember(enabled) { SongSwipe(enabled, { right() }, { left() }, offset) }
}

private val SwipeTrigger = 72.dp
private val SwipeMax = 130.dp

@Composable
fun Modifier.songSwipe(s: SongSwipe): Modifier {
    if (!s.enabled) return this
    val density = androidx.compose.ui.platform.LocalDensity.current
    val trigger = with(density) { SwipeTrigger.toPx() }
    val max = with(density) { SwipeMax.toPx() }
    val scope = rememberCoroutineScope()
    val haptic = androidx.compose.ui.platform.LocalHapticFeedback.current
    return this
        .offset { androidx.compose.ui.unit.IntOffset(s.offset.value.toInt(), 0) }
        .pointerInput(s) {
            fun release(go: Boolean) {
                val right = s.offset.value > 0
                s.armed = false
                scope.launch {
                    s.offset.animateTo(0f, androidx.compose.animation.core.spring(dampingRatio = 0.8f, stiffness = 400f))
                }
                if (go) {
                    // A stronger tap when the action fires (the light tick came when the threshold was crossed)
                    haptic.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.LongPress)
                    if (right) s.onRight() else s.onLeft()
                }
            }
            detectHorizontalDragGestures(
                onDragEnd = { release(kotlin.math.abs(s.offset.value) >= trigger) },
                onDragCancel = { release(false) },
            ) { change, drag ->
                change.consume()
                // A little resistance, so it feels like pulling something
                scope.launch { s.offset.snapTo((s.offset.value + drag * 0.85f).coerceIn(-max, max)) }
                val now = kotlin.math.abs(s.offset.value) >= trigger
                if (now != s.armed) {
                    s.armed = now
                    if (now) haptic.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.TextHandleMove)
                }
            }
        }
}

/** What shows in the gap while a row is pulled aside. */
@Composable
fun BoxScope.SongSwipeBackdrop(s: SongSwipe) {
    val pulled = s.offset.value
    if (!s.enabled || pulled == 0f) return
    val density = androidx.compose.ui.platform.LocalDensity.current.density
    Box(Modifier.matchParentSize().padding(horizontal = 24.dp), contentAlignment = if (pulled > 0) Alignment.CenterStart else Alignment.CenterEnd) {
        Icon(
            if (pulled > 0) TonaloGlyphs.TextInsert else TonaloGlyphs.TextBadgePlus, null, tint = Palette.accent,
            modifier = Modifier.size(18.dp).graphicsLayer {
                // The iPhone: opacity follows the pull, full after 40 points
                alpha = (kotlin.math.abs(pulled) / density / 40f).coerceAtMost(1f)
            },
        )
    }
}

/** The "…" of a song and its menu, in the iPhone's order. */
@Composable
fun SongMenu(
    song: Song,
    extraMenu: (@Composable (close: () -> Unit) -> Unit)? = null,
    open: Boolean? = null,
    onOpen: ((Boolean) -> Unit)? = null,
) {
    val context = LocalContext.current
    val player = LocalPlayer.current
    val nav = LocalNav.current
    val snackbar = LocalSnackbar.current
    val scope = rememberCoroutineScope()
    var ownOpen by remember { mutableStateOf(false) }
    val isOpen = open ?: ownOpen
    val setOpen: (Boolean) -> Unit = onOpen ?: { ownOpen = it }
    var pickPlaylist by remember { mutableStateOf(false) }
    val starred = rememberStarred(song.id, song.starred)
    val djOn by app.tonalo.android.dj.DJ.enabled.collectAsState()
    val downloads by app.tonalo.android.downloads.Downloads.all.collectAsState()
    val account by context.tonalo.current.collectAsState()
    val download = account?.let { downloads[app.tonalo.android.downloads.Downloads.key(it.id, song.id)] }
    Box {
        IconButton(onClick = { setOpen(true) }, modifier = Modifier.size(width = 32.dp, height = 40.dp)) {
            Icon(TonaloGlyphs.MoreHorizontal, stringResource(R.string.cd_more), tint = Palette.secondaryText, modifier = Modifier.size(16.dp))
        }
        DropdownMenu(expanded = isOpen, onDismissRequest = { setOpen(false) }) {
            val close = { setOpen(false) }
            song.albumId?.let { id -> MenuItem(R.string.go_to_album, TonaloGlyphs.SquareStack) { close(); nav.open(albumRoute(id)) } }
            song.artistId?.let { id -> MenuItem(R.string.go_to_artist, TonaloGlyphs.Mic) { close(); nav.open(artistRoute(id)) } }
            MenuItem(R.string.play_next, TonaloGlyphs.TextInsert) { close(); player.playNext(listOf(song)) }
            MenuItem(R.string.add_to_queue, TonaloGlyphs.TextAppend) {
                close(); player.enqueue(listOf(song))
                scope.launch { snackbar.showSnackbar(context.getString(R.string.added_to_queue)) }
            }
            MenuItem(R.string.add_to_playlist, TonaloGlyphs.TextBadgePlus) { close(); pickPlaylist = true }
            MenuItem(R.string.start_song_radio, TonaloGlyphs.Radio) {
                close()
                scope.launch {
                    val ok = app.tonalo.android.playback.Playback.service
                        ?.startRadio(context.getString(R.string.song_radio, song.title), seedId = song.id, first = song) ?: false
                    if (!ok) snackbar.showSnackbar(context.getString(R.string.radio_failed))
                }
            }
            if (djOn && app.tonalo.android.dj.DJ.configured) MenuItem(R.string.dj_from_here, TonaloGlyphs.Sparkles) {
                close()
                scope.launch {
                    try { app.tonalo.android.dj.DJ.takeOver(song) }
                    catch (e: CancellationException) { throw e } catch (e: Exception) { snackbar.showSnackbar(djMessage(context, e)) }
                }
            }
            when {
                download?.done == true -> MenuItem(R.string.remove_download, TonaloGlyphs.Trash) { close(); app.tonalo.android.downloads.Downloads.remove(context, listOf(song.id)) }
                download != null && !download.failed -> MenuItem(R.string.cancel_download, TonaloGlyphs.Xmark) { close(); app.tonalo.android.downloads.Downloads.remove(context, listOf(song.id)) }
                else -> MenuItem(R.string.download, TonaloGlyphs.Download) { close(); app.tonalo.android.downloads.Downloads.download(context, listOf(song)) }
            }
            MenuItem(if (starred) R.string.remove_favorite else R.string.add_favorite, if (starred) Icons.Default.HeartBroken else TonaloGlyphs.Heart) {
                close(); toggleFavorite(context, song, player, scope, snackbar, notify = true)
            }
            extraMenu?.invoke(close)
        }
    }
    if (pickPlaylist) PlaylistPicker(listOf(song)) { pickPlaylist = false }
}

@Composable
fun MenuItem(text: Int, icon: ImageVector, onClick: () -> Unit) {
    DropdownMenuItem(text = { Text(stringResource(text)) }, leadingIcon = { Icon(icon, null) }, onClick = onClick)
}

fun toggleFavorite(context: Context, song: Song, player: PlayerConnection, scope: kotlinx.coroutines.CoroutineScope, snackbar: SnackbarHostState, notify: Boolean = false) {
    val on = !Favorites.isStarred(song.id, song.starred)
    Favorites.set(song.id, on)
    scope.launch {
        try {
            context.tonalo.client()?.setStar(songId = song.id, on = on)
            player.update(song.copy(starred = if (on) "now" else null))
            if (on) app.tonalo.android.playback.Playback.service?.liked(song)
            // From a menu that closed right away: say what happened
            if (notify) snackbar.showSnackbar(context.getString(if (on) R.string.added_to_favorites else R.string.removed_from_favorites))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Favorites.set(song.id, !on)
            snackbar.showSnackbar(if (notify) context.getString(R.string.favorites_failed) else errorText(context, e))
        }
    }
}

/** Picks one of the user's own playlists – or makes a new one – and adds the songs. */
@Composable
fun PlaylistPicker(songs: List<Song>, onDone: () -> Unit) {
    val context = LocalContext.current
    val snackbar = LocalSnackbar.current
    val scope = rememberCoroutineScope()
    val account by context.tonalo.current.collectAsState()
    var creating by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }
    val loader = rememberLoad("pick-playlists") { c -> c.playlists().filter { it.readonly != true && (it.owner == null || it.owner == account?.username) } }

    /** Some of the songs are already in the chosen playlist: [fresh] are the ones that are not. */
    class Duplicates(val playlist: Playlist, val fresh: List<Song>)
    var duplicates by remember { mutableStateOf<Duplicates?>(null) }
    var busy by remember { mutableStateOf(false) }

    fun finish(message: String) { onDone(); context.tonalo.scope.launch { snackbar.showSnackbar(message) } }
    fun commit(p: Playlist, which: List<Song>) = scope.launch {
        try {
            context.tonalo.client()?.updatePlaylist(p.id, add = which.map { it.id }); Playlists.changed()
            finish(context.getString(R.string.added_to_playlist, p.name))
        } catch (e: CancellationException) { throw e } catch (e: Exception) { finish(errorText(context, e)) }
    }
    /** Looks for songs that are already in the playlist first, like the iPhone app and the big streaming apps. */
    fun add(p: Playlist) = scope.launch {
        if (busy) return@launch
        busy = true
        try {
            val existing = try { context.tonalo.client()?.playlist(p.id)?.entry.orEmpty().map { it.id }.toSet() } catch (e: CancellationException) { throw e } catch (e: Exception) { emptySet() }
            val fresh = songs.filter { it.id !in existing }
            if (fresh.size == songs.size) commit(p, songs) else duplicates = Duplicates(p, fresh)
        } finally { busy = false }
    }

    duplicates?.let { d ->
        AlertDialog(
            onDismissRequest = { duplicates = null },
            title = { Text(stringResource(R.string.already_in_playlist, d.playlist.name)) },
            text = {
                val already = songs.size - d.fresh.size
                Text(when {
                    songs.size == 1 -> stringResource(R.string.duplicate_one)
                    already == 1 -> stringResource(R.string.duplicate_one_of)
                    else -> stringResource(R.string.duplicate_some, already)
                })
            },
            confirmButton = {
                Row {
                    if (d.fresh.isNotEmpty() && d.fresh.size < songs.size) {
                        TextButton(onClick = { duplicates = null; commit(d.playlist, d.fresh) }) { Text(stringResource(R.string.add_new_only)) }
                    }
                    TextButton(onClick = { duplicates = null; commit(d.playlist, songs) }) { Text(stringResource(R.string.add_anyway)) }
                }
            },
            dismissButton = { TextButton(onClick = { duplicates = null }) { Text(stringResource(R.string.cancel)) } },
        )
    }

    AlertDialog(
        onDismissRequest = onDone,
        title = { Text(stringResource(if (creating) R.string.new_playlist else R.string.add_to_playlist)) },
        text = {
            if (creating) {
                OutlinedTextField(name, { name = it }, label = { Text(stringResource(R.string.playlist_name)) }, singleLine = true)
            } else {
                Box(Modifier.height(320.dp)) {
                    LoadView(loader) { lists ->
                        LazyColumn {
                            item { ListRow(stringResource(R.string.new_playlist), leading = {
                                Box(Modifier.size(52.dp).clip(RoundedCornerShape(Palette.corner(4.dp))).background(Palette.elevated), contentAlignment = Alignment.Center) {
                                    Icon(TonaloGlyphs.Plus, null)
                                }
                            }) { creating = true } }
                            items(lists, key = { it.id }) { p ->
                                ListRow(p.name, pluralString(R.plurals.song_count, p.songCount ?: 0), p.coverArt) { add(p) }
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            if (creating) TextButton(enabled = name.isNotBlank(), onClick = {
                scope.launch {
                    try {
                        context.tonalo.client()?.createPlaylist(name.trim(), songs.map { it.id }); Playlists.changed()
                        finish(context.getString(R.string.added_to_playlist, name.trim()))
                    } catch (e: CancellationException) { throw e } catch (e: Exception) { finish(errorText(context, e)) }
                }
            }) { Text(stringResource(R.string.create)) }
        },
        dismissButton = { TextButton(onClick = onDone) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
fun pluralString(id: Int, count: Int): String = LocalContext.current.resources.getQuantityString(id, count, count)

// endregion
