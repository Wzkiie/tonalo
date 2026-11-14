package app.tonalo.android.ui

import androidx.compose.foundation.background
import androidx.compose.animation.core.animateFloat
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.tonalo.android.R
import app.tonalo.android.data.ABSShelf
import app.tonalo.android.data.Album
import app.tonalo.android.data.Genre
import app.tonalo.android.data.PlayQueue
import app.tonalo.android.data.Playlist
import app.tonalo.android.data.Station
import app.tonalo.android.data.SubsonicClient
import app.tonalo.android.data.localTitle
import app.tonalo.android.dj.DJ
import app.tonalo.android.downloads.Downloads
import app.tonalo.android.playback.Playback
import app.tonalo.android.tonalo
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** The album rows of the home page, in the iPhone's order; each can be switched off under Appearance. */
val homeRows = listOf(
    "recent" to R.string.recently_played,
    "newest" to R.string.recently_added,
    "frequent" to R.string.most_played,
    "random" to R.string.discover,
    "starred" to R.string.favorite_albums,
)

/** Queues from other devices already answered (taken or turned down) in this run of the app. */
private val answeredOffers = mutableSetOf<String>()

private enum class HomeFilter { ALL, PLAYLISTS, DOWNLOADS, BOOKS }

/** Goes up each time the open tab is tapped again: back to the top, filter off. */
val LocalReselect = androidx.compose.runtime.compositionLocalOf { 0 }

/**
 * Runs [action] when the tab was tapped again – not when the page comes back from a page above it
 * (the counter stays above 0 once it was used, so each page keeps the value it has handled).
 */
