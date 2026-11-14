package app.tonalo.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.ui.unit.sp
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.draw.clip
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.DropdownMenu
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Add
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.clickable
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.tonalo.android.R
import app.tonalo.android.data.Album
import app.tonalo.android.data.Genre
import app.tonalo.android.data.Station
import app.tonalo.android.downloads.BookDownloads
import app.tonalo.android.downloads.Downloads
import app.tonalo.android.tonalo
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Title bar of a page, with a back arrow when there is somewhere to go back to. */
@Composable
fun TopBar(title: String, back: Boolean = true, actions: @Composable () -> Unit = {}) {
    if (!back) {
        Row(
            Modifier.fillMaxWidth().statusBarsPadding().padding(start = 16.dp, end = 4.dp, top = 8.dp, bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(title, Modifier.weight(1f), maxLines = 1, overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
            actions()
        }
        return
    }
    // Like the iPhone: a round back button, the title small in the middle
    Box(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 12.dp, vertical = 8.dp).height(48.dp)) {
        GlassBackButton(Modifier.align(Alignment.CenterStart))
        Text(
            title, Modifier.align(Alignment.Center).padding(horizontal = 64.dp), maxLines = 1, overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold,
        )
        Row(Modifier.align(Alignment.CenterEnd), verticalAlignment = Alignment.CenterVertically) { actions() }
    }
}

/** All albums of the server, two columns, loaded page by page – with a sort menu, or of one genre. */
@Composable
fun AlbumsScreen(startType: String = "alphabeticalByName", genre: String? = null) {
    val context = LocalContext.current
    var type by rememberSaveable { mutableStateOf(startType) }
    // Pulling down starts the list again: a new generation, so an answer still on its way lands in the old list
    var gen by remember { mutableStateOf(0) }
    val albums = remember(type, gen) { mutableStateListOf<Album>() }
    var loading by remember(type, gen) { mutableStateOf(false) }
    var done by remember(type, gen) { mutableStateOf(false) }
    var error by remember(type, gen) { mutableStateOf<String?>(null) }
    val grid = rememberLazyGridState()
    val scope = rememberCoroutineScope()
    val sorts = listOf("alphabeticalByName" to R.string.sort_az, "alphabeticalByArtist" to R.string.artist, "newest" to R.string.recently_added,
        "recent" to R.string.recently_played, "frequent" to R.string.most_played, "random" to R.string.sort_random, "starred" to R.string.favorites)

    fun more() {
        if (loading || done) return
        loading = true
        scope.launch {
            try {
                val page = context.tonalo.client()?.albumList(type, size = 60, offset = albums.size, genre = genre).orEmpty()
                albums.addAll(page.filter { a -> albums.none { it.id == a.id } })
                if (page.size < 60) done = true
                error = null
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                error = errorText(context, e)
            } finally {
                loading = false
            }
        }
    }

    val nearEnd by remember(albums) { derivedStateOf { (grid.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0) >= albums.size - 12 } }
    LaunchedEffect(nearEnd, albums.size, type, gen) { if (nearEnd && error == null) more() }

    Column(Modifier.fillMaxSize()) {
        TopBar(genre ?: stringResource(R.string.albums)) {
            if (genre == null) {
                var open by remember { mutableStateOf(false) }
                Box {
                    IconButton(onClick = { open = true }) { Icon(Icons.Default.SwapVert, stringResource(R.string.sort)) }
                    DropdownMenu(open, { open = false }) {
                        sorts.forEach { (t, label) ->
                            DropdownMenuItem(text = { Text(stringResource(label)) },
                                leadingIcon = { if (t == type) Icon(Icons.Default.Check, null, tint = Palette.accent) else Spacer(Modifier.size(24.dp)) },
                                onClick = { open = false; type = t })
                        }
                    }
                }
            }
        }
        if (albums.isEmpty() && error != null) return@Column ErrorView(error!!) { error = null; more() }
        Refreshable(refreshing = loading, onRefresh = { gen++ }, modifier = Modifier.weight(1f).fillMaxWidth()) {
        LazyVerticalGrid(
            GridCells.Fixed(2), state = grid,
            contentPadding = PaddingValues(16.dp),
            horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            items(albums, key = { it.id }) { a -> AlbumCard(a, null) }
            error?.let { msg ->
                item(span = { GridItemSpan(maxLineSpan) }) {
                    Column(Modifier.fillMaxWidth().padding(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(msg, color = Palette.secondaryText)
                        TextButton(onClick = { error = null; more() }) { Text(stringResource(R.string.retry)) }
                    }
                }
            }
            if (loading) item(span = { GridItemSpan(maxLineSpan) }) {
                Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            }
        }
        }
    }
}

/** All artists of the server, with a filter field. */
@Composable
fun ArtistsScreen() {
    val nav = LocalNav.current
    val loader = rememberLoad("artists", cached = { c -> c.cached("getArtists")?.artists?.index?.flatMap { it.artist.orEmpty() } }) { it.artists() }
    var filter by rememberSaveable { mutableStateOf("") }
    Column(Modifier.fillMaxSize()) {
        TopBar(stringResource(R.string.artists))
        SearchField(filter, { filter = it }, stringResource(R.string.search), Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
        Refreshable(loader.refreshing, loader.reload, Modifier.weight(1f).fillMaxWidth()) {
        LoadView(loader) { artists ->
            val shown = if (filter.isBlank()) artists else artists.filter { it.name.contains(filter.trim(), ignoreCase = true) }
            LazyColumn(contentPadding = PaddingValues(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                items(shown, key = { it.id }) { a ->
                    ItemRow(a.name, stringResource(R.string.artist), onClick = { nav.open(artistRoute(a.id)) }) {
                        FillCover(a.coverArt ?: "ar-${a.id}", Modifier.size(64.dp), 32.dp, Icons.Default.Person)
                    }
                }
            }
        }
        }
    }
}

/** The gray rounded search field of lists (artists). */
@Composable
fun SearchField(value: String, onChange: (String) -> Unit, hint: String, modifier: Modifier = Modifier) {
    Row(
        modifier.fillMaxWidth().height(36.dp).clip(RoundedCornerShape(10.dp)).background(Palette.elevated).padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Default.Search, null, tint = Palette.secondaryText, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Box(Modifier.weight(1f)) {
            if (value.isEmpty()) Text(hint, color = Palette.subtle, fontSize = 15.sp)
            BasicTextField(value, onChange, Modifier.fillMaxWidth(), singleLine = true,
                textStyle = androidx.compose.ui.text.TextStyle(color = Color.White, fontSize = 15.sp), cursorBrush = SolidColor(Palette.accent))
        }
    }
}

/** Library-style row: a 64 dp picture, title, gray subtitle. */
@Composable
fun ItemRow(title: String, subtitle: String, onClick: () -> Unit, art: @Composable () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(64.dp)) { art() }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 16.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(subtitle, Modifier.padding(top = 4.dp), color = Palette.secondaryText, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** All playlists, two columns, and "+" for a new one. */
@Composable
fun PlaylistsScreen() {
    val context = LocalContext.current
    val snackbar = LocalSnackbar.current
    val scope = rememberCoroutineScope()
    var version by remember { mutableStateOf(0) }
    val plVersion by Playlists.version.collectAsState()
    val loader = rememberLoad("playlists", version, cached = { c -> c.cached("getPlaylists")?.playlists?.playlist }, refresh = plVersion) { it.playlists() }
    var naming by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }
    Column(Modifier.fillMaxSize()) {
        TopBar(stringResource(R.string.playlists)) {
            IconButton(onClick = { name = ""; naming = true }) { Icon(Icons.Default.Add, stringResource(R.string.new_playlist)) }
        }
        Refreshable(loader.refreshing, loader.reload, Modifier.weight(1f).fillMaxWidth()) {
        LoadView(loader) { all ->
            val lists = Playlists.visible(all)
            LazyColumn {
                item { CardGrid(lists.size) { i -> PlaylistCard(lists[i], null) } }
            }
        }
        }
    }
    if (naming) AlertDialog(
        onDismissRequest = { naming = false },
        containerColor = Palette.elevated,
        title = { Text(stringResource(R.string.new_playlist)) },
        text = { androidx.compose.material3.OutlinedTextField(name, { name = it }, singleLine = true, placeholder = { Text(stringResource(R.string.playlist_name)) }) },
        confirmButton = {
            TextButton(onClick = {
                naming = false
                val n = name.trim()
                if (n.isNotEmpty()) scope.launch {
                    try { context.tonalo.client()?.createPlaylist(n, emptyList()); version++; Playlists.changed() }
                    catch (e: CancellationException) { throw e } catch (e: Exception) { snackbar.showSnackbar(errorText(context, e)) }
                }
            }) { Text(stringResource(R.string.create)) }
        },
        dismissButton = { TextButton(onClick = { naming = false }) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
fun GenresScreen() {
    val nav = LocalNav.current
    val loader = rememberLoad("genres", cached = { c -> c.cached("getGenres")?.genres?.genre }) { c ->
        c.genres().filter { it.value.isNotBlank() && ((it.albumCount ?: 0) > 0 || (it.songCount ?: 0) > 0) }.sortedBy { it.value.lowercase() }
    }
    Column(Modifier.fillMaxSize()) {
        TopBar(stringResource(R.string.genres))
        LoadView(loader) { genres ->
            if (genres.isEmpty()) return@LoadView EmptyView()
            LazyColumn {
                items(genres, key = { it.value }) { g ->
                    ListRow(g.value, g.albumCount?.let { pluralString(R.plurals.album_count, it) }, showCover = false,
                        trailing = { Icon(Icons.Default.ChevronRight, null, tint = Palette.secondaryText) }) {
                        nav.open(genreRoute(g.value))
                    }
                }
            }
        }
    }
}

/** A genre: its albums, two columns (the iPhone's albums page for one genre). */
@Composable
fun GenreScreen(name: String) = AlbumsScreen("byGenre", genre = name)

@Composable
fun AlbumGrid(albums: List<Album>, header: (@Composable () -> Unit)? = null, onClick: (Album) -> Unit) {
    if (albums.isEmpty() && header == null) return EmptyView()
    LazyVerticalGrid(
        GridCells.Fixed(2),
        contentPadding = PaddingValues(16.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        header?.let { h -> item(span = { GridItemSpan(maxLineSpan) }) { h() } }
        items(albums, key = { it.id }) { a -> AlbumCard(a, null) }
    }
}

/** What's on the phone: storage, play buttons, what's still loading, albums and songs – like the iPhone's downloads page. */
@Composable
fun DownloadsScreen() {
    val context = LocalContext.current
    val nav = LocalNav.current
    val player = LocalPlayer.current
    val state by player.state.collectAsState()
    val all by Downloads.all.collectAsState()
    val account by context.tonalo.current.collectAsState()
    LaunchedEffect(Unit) { Downloads.manager(context) }
    // An account with audiobooks only: just the audiobooks and podcasts are downloaded here
    val hasMusic = account?.hasMusic != false
    val bookDownloads by BookDownloads.books.collectAsState()
    val bookStates by BookDownloads.states.collectAsState()
    val list = Downloads.forAccount(all, account?.id)
    val songs = list.filter { it.done }.map { it.song }.sortedWith(compareBy({ it.artist?.lowercase() }, { it.album?.lowercase() }, { it.discNumber ?: 0 }, { it.track ?: 0 }))
    val active = list.filter { !it.done && !it.failed }
    val failed = list.filter { it.failed }
    LaunchedEffect(active.isNotEmpty()) { while (active.isNotEmpty()) { Downloads.poll(context); delay(1000) } }
    val albums = songs.filter { it.albumId != null }.groupBy { it.albumId!! }
        .map { (id, l) -> Album(id, l.first().album ?: "", l.first().artist, coverArt = l.first().coverArt) }.sortedBy { it.name.lowercase() }
    val name = stringResource(R.string.downloads)
    val bytes = remember(songs.size) { runCatching { Downloads.cache(context).cacheSpace }.getOrDefault(0L) }
    var confirm by remember { mutableStateOf(false) }

    GroupedPage(name) {
        if (hasMusic) item {
            Group {
                ValueRow(stringResource(R.string.storage_used), android.text.format.Formatter.formatShortFileSize(context, bytes))
                ValueRow(stringResource(R.string.songs), songs.size.toString())
            }
            if (songs.isNotEmpty()) Row(Modifier.fillMaxWidth().padding(bottom = 22.dp), verticalAlignment = Alignment.CenterVertically) {
                Spacer(Modifier.weight(1f))
                PlayButtons(state.contextId == "downloads" && state.isPlaying,
                    play = { if (state.contextId == "downloads") player.toggle() else player.play(songs, context = name, contextId = "downloads") },
                    shuffle = { player.play(songs, shuffled = true, context = name, contextId = "downloads") })
            }
        }
        if (active.isNotEmpty()) item {
            Group(stringResource(R.string.downloading_n, active.size)) {
                active.forEach { d ->
                    GroupRow(icon = { Cover(d.song.coverArt, 44.dp, corner = 4.dp, pixels = 120) }, trailing = {
                        IconButton(onClick = { Downloads.remove(context, listOf(d.song.id)) }) { Icon(Icons.Default.Close, stringResource(R.string.cancel), tint = Palette.subtle) }
                    }) {
                        Text(d.song.title, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        LinearProgressIndicator(progress = { d.progress }, Modifier.fillMaxWidth().padding(top = 6.dp), color = Palette.accent, trackColor = Palette.elevated)
                    }
                }
                ActionRow(stringResource(R.string.cancel_all), destructive = true) { Downloads.remove(context, active.map { it.song.id }) }
            }
        }
        if (failed.isNotEmpty()) item {
            Group { ActionRow(stringResource(R.string.retry_failed, failed.size), Icons.Default.Refresh) { Downloads.download(context, failed.map { it.song }) } }
        }
        // The audiobooks and podcasts: storage, what is loading (with the combined progress), the finished ones
        bookDownloadItems(nav)
        if (albums.isNotEmpty()) item {
            Group(stringResource(R.string.albums)) {
                albums.forEach { a ->
                    NavRow(a.name, sub = a.artist, icon = { Cover(a.coverArt, 44.dp, corner = 4.dp, pixels = 120) }) { nav.open(albumRoute(a.id)) }
                }
            }
        }
        if (songs.isNotEmpty()) {
            item { Text(stringResource(R.string.songs), Modifier.padding(start = 16.dp, bottom = 8.dp), color = Palette.secondaryText, fontSize = 16.sp, fontWeight = FontWeight.SemiBold) }
            items(songs.size, key = { songs[it].id }) { i -> SongRow(songs[i], padded = false) { player.play(songs, i, context = name, contextId = "downloads") } }
            item { Spacer(Modifier.height(22.dp)); Group { ActionRow(stringResource(R.string.delete_all_downloads), destructive = true, centered = true) { confirm = true } } }
        }
        if (songs.isEmpty() && active.isEmpty() && bookDownloads.isEmpty() && bookStates.isEmpty()) item {
            Group { GroupBox { Text(stringResource(R.string.nothing_downloaded_home), color = Palette.secondaryText) } }
        }
    }
    if (confirm) AlertDialog(
        onDismissRequest = { confirm = false },
        containerColor = Palette.elevated,
        title = { Text(stringResource(R.string.delete_all_downloads_q)) },
        confirmButton = { TextButton(onClick = { Downloads.remove(context, songs.map { it.id }); confirm = false }) { Text(stringResource(R.string.delete_all_downloads), color = Color(0xFFFF5A5F)) } },
        dismissButton = { TextButton(onClick = { confirm = false }) { Text(stringResource(R.string.cancel)) } },
    )
}

/** Everything radio: the endless radios (all genres here) and the stations set up on the server, two columns. */
@Composable
fun RadioScreen() {
    val genres = rememberLoad("radio-genres", cached = { c -> c.cached("getGenres")?.genres?.genre }) { it.genres() }
    val stations = rememberLoad("radio-stations", cached = { c -> c.cached("getInternetRadioStations")?.internetRadioStations?.internetRadioStation }) { it.stations() }
    val genreList = radioGenres((genres.state as? Load.Ready<List<Genre>>)?.value.orEmpty())
    val stationList = (stations.state as? Load.Ready<List<Station>>)?.value.orEmpty()
    val stationsFailed = stations.state as? Load.Failed
    Column(Modifier.fillMaxSize()) {
        TopBar(stringResource(R.string.radio))
        Refreshable(genres.refreshing || stations.refreshing, { genres.reload(); stations.reload() }, Modifier.weight(1f).fillMaxWidth()) {
        androidx.compose.foundation.layout.BoxWithConstraints(Modifier.fillMaxSize()) {
            val size = maxOf(120.dp, (maxWidth - 32.dp - 14.dp) / 2)
            LazyColumn(contentPadding = PaddingValues(vertical = 16.dp)) {
                item {
                    Text(stringResource(R.string.endless_radio), Modifier.padding(horizontal = 16.dp), fontSize = 22.sp, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.height(12.dp))
                    WrapGrid(size) { RadioCards(genreList, size, wrap = true) }
                    Spacer(Modifier.height(28.dp))
                    Text(stringResource(R.string.stations), Modifier.padding(horizontal = 16.dp), fontSize = 22.sp, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.height(12.dp))
                    if (stations.state is Load.Ready && stationList.isEmpty()) Text(stringResource(R.string.no_stations), Modifier.padding(horizontal = 16.dp), color = Palette.secondaryText)
                    stationsFailed?.let { Text(it.message, Modifier.padding(horizontal = 16.dp), color = Palette.secondaryText) }
                    WrapGrid(size) { stationList.forEach { st -> StationTile(st, size) } }
                }
            }
        }
        }
    }
}

/** Fixed-size cards flowing in rows of two. */
@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
private fun WrapGrid(size: androidx.compose.ui.unit.Dp, content: @Composable () -> Unit) {
    androidx.compose.foundation.layout.FlowRow(
        Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(18.dp),
        maxItemsInEachRow = 2,
    ) { content() }
}

/** A station on the radio page: just its art; tap plays, tap again pauses. */
@Composable
private fun StationTile(station: Station, size: androidx.compose.ui.unit.Dp) {
    val scope = rememberCoroutineScope()
    val player = LocalPlayer.current
    val state by player.state.collectAsState()
    val live = state.station?.id == station.id
    Box(Modifier.size(size).clip(RoundedCornerShape(Palette.corner(4.dp))).clickable {
        if (live) player.toggle() else scope.launch { app.tonalo.android.playback.Playback.service?.playStation(station) }
    }) {
        StationArt(station)
        if (live) LiveBadge(state.isPlaying, Modifier.align(Alignment.TopStart).padding(8.dp))
    }
}
