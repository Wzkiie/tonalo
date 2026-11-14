package app.tonalo.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Album
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.automirrored.filled.ArrowBackIos
import androidx.compose.material.icons.filled.ArrowCircleDown
import kotlinx.coroutines.launch
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.tonalo.android.R
import app.tonalo.android.data.Song
import app.tonalo.android.downloads.Downloads
import app.tonalo.android.tonalo
import kotlinx.coroutines.delay

/** The round letter of a name, in a color fixed for that name. */
@Composable
fun NameAvatar(name: String, size: Dp = 36.dp, modifier: Modifier = Modifier) {
    val letter = name.firstOrNull()?.uppercaseChar()?.toString() ?: "?"
    Box(modifier.size(size).clip(CircleShape).background(Palette.avatar(name)), contentAlignment = Alignment.Center) {
        Text(letter, color = Color.Black, fontWeight = FontWeight.Bold, fontSize = (size.value * 0.45f).sp)
    }
}

/** The account's avatar, top left – opens the side menu with accounts and settings (like the iPhone app). */
@Composable
fun Avatar(size: Dp = 36.dp) {
    val context = LocalContext.current
    val openMenu = LocalMenu.current
    val account by context.tonalo.current.collectAsState()
    NameAvatar(account?.username ?: "?", size, Modifier.clip(CircleShape).clickable(onClick = openMenu))
}

/** Page title with the avatar in front, for the three main tabs. */
@Composable
fun TabHeader(title: String?, content: @Composable () -> Unit = {}) {
    Row(
        Modifier.fillMaxWidth().statusBarsPadding().padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Avatar()
        Spacer(Modifier.width(12.dp))
        if (title != null) Text(title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        content()
    }
}

@Composable
fun Chip(text: String, selected: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.height(32.dp).clip(CircleShape)
            .background(if (selected) Palette.accent else Palette.elevated)
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, color = if (selected) Color.Black else Color.White, fontSize = 14.sp, fontWeight = FontWeight.Medium)
    }
}

@Composable
fun ChipRow(content: @Composable () -> Unit) {
    Row(
        Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically,
    ) { content() }
}

/** Small tile with a cover on the left – the two-column grid at the top of the home page. */
@Composable
fun QuickTile(
    title: String, modifier: Modifier = Modifier, current: Boolean = false, playing: Boolean = false,
    art: @Composable () -> Unit, onClick: () -> Unit,
) {
    // What plays (or is paused) right now: the tile shows it, with a small level meter in the corner
    Box(
        modifier.height(56.dp).clip(RoundedCornerShape(Palette.corner(4.dp)))
            .background(if (current) Palette.accent.copy(alpha = 0.22f) else Palette.elevated).clickable(onClick = onClick),
    ) {
        Row(Modifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(56.dp)) { art() }
            Text(
                title, Modifier.padding(start = 8.dp, end = 4.dp).weight(1f), maxLines = 2, overflow = TextOverflow.Ellipsis,
                fontWeight = FontWeight.Bold, fontSize = 13.sp, lineHeight = 16.sp,
                color = if (current) Palette.accent else Color.White,
            )
        }
        if (current) {
            Box(Modifier.align(Alignment.CenterStart).width(3.dp).fillMaxHeight().background(Palette.accent))
            PlayingBars(playing, Modifier.align(Alignment.TopEnd).padding(top = 8.dp, end = 9.dp).size(width = 13.dp, height = 11.dp))
        }
    }
}

/**
 * The small level meter that says "this plays right now": the bars move while it plays and rest while it is paused.
 */
@Composable
fun PlayingBars(active: Boolean, modifier: Modifier = Modifier.size(width = 14.dp, height = 12.dp)) {
    var t by androidx.compose.runtime.remember { androidx.compose.runtime.mutableFloatStateOf(0f) }
    LaunchedEffect(active) {
        if (active) while (true) androidx.compose.runtime.withFrameNanos { t = (it / 1_000_000L) / 1000f }
    }
    val color = Palette.accent
    androidx.compose.foundation.Canvas(modifier) {
        val phase = floatArrayOf(0f, 1.7f, 3.1f, 0.9f)
        val speed = floatArrayOf(5.2f, 6.4f, 4.6f, 5.8f)
        val rest = floatArrayOf(0.45f, 0.8f, 0.6f, 0.35f)
        val barW = 3.5.dp.toPx()
        val gap = 2.5.dp.toPx()
        var x = (size.width - (barW * 4 + gap * 3)) / 2
        for (i in 0 until 4) {
            val level = if (active) 0.55f + 0.45f * kotlin.math.sin(t * speed[i] + phase[i]) else rest[i]
            val h = size.height * maxOf(0.18f, level)
            drawRoundRect(
                color, topLeft = androidx.compose.ui.geometry.Offset(x, size.height - h),
                size = androidx.compose.ui.geometry.Size(barW, h), cornerRadius = androidx.compose.ui.geometry.CornerRadius(barW / 2),
            )
            x += barW + gap
        }
    }
}