@Composable
fun OnReselect(action: suspend () -> Unit) {
    val reselect = LocalReselect.current
    var seen by androidx.compose.runtime.saveable.rememberSaveable { androidx.compose.runtime.mutableIntStateOf(reselect) }
    LaunchedEffect(reselect) { if (reselect != seen) { seen = reselect; action() } }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen() {
    val context = LocalContext.current
    val app = context.tonalo
    val nav = LocalNav.current
    val online by app.online.collectAsState()
    val hidden by app.settings.hiddenHomeRows.collectAsState()
    var filter by rememberSaveable { mutableStateOf(HomeFilter.ALL) }
    var refresh by remember { mutableIntStateOf(0) }
    val list = rememberLazyListState()
    OnReselect { filter = HomeFilter.ALL; list.animateScrollToItem(0) }

    val account by app.current.collectAsState()
    // An account with audiobooks only has no music server: no music rows, no music calls
    val hasMusic = account?.hasMusic != false
    val booksConnected by app.books.connected.collectAsState()
    val shelves by app.books.shelves.collectAsState()
    val scope = rememberCoroutineScope()
    var pulling by remember { mutableStateOf(false) }
    LaunchedEffect(account?.id, booksConnected) { if (booksConnected) app.books.load() }
    LaunchedEffect(booksConnected) { if (!booksConnected && filter == HomeFilter.BOOKS) filter = HomeFilter.ALL }

    val plVersion by Playlists.version.collectAsState()
    val playlists = if (hasMusic) rememberLoad("home-playlists", cached = { c -> c.cached("getPlaylists")?.playlists?.playlist }, refresh = refresh + plVersion) { it.playlists() } else null
    val rows = homeRows.filter { it.first !in hidden.split(",") }
    val lists = Playlists.visible((playlists?.state as? Load.Ready<List<Playlist>>)?.value.orEmpty())
    val continueListening = shelves.firstOrNull { it.id == ABSShelf.CONTINUE_LISTENING }?.items.orEmpty()
    val otherShelves = shelves.filter { it.id != ABSShelf.CONTINUE_LISTENING }

    Refreshable(refreshing = playlists?.refreshing == true || pulling, onRefresh = {
        refresh++
        if (booksConnected) scope.launch {
            pulling = true
            try { app.books.load(force = true) } finally { pulling = false }
        }
    }) {
        LazyColumn(Modifier.fillMaxSize(), state = list, contentPadding = PaddingValues(bottom = 24.dp)) {
            item {
                Row(
                    Modifier.fillMaxWidth().statusBarsPadding().padding(start = 16.dp, top = 8.dp, bottom = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Avatar(32.dp)
                    Spacer(Modifier.width(12.dp))
                    ChipRow {
                        if (hasMusic) {
                            Chip(stringResource(R.string.all), filter == HomeFilter.ALL) { filter = HomeFilter.ALL }
                            Chip(stringResource(R.string.playlists), filter == HomeFilter.PLAYLISTS) {
                                filter = if (filter == HomeFilter.PLAYLISTS) HomeFilter.ALL else HomeFilter.PLAYLISTS
                            }
                            Chip(stringResource(R.string.downloads), filter == HomeFilter.DOWNLOADS) {
                                filter = if (filter == HomeFilter.DOWNLOADS) HomeFilter.ALL else HomeFilter.DOWNLOADS
                            }
                        }
                        if (booksConnected) {
                            Chip(stringResource(R.string.bk_audiobooks), filter == HomeFilter.BOOKS || !hasMusic) {
                                if (hasMusic) filter = if (filter == HomeFilter.BOOKS) HomeFilter.ALL else HomeFilter.BOOKS
                            }
                        }
                    }
                }
            }
            if (!online) item { OfflineBanner() }
            if (!hasMusic) booksHomeItems(nav) else when (filter) {
                HomeFilter.BOOKS -> booksHomeItems(nav)
                HomeFilter.PLAYLISTS -> item {
                    if (lists.isEmpty()) EmptyNote(stringResource(R.string.no_playlists_yet))
                    else CardGrid(lists.size) { i -> PlaylistCard(lists[i], null) }
                }
                HomeFilter.DOWNLOADS -> item { DownloadGrid() }
                HomeFilter.ALL -> {
                    item(key = "quick") {
                        val recent = rememberLoad("home-recent", cached = { c -> c.cached("getAlbumList2", "type" to "recent", "size" to "20", "offset" to "0")?.albumList2?.album }, refresh = refresh) {
                            it.albumList("recent", size = 20)
                        }
                        QuickGrid(lists, (recent.state as? Load.Ready<List<Album>>)?.value.orEmpty())
                    }
                    if (continueListening.isNotEmpty()) item(key = "books-continue") {
                        BookShelf(stringResource(R.string.books_shelf_continue_listening), continueListening)
                    }
                    item(key = "mixes") { Mixes() }
                    item(key = "radio") { RadioShelf(refresh) }
                    if (lists.isNotEmpty()) item(key = "playlists") {
                        SectionHeader(stringResource(R.string.your_playlists)) { nav.open("playlists") }
                        LazyRow(contentPadding = HorizontalPadding, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                            items(lists, key = { it.id }) { PlaylistCard(it) }
                        }
                    }
                    // Music and audiobooks take turns, it's one home page
                    rows.forEachIndexed { index, (type, title) ->
                        item(key = type) {
                            val loader = rememberLoad("home-$type", cached = { c -> c.cached("getAlbumList2", "type" to type, "size" to "20", "offset" to "0")?.albumList2?.album }, refresh = refresh) { c ->
                                c.albumList(type, size = 20)
                            }
                            val albums = (loader.state as? Load.Ready<List<Album>>)?.value
                            if (!albums.isNullOrEmpty()) {
                                SectionHeader(stringResource(title)) { nav.open("albums/$type") }
                                LazyRow(contentPadding = HorizontalPadding, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                                    items(albums, key = { it.id }) { a -> AlbumCard(a) }
                                }
                            }
                        }
                        otherShelves.getOrNull(index)?.let { shelf ->
                            item(key = "books-shelf-" + shelf.id) { BookShelf(shelf.localTitle(context), shelf.items) }
                        }
                    }
                    otherShelves.drop(rows.size).forEach { shelf ->
                        item(key = "books-shelf-" + shelf.id) { BookShelf(shelf.localTitle(context), shelf.items) }
                    }
                }
            }
        }
    }
}

@Composable
private fun EmptyNote(text: String) =
    Text(text, Modifier.padding(16.dp), color = Palette.secondaryText, fontSize = 15.sp)

/** Two columns of big cards (the playlists and downloads filters). */
@Composable
fun CardGrid(count: Int, card: @Composable (Int) -> Unit) {
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        (0 until count).chunked(2).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                row.forEach { i -> Box(Modifier.weight(1f)) { card(i) } }
                if (row.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

/** "You're offline – your downloads still work." */
@Composable
fun OfflineBanner() {
    Row(
        Modifier.padding(horizontal = 16.dp, vertical = 8.dp).fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Palette.elevated).padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Default.WifiOff, null, tint = Palette.secondaryText)
        Spacer(Modifier.width(12.dp))
        Column {
            Text(stringResource(R.string.offline_title), fontWeight = FontWeight.Bold, fontSize = 15.sp)
            Text(stringResource(R.string.offline_info), color = Palette.secondaryText, fontSize = 12.sp)
        }
    }
}

/** Everything downloaded: all songs first, the favorites, then the albums the songs belong to. */
@Composable
private fun DownloadGrid() {
    val context = LocalContext.current
    val nav = LocalNav.current
    val all by Downloads.all.collectAsState()
    val account by context.tonalo.current.collectAsState()
    val songs = Downloads.forAccount(all, account?.id).filter { it.done }.map { it.song }
    if (songs.isEmpty()) return EmptyNote(stringResource(R.string.nothing_downloaded_home))
    val favorites = songs.count { it.starred != null }
    val albums = songs.filter { it.albumId != null }.groupBy { it.albumId!! }.map { (id, s) ->
        Album(id, s.first().album ?: "", s.first().artist, coverArt = s.first().coverArt)
    }.sortedBy { it.name.lowercase() }
    val cards = buildList<@Composable () -> Unit> {
        add { CollectionCard(stringResource(R.string.downloads), pluralString(R.plurals.song_count, songs.size), { DownloadsArt() }) { nav.open("downloads") } }
        if (favorites > 0) add { CollectionCard(stringResource(R.string.favorite_songs), stringResource(R.string.n_downloaded, favorites), { FavoritesArt() }) { nav.open("favorites") } }
        albums.forEach { a -> add { AlbumCard(a, null) } }
    }
    CardGrid(cards.size) { cards[it]() }
}

/** Big tile like a playlist card, for the built-in collections (favorites, downloads). */
@Composable
fun CollectionCard(title: String, subtitle: String, art: @Composable () -> Unit, onClick: () -> Unit) {
    Column(Modifier.fillMaxWidth().clickable(onClick = onClick)) {
        Box(Modifier.fillMaxWidth().aspectRatio(1f).clip(RoundedCornerShape(Palette.corner(4.dp)))) { art() }
        Text(title, Modifier.padding(top = 6.dp), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(subtitle, color = Palette.secondaryText, fontSize = 12.sp, maxLines = 1)
    }
}

/** The DJ, then two columns of small tiles: favorite songs, a few playlists, recently played albums. */
@Composable
private fun QuickGrid(playlists: List<Playlist>, albums: List<Album>) {
    val nav = LocalNav.current
    val djOn by DJ.enabled.collectAsState()
    val state by LocalPlayer.current.state.collectAsState()
    val tiles = buildList<Triple<String, @Composable () -> Unit, String>> {
        add(Triple(stringResource(R.string.favorite_songs), { FavoritesArt() }, "favorites"))
        playlists.take(3).forEach { p -> add(Triple(p.name, { Cover(p.coverArt, 56.dp, corner = 0.dp, pixels = 120, placeholder = Icons.AutoMirrored.Filled.QueueMusic) }, playlistRoute(p.id))) }
        albums.forEach { a -> add(Triple(a.name, { Cover(a.coverArt, 56.dp, corner = 0.dp, pixels = 120) }, albumRoute(a.id))) }
    }.take(8)
    // The tile of what plays right now (the player's context id: favorites, a playlist "p<id>", an album "a<id>")
    fun isCurrent(route: String): Boolean {
        val cid = state.contextId ?: return false
        return when {
            route == "favorites" -> cid == "favorites"
            route.startsWith("playlist/") -> cid.startsWith("p") && route == playlistRoute(cid.drop(1))
            route.startsWith("album/") -> cid.startsWith("a") && route == albumRoute(cid.drop(1))
            else -> false
        }
    }
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (djOn && DJ.configured) DJHomeTile()
        tiles.chunked(2).forEach { row ->
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                row.forEach { (title, art, route) -> QuickTile(title, Modifier.weight(1f), current = isCurrent(route), playing = state.isPlaying, art = art) { nav.open(route) } }
                if (row.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

/** Starts the DJ with a fresh set – or opens the player, if the DJ plays right now. */
@Composable
fun rememberDJStarter(): () -> Unit {
    val context = LocalContext.current
    val nav = LocalNav.current
    val player = LocalPlayer.current
    val snackbar = LocalSnackbar.current
    val scope = rememberCoroutineScope()
    val state by player.state.collectAsState()
    return {
        if (state.context == "DJ" && state.isPlaying) nav.open("player")
        else if (!DJ.busy.value) scope.launch {
            try { DJ.start() } catch (e: CancellationException) { throw e } catch (e: Exception) { snackbar.showSnackbar(djMessage(context, e)) }
        }
    }
}

/** The DJ at the top of the home page, for people who turned it on. */
@Composable
private fun DJHomeTile() {
    val player = LocalPlayer.current
    val state by player.state.collectAsState()
    val busy by DJ.busy.collectAsState()
    val line by DJ.line.collectAsState()
    val playing = state.context == "DJ" && state.isPlaying
    val start = rememberDJStarter()
    Row(
        Modifier.fillMaxWidth().height(56.dp).clip(RoundedCornerShape(Palette.corner(4.dp))).background(Palette.elevated).clickable(onClick = start),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(56.dp)) { AnimatedDJArt(playing) }
        Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
            Text("DJ", fontWeight = FontWeight.Bold, fontSize = 14.sp)
            Text(
                if (playing) line ?: stringResource(R.string.dj_playing_now) else stringResource(R.string.dj_tile),
                color = Palette.secondaryText, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
        Box(Modifier.width(44.dp), contentAlignment = Alignment.Center) {
            if (busy) CircularProgressIndicator(Modifier.size(18.dp), color = Palette.secondaryText, strokeWidth = 2.dp)
            else if (playing) PlayingBars(true, Modifier.size(width = 18.dp, height = 16.dp))
            else Icon(Icons.Default.PlayArrow, null, tint = Palette.accent, modifier = Modifier.size(20.dp))
        }
    }
}

@Composable
private fun Mixes() {
    val context = LocalContext.current
    val player = LocalPlayer.current
    val client = { context.tonalo.client() }
    val snackbar = LocalSnackbar.current
    // Network failures of a mix show as a message instead of nothing
    suspend fun <R> attempt(block: suspend () -> R): R? = try {
        block()
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        snackbar.showSnackbar(errorText(context, e)); null
    }
    SectionHeader(stringResource(R.string.made_for_you))
    LazyRow(contentPadding = HorizontalPadding, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        item {
            val name = stringResource(R.string.shuffle_mix)
            MixCard(name, stringResource(R.string.shuffle_mix_info), 0.62f, Icons.Default.Shuffle) {
                attempt { client()?.randomSongs(150) }?.let { player.play(it, context = name) }
            }
        }
        item {
            val name = stringResource(R.string.favorite_songs)
            MixCard(stringResource(R.string.favorites_mix), stringResource(R.string.favorites_mix_info), 0.92f, Icons.Default.Favorite) {
                attempt { client()?.starred()?.song }?.takeIf { it.isNotEmpty() }?.let { player.play(it, shuffled = true, context = name) }
            }
        }
        item {
            val name = stringResource(R.string.discover)
            MixCard(name, stringResource(R.string.discover_info), 0.12f, Icons.Default.AutoAwesome) {
                val c = client() ?: return@MixCard
                val albums = attempt { c.albumList("random", size = 6) } ?: return@MixCard
                val songs = albums.flatMap { a -> try { c.album(a.id).song.orEmpty() } catch (e: CancellationException) { throw e } catch (e: Exception) { emptyList() }.shuffled().take(4) }
                if (songs.isNotEmpty()) player.play(songs.shuffled(), context = name)
            }
        }
    }
}

/** Endless radios first (the DJ, your favorites, the artist playing now, the biggest genres), then the server's stations. */
@Composable
private fun RadioShelf(refresh: Int) {
    val nav = LocalNav.current
    val genres = rememberLoad("radio-genres", cached = { c -> c.cached("getGenres")?.genres?.genre }, refresh = refresh) { it.genres() }
    val stations = rememberLoad("radio-stations", cached = { c -> c.cached("getInternetRadioStations")?.internetRadioStations?.internetRadioStation }, refresh = refresh) { it.stations() }
    val stationList = (stations.state as? Load.Ready<List<Station>>)?.value.orEmpty()
    SectionHeader(stringResource(R.string.radio)) { nav.open("radio") }
    LazyRow(contentPadding = HorizontalPadding, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        item { RadioCards(radioGenres((genres.state as? Load.Ready<List<Genre>>)?.value.orEmpty()).take(4), size = 130.dp) }
        items(stationList, key = { "st-" + it.id }) { st -> StationCard(st, stationList, 130.dp) }
    }
}

/** Genres with enough songs for a radio that doesn't repeat itself, biggest first. */
fun radioGenres(genres: List<Genre>) = genres.filter { (it.songCount ?: 0) >= 20 }.sortedByDescending { it.songCount ?: 0 }

fun topGenres(genres: List<Genre>, count: Int) = radioGenres(genres).take(count)

/** The endless radios: the DJ, your favorites, the artist playing now, and one per genre. */
@Composable
fun RadioCards(genres: List<Genre>, size: Dp, wrap: Boolean = false) {
    val context = LocalContext.current
    val player = LocalPlayer.current
    val snackbar = LocalSnackbar.current
    val state by player.state.collectAsState()
    val djOn by DJ.enabled.collectAsState()
    suspend fun start(block: suspend () -> Boolean) { if (!block()) snackbar.showSnackbar(context.getString(R.string.radio_failed)) }
    // In a grid the cards flow on their own; in a shelf they sit in one row
    val holder: @Composable (@Composable () -> Unit) -> Unit = if (wrap) { c -> c() } else { c -> Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) { c() } }
    holder {
        if (djOn && DJ.configured) MixCard("DJ", stringResource(R.string.dj_tile), 0.88f, Icons.Default.AutoAwesome, size) {
            try { DJ.start() } catch (e: CancellationException) { throw e } catch (e: Exception) { snackbar.showSnackbar(djMessage(context, e)) }
        }
        val yours = stringResource(R.string.your_radio)
        MixCard(yours, stringResource(R.string.your_radio_info), 0.52f, Icons.Default.Sensors, size) {
            start {
                val favs = runCatching { context.tonalo.client()?.starred()?.song }.getOrNull().orEmpty().shuffled().take(8)
                Playback.service?.startRadio(yours, seeds = favs, seedId = favs.firstOrNull()?.id) ?: false
            }
        }
        val song = if (state.station == null) state.current else null
        song?.artist?.let { artist ->
            val name = stringResource(R.string.more_like, artist)
            MixCard(name, stringResource(R.string.more_like_info), 0.75f, Icons.Default.Mic, size) {
                start { Playback.service?.startRadio(name, seedId = song.artistId ?: song.id, seeds = listOf(song)) ?: false }
            }
        }
        genres.forEach { g ->
            MixCard(g.value, stringResource(R.string.genre_radio), stableHue(g.value), Icons.Default.Sensors, size) {
                start { Playback.service?.startRadio(g.value, genre = g.value) ?: false }
            }
        }
    }
}

/** A station: its own color with the name on it. Tap to play, tap again to pause. */
@Composable
fun StationCard(station: Station, all: List<Station>, size: Dp) {
    val scope = rememberCoroutineScope()
    val player = LocalPlayer.current
    val state by player.state.collectAsState()
    val live = state.station?.id == station.id
    Column(Modifier.width(size).clickable { if (live) player.toggle() else scope.launch { Playback.service?.playStation(station) } }) {
        Box(Modifier.size(size).clip(RoundedCornerShape(Palette.corner(4.dp)))) {
            StationArt(station)
            if (live) LiveBadge(state.isPlaying, Modifier.align(Alignment.TopStart).padding(8.dp))
        }
        Text(
            if (live) state.liveTitle ?: stringResource(R.string.live_radio) else stringResource(R.string.live_radio),
            Modifier.padding(top = 6.dp), fontSize = 13.sp, color = if (live) Palette.accent else Palette.secondaryText,
            maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
    }
}

/** Stations have no cover on the server: a gradient of their own, the name on it. */
@Composable
fun StationArt(station: Station, modifier: Modifier = Modifier.fillMaxSize(), big: Boolean = false) {
    androidx.compose.foundation.layout.BoxWithConstraints(modifier.background(hueGradient(stableHue(station.name), 0.3f))) {
        val small = maxWidth < 80.dp
        Icon(
            Icons.Default.Sensors, null, tint = Color.White.copy(alpha = if (small) 0.9f else 0.75f),
            modifier = if (small) Modifier.align(Alignment.Center).size(maxWidth * 0.4f)
            else Modifier.align(Alignment.TopEnd).padding(if (big) 18.dp else 6.dp).size(if (big) 30.dp else 14.dp),
        )
        if (!small) Text(
            station.name, Modifier.align(Alignment.BottomStart).padding(if (big) 20.dp else 8.dp),
            fontWeight = FontWeight.ExtraBold, fontSize = if (big) 30.sp else 14.sp, lineHeight = if (big) 32.sp else 16.sp,
            color = Color.White, maxLines = if (big) 3 else 2, overflow = TextOverflow.Ellipsis,
        )
    }
}

/** Small "LIVE" tag, with a pulsing dot while it plays. */
@Composable
fun LiveBadge(playing: Boolean, modifier: Modifier = Modifier) {
    val pulse = androidx.compose.animation.core.rememberInfiniteTransition(label = "live")
    val alpha by pulse.animateFloat(
        1f, if (playing) 0.3f else 1f,
        androidx.compose.animation.core.infiniteRepeatable(androidx.compose.animation.core.tween(900), androidx.compose.animation.core.RepeatMode.Reverse),
        label = "dot",
    )
    Row(modifier.clip(CircleShape).background(Color.Black.copy(alpha = 0.55f)).padding(horizontal = 6.dp, vertical = 3.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(6.dp).clip(CircleShape).background(Color.Red.copy(alpha = alpha)))
        Spacer(Modifier.width(4.dp))
        Text(stringResource(R.string.live).uppercase(), fontSize = 9.sp, fontWeight = FontWeight.Black, color = Color.White, letterSpacing = 0.5.sp)
    }
}

/**
 * "Continue from …": another device (the TV, the iPhone, the desktop app) saved its queue on the server after
 * this phone – one tap plays it here, from the same song and second. Sits above the mini player.
 */
@Composable
fun ContinueBanner() {
    val context = LocalContext.current
    val player = LocalPlayer.current
    val state by player.state.collectAsState()
    val account by context.tonalo.current.collectAsState()
    var offer by remember(account?.id) { mutableStateOf<PlayQueue?>(null) }

    LaunchedEffect(account?.id) {
        if (!context.tonalo.settings.syncQueue.value) return@LaunchedEffect
        val q = context.tonalo.client()?.playQueue() ?: return@LaunchedEffect
        val key = q.changed ?: return@LaunchedEffect
        if (q.entry.isNullOrEmpty() || q.changedBy == SubsonicClient.CLIENT_NAME || key in answeredOffers) return@LaunchedEffect
        if (state.isPlaying && state.current?.id == q.current) return@LaunchedEffect
        offer = q
    }

    val q = offer ?: return
    val song = q.entry?.firstOrNull { it.id == q.current } ?: q.entry?.firstOrNull() ?: return
    fun answer() { q.changed?.let { answeredOffers += it }; offer = null }

    Row(
        Modifier.padding(horizontal = 10.dp, vertical = 4.dp).fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Palette.elevated)
            .padding(start = 8.dp, end = 4.dp, top = 8.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Cover(song.coverArt, 40.dp, corner = 6.dp, pixels = 120)
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f)) {
            Text(
                q.changedBy?.let { stringResource(R.string.continue_from, it) } ?: stringResource(R.string.continue_from_unknown),
                color = Palette.accent, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, maxLines = 1,
            )
            Text(listOfNotNull(song.title, song.artist).joinToString(" · "), fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Box(
            Modifier.size(34.dp).clip(CircleShape).background(Palette.accent).clickable {
                val songs = q.entry.orEmpty()
                player.play(songs, start = songs.indexOfFirst { it.id == q.current }.coerceAtLeast(0), positionMs = q.position ?: 0)
                answer()
            },
            contentAlignment = Alignment.Center,
        ) { Icon(Icons.Default.PlayArrow, stringResource(R.string.continue_action), tint = Color.Black, modifier = Modifier.size(20.dp)) }
        Box(Modifier.size(width = 34.dp, height = 34.dp).clickable { answer() }, contentAlignment = Alignment.Center) {
            Icon(Icons.Default.Close, stringResource(R.string.not_now), tint = Palette.secondaryText, modifier = Modifier.size(16.dp))
        }
    }
}