/** The DJ's art while the DJ plays: the glow breathes and the three bars of the mark move (still when [playing] is false). */
@Composable
fun AnimatedDJArt(playing: Boolean, modifier: Modifier = Modifier.fillMaxSize()) {
    var t by androidx.compose.runtime.remember { androidx.compose.runtime.mutableFloatStateOf(0f) }
    LaunchedEffect(playing) {
        if (playing) while (true) androidx.compose.runtime.withFrameNanos { t = (it / 1_000_000L) / 1000f }
    }
    val color = Palette.accent
    val glow = if (playing) 0.30f + 0.16f * kotlin.math.sin(t * 2.6f) else 0.22f
    Box(
        modifier.background(Brush.linearGradient(listOf(Color(0xFF3D3D3D), Color(0xFF1F1F1F))))
            .background(Brush.linearGradient(listOf(color.copy(alpha = glow), color.copy(alpha = 0.06f)))),
        contentAlignment = Alignment.Center,
    ) {
        androidx.compose.foundation.Canvas(Modifier.fillMaxSize(0.54f)) {
            val s = minOf(size.width, size.height)
            val line = s * 0.1f
            val r = (s - line) / 2
            val c = androidx.compose.ui.geometry.Offset(size.width / 2, size.height / 2)
            drawArc(
                color, startAngle = -16.2f, sweepAngle = 360f * 0.84f, useCenter = false,
                topLeft = androidx.compose.ui.geometry.Offset(c.x - r, c.y - r), size = androidx.compose.ui.geometry.Size(r * 2, r * 2),
                style = androidx.compose.ui.graphics.drawscope.Stroke(width = line, cap = androidx.compose.ui.graphics.StrokeCap.Round),
            )
            drawCircle(color, radius = line * 0.625f, center = androidx.compose.ui.geometry.Offset(c.x + r * 0.7071f, c.y - r * 0.7071f))
            val gap = s * 0.07f
            val low = floatArrayOf(0.22f, 0.40f, 0.30f)
            val speed = floatArrayOf(5.0f, 6.2f, 4.4f)
            var x = c.x - (line * 3 + gap * 2) / 2
            for (i in 0 until 3) {
                val h = s * (if (playing) 0.30f + 0.17f * kotlin.math.sin(t * speed[i] + i * 1.9f) else low[i])
                drawRoundRect(color, topLeft = androidx.compose.ui.geometry.Offset(x, c.y - h / 2),
                    size = androidx.compose.ui.geometry.Size(line, h), cornerRadius = androidx.compose.ui.geometry.CornerRadius(line / 2))
                x += line + gap
            }
        }
    }
}

/**
 * Pull to refresh with one visible spinner: it shows from the pull until [refreshing] is over, at least 700 ms
 * (a cached or local answer would otherwise flash by unseen). Reloads that were not pulled show no spinner.
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun Refreshable(refreshing: Boolean, onRefresh: () -> Unit, modifier: Modifier = Modifier.fillMaxSize(), content: @Composable BoxScope.() -> Unit) {
    var pulled by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }
    var until by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(0L) }
    LaunchedEffect(pulled, refreshing) {
        if (pulled && !refreshing) {
            val rest = until - android.os.SystemClock.elapsedRealtime()
            if (rest > 0) kotlinx.coroutines.delay(rest)
            pulled = false
        }
    }
    androidx.compose.material3.pulltorefresh.PullToRefreshBox(
        isRefreshing = pulled,
        onRefresh = { until = android.os.SystemClock.elapsedRealtime() + 700; pulled = true; onRefresh() },
        modifier = modifier,
        content = content,
    )
}

/** "Favorite songs": a white heart on the accent color, fading toward the page. */
@Composable
fun FavoritesArt(modifier: Modifier = Modifier.fillMaxSize(), corner: Dp = 0.dp) {
    Box(
        modifier.clip(RoundedCornerShape(corner)).background(Palette.canvas)
            .background(Brush.linearGradient(listOf(Palette.accent, Palette.accent.copy(alpha = 0.35f)))),
        contentAlignment = Alignment.Center,
    ) { Icon(Icons.Default.Favorite, null, tint = Color.White, modifier = Modifier.fillMaxSize(0.38f)) }
}

/** "Downloads": the accent arrow on a gray gradient. */
@Composable
fun DownloadsArt(modifier: Modifier = Modifier.fillMaxSize(), corner: Dp = 0.dp) {
    Box(
        modifier.clip(RoundedCornerShape(corner)).background(Brush.linearGradient(listOf(Color(0xFF4D4D4D), Color(0xFF1F1F1F)))),
        contentAlignment = Alignment.Center,
    ) { Icon(Icons.Default.ArrowCircleDown, null, tint = Palette.accent, modifier = Modifier.fillMaxSize(0.42f)) }
}

/** A color for a name that stays the same on every start – the same pick as the iPhone (FNV hash). */
fun stableHue(name: String): Float {
    var seed = 2166136261u
    name.forEach { c -> seed = (seed xor c.code.toUInt()) * 16777619u }
    return ((seed xor (seed shr 16)) % 360u).toFloat() / 360f
}

/** The iPhone's gradient for mixes and stations: light at the top left, dark at the bottom right. */
fun hueGradient(hue: Float, endBrightness: Float = 0.35f) = Brush.linearGradient(
    listOf(Color.hsv((hue * 360f) % 360f, 0.55f, 0.75f), Color.hsv(((hue + 0.06f) * 360f) % 360f, 0.7f, endBrightness)),
)

/** Big colored card that starts a generated queue – "Made for you" and the radios. Shows a spinner while it loads. */
@Composable
fun MixCard(title: String, subtitle: String?, hue: Float, icon: ImageVector, size: Dp = 150.dp, onClick: suspend () -> Unit) {
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var busy by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }
    val small = size < 150.dp
    Column(Modifier.width(size)) {
        Box(
            Modifier.size(size).clip(RoundedCornerShape(Palette.corner(4.dp))).background(hueGradient(hue))
                .clickable { if (!busy) { busy = true; scope.launch { try { onClick() } finally { busy = false } } } },
        ) {
            Icon(
                icon, null, tint = Color.White.copy(alpha = 0.9f),
                modifier = if (small) Modifier.align(Alignment.TopEnd).padding(10.dp).size(24.dp) else Modifier.align(Alignment.Center).size(48.dp),
            )
            if (busy) CircularProgressIndicator(Modifier.align(Alignment.BottomStart).padding(10.dp).size(20.dp), color = Color.White, strokeWidth = 2.dp)
            else Text(
                title, Modifier.align(Alignment.BottomStart).padding(10.dp),
                fontWeight = FontWeight.ExtraBold, fontSize = 15.sp, maxLines = 2, overflow = TextOverflow.Ellipsis, color = Color.White,
            )
        }
        if (!subtitle.isNullOrEmpty()) {
            Text(subtitle, Modifier.padding(top = 6.dp), color = Palette.secondaryText, fontSize = 13.sp, lineHeight = 16.sp, maxLines = 2)
        }
    }
}

fun Color.darken(factor: Float) = Color(red * factor, green * factor, blue * factor, alpha)

/** A page whose top fades from the cover's color into the background (album, playlist, player). */
@Composable
fun TintedBackground(color: Color?, height: Dp = 420.dp, content: @Composable BoxScope.() -> Unit) {
    Box(Modifier.fillMaxSize().background(Palette.canvas)) {
        if (color != null) Box(
            Modifier.fillMaxWidth().height(height)
                .background(Brush.verticalGradient(listOf(color, Palette.canvas))),
        )
        content()
    }
}

/** Round, see-through back button floating over a page. */
@Composable
fun RoundBackButton(modifier: Modifier = Modifier) {
    GlassBackButton(modifier.statusBarsPadding().padding(start = 12.dp, top = 8.dp))
}

/** The round back button itself, gray and a little see-through. */
@Composable
fun GlassBackButton(modifier: Modifier = Modifier, onClick: (() -> Unit)? = null) {
    val nav = LocalNav.current
    IconButton(
        onClick = onClick ?: { nav.popBackStack(); Unit },
        modifier = modifier.size(46.dp).clip(CircleShape).background(Color(0xFF2C2C2E).copy(alpha = 0.88f)),
    ) { Icon(Icons.AutoMirrored.Filled.ArrowBackIos, stringResource(R.string.cd_back), tint = Color.White, modifier = Modifier.padding(start = 6.dp).size(20.dp)) }
}

/** The big round play button in the accent color. */
@Composable
fun BigPlayButton(size: Dp = 56.dp, onClick: () -> Unit) {
    Box(Modifier.size(size).clip(CircleShape).background(Palette.accent).clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(Icons.Default.PlayArrow, stringResource(R.string.play), tint = Color.Black, modifier = Modifier.size(size * 0.55f))
    }
}

/** Download state of a group of songs: arrow to start, ring while loading, check when done (tap removes). */
@Composable
fun DownloadButton(songs: List<Song>) {
    val context = LocalContext.current
    val all by Downloads.all.collectAsState()
    val account by context.tonalo.current.collectAsState()
    if (songs.isEmpty()) return
    val keys = songs.map { Downloads.key(account?.id ?: "", it.id) }
    val infos = keys.mapNotNull { all[it] }
    val done = infos.count { it.done }
    val loading = infos.size > done
    LaunchedEffect(loading) {
        while (loading) { Downloads.poll(context); delay(1000) }
    }
    IconButton(onClick = {
        if (done == songs.size || loading) Downloads.remove(context, songs.map { it.id }) else Downloads.download(context, songs)
    }) {
        when {
            done == songs.size -> Icon(Icons.Default.CheckCircle, stringResource(R.string.remove_download), tint = Palette.accent)
            loading -> {
                val progress = (done + infos.filter { !it.done }.sumOf { it.progress.toDouble() }.toFloat()) / songs.size
                CircularProgressIndicator(progress = { progress }, Modifier.size(22.dp), color = Palette.accent, strokeWidth = 2.5.dp, trackColor = Palette.elevated)
            }
            else -> Icon(Icons.Default.Download, stringResource(R.string.download), tint = Palette.secondaryText)
        }
    }
}

@Composable
fun SectionHeader(title: String, more: (() -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 28.dp, bottom = 12.dp), verticalAlignment = Alignment.Bottom) {
        Text(title, fontSize = 22.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
        if (more != null) Text(
            stringResource(R.string.show_all), Modifier.clickable(onClick = more).padding(start = 8.dp, bottom = 2.dp),
            color = Palette.secondaryText, fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
        )
    }
}

val HorizontalPadding = PaddingValues(horizontal = 16.dp)

/** An album in a shelf or grid: cover, name, "year • artist". `width` null fills the grid cell. */
@Composable
fun AlbumCard(album: app.tonalo.android.data.Album, width: Dp? = 150.dp) {
    val nav = LocalNav.current
    CoverCard(album.name, listOfNotNull(album.year?.toString(), album.artist).joinToString(" • "), album.coverArt, width) { nav.open(albumRoute(album.id)) }
}

@Composable
fun PlaylistCard(playlist: app.tonalo.android.data.Playlist, width: Dp? = 150.dp) {
    val nav = LocalNav.current
    CoverCard(playlist.name, pluralString(R.plurals.song_count, playlist.songCount ?: 0), playlist.coverArt, width,
        placeholder = Icons.AutoMirrored.Filled.QueueMusic) { nav.open(playlistRoute(playlist.id)) }
}

/** Round picture, name, "Artist" – "Fans also like". */
@Composable
fun ArtistCard(artist: app.tonalo.android.data.Artist) {
    val nav = LocalNav.current
    val scale = coverScale()
    Column(Modifier.width(140.dp * scale).clickable { nav.open(artistRoute(artist.id)) }) {
        Cover(artist.coverArt ?: "ar-${artist.id}", 140.dp * scale, corner = 70.dp * scale, pixels = 300, placeholder = Icons.Default.Person)
        Text(artist.name, Modifier.padding(top = 6.dp), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(stringResource(R.string.artist), fontSize = 13.sp, color = Palette.secondaryText)
    }
}

@Composable
fun coverScale(): Float {
    val size by LocalContext.current.tonalo.settings.coverSize.collectAsState()
    return size.scale
}

@Composable
private fun CoverCard(title: String, subtitle: String, coverArt: String?, width: Dp?, placeholder: ImageVector = Icons.Default.Album, onClick: () -> Unit) {
    val scale = coverScale()
    androidx.compose.foundation.layout.BoxWithConstraints(if (width != null) Modifier.width(width * scale) else Modifier.fillMaxWidth()) {
        val side = maxWidth
        Column(Modifier.fillMaxWidth().clickable(onClick = onClick)) {
            Cover(coverArt, side, corner = Palette.corner(4.dp), pixels = 300, placeholder = placeholder)
            Text(title, Modifier.padding(top = 6.dp), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (subtitle.isNotEmpty()) Text(subtitle, fontSize = 13.sp, color = Palette.secondaryText, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** The big round play/pause button in the accent color (black symbol). */
@Composable
fun PlayCircle(playing: Boolean, size: Dp = 52.dp, color: Color = Palette.accent, onClick: () -> Unit) {
    Box(Modifier.size(size).clip(CircleShape).background(color).clickable(onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(
            if (playing) Icons.Default.Pause else Icons.Default.PlayArrow,
            stringResource(if (playing) R.string.cd_pause else R.string.cd_play), tint = Color.Black,
            modifier = Modifier.size(size * 0.5f).padding(start = if (playing) 0.dp else size * 0.03f),
        )
    }
}

/** Shuffle icon plus the round play button, right-aligned like on album pages. */
@Composable
fun PlayButtons(playing: Boolean, play: () -> Unit, shuffle: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = shuffle) { Icon(Icons.Default.Shuffle, stringResource(R.string.shuffle), tint = Palette.secondaryText, modifier = Modifier.size(26.dp)) }
        Spacer(Modifier.width(12.dp))
        PlayCircle(playing, onClick = play)
    }
}
