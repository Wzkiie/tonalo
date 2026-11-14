package app.tonalo.android.ui

import android.content.Context
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
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
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.ArrowCircleDown
import androidx.compose.material.icons.filled.Book
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.filled.ViewModule
import androidx.compose.material.icons.outlined.PushPin
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.tonalo.android.R
import app.tonalo.android.data.ABSAuthor
import app.tonalo.android.data.ABSItem
import app.tonalo.android.data.Album
import app.tonalo.android.data.Artist
import app.tonalo.android.data.LibrarySort
import app.tonalo.android.data.Playlist
import app.tonalo.android.data.SearchBody
import app.tonalo.android.dj.DJ
import app.tonalo.android.downloads.BookDownloads
import app.tonalo.android.downloads.Downloads
import app.tonalo.android.tonalo

private enum class LibFilter { PLAYLISTS, ALBUMS, ARTISTS, DOWNLOADS, BOOKS, PODCASTS }

/** One entry of the library, whatever it is. */
private sealed class LibItem(val id: String) {
    data object DJItem : LibItem("dj")
    data object Favorites : LibItem("favorites")
    data object DownloadsItem : LibItem("downloads")
    data class P(val p: Playlist) : LibItem("p" + p.id)
    data class A(val a: Album) : LibItem("a" + a.id)
    data class R(val a: Artist) : LibItem("r" + a.id)
    /** An audiobook or podcast with a heart (or downloaded); [added] is when, in milliseconds, 0 if unknown. */
    data class B(val b: ABSItem, val added: Long) : LibItem("b" + b.id)
    /** An author with a heart. */
    data class U(val u: ABSAuthor, val added: Long) : LibItem("u" + u.id)

    val name: String get() = when (this) { is P -> p.name; is A -> a.name; is R -> a.name; is B -> b.title; is U -> u.name; else -> "" }
    val creator: String get() = when (this) { is P -> p.owner ?: ""; is A -> a.artist ?: ""; is R -> a.name; is B -> b.creator; is U -> u.name; else -> "" }
    /** When it was added or changed (ISO date from the server, sorts as text). */
    val date: String get() = when (this) {
        is P -> p.changed ?: ""; is A -> a.starred ?: ""; is R -> a.starred ?: ""
        is B -> isoDate(added); is U -> isoDate(added)
        else -> ""
    }
    val alwaysPinned: Boolean get() = this is DJItem || this is Favorites || this is DownloadsItem
}

/** A time in milliseconds as an ISO date, so it sorts as text next to the server's dates; empty for 0. */
private fun isoDate(ms: Long): String =
    if (ms <= 0) "" else java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", java.util.Locale.US).apply { timeZone = java.util.TimeZone.getTimeZone("UTC") }.format(java.util.Date(ms))

/** What you pinned to the top, newest first – on this phone, per account. */
private fun pinsKey(account: String?) = "library.pins.${account ?: ""}"
private fun loadPins(context: Context, account: String?): List<String> =
    context.getSharedPreferences("settings", Context.MODE_PRIVATE).getString(pinsKey(account), null)?.split(",")?.filter { it.isNotEmpty() }.orEmpty()
private fun savePins(context: Context, account: String?, pins: List<String>) =
    context.getSharedPreferences("settings", Context.MODE_PRIVATE).edit().putString(pinsKey(account), pins.joinToString(",")).apply()

/**
 * Your Library, like the iPhone's: the DJ and your favorite songs on top, then your playlists and the albums and
 * artists with a heart. Chips narrow it down, the sort order, a search and list or grid sit above.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun LibraryScreen() {
    val context = LocalContext.current
    val app = context.tonalo
    val nav = LocalNav.current
    val account by app.current.collectAsState()
    val sort by app.settings.librarySort.collectAsState()
    val grid by app.settings.libraryGrid.collectAsState()
    val online by app.online.collectAsState()
    val djOn by DJ.enabled.collectAsState()
    val downloads by Downloads.all.collectAsState()
    val player = LocalPlayer.current
    val state by player.state.collectAsState()
    val djLine by DJ.line.collectAsState()
    var filter by rememberSaveable(account?.id) { mutableStateOf<LibFilter?>(null) }
    var query by rememberSaveable { mutableStateOf("") }
    var searching by rememberSaveable { mutableStateOf(false) }
    val pins = remember(account?.id) { mutableStateListOf<String>().apply { addAll(loadPins(context, account?.id)) } }
    val list = rememberLazyListState()
    OnReselect { filter = null; query = ""; searching = false; list.animateScrollToItem(0) }

    // An account with audiobooks only has no music server: no music entries, no music calls
    val hasMusic = account?.hasMusic != false
    val booksConnected by app.books.connected.collectAsState()
    val bookLibraries by app.books.libraries.collectAsState()
    val bookFavorites by app.books.favorites.collectAsState()
    val authorFavorites by app.books.favoriteAuthors.collectAsState()
    val bookProgress by app.books.progress.collectAsState()
    val bookDownloads by BookDownloads.books.collectAsState()
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var pulling by remember { mutableStateOf(false) }
    LaunchedEffect(account?.id, booksConnected) { if (booksConnected) app.books.load() }
    LaunchedEffect(booksConnected) { if (!booksConnected && (filter == LibFilter.BOOKS || filter == LibFilter.PODCASTS)) filter = null }

    val plVersion by Playlists.version.collectAsState()
    val playlistsLoad = if (hasMusic) rememberLoad("lib-playlists", cached = { c -> c.cached("getPlaylists")?.playlists?.playlist }, refresh = plVersion) { it.playlists() } else null
    val hearts = Favorites.overrides.collectAsState().value.filterValues { it }.keys.sorted().hashCode()
    val starredLoad = if (hasMusic) rememberLoad("lib-starred", cached = { c -> c.cached("getStarred2")?.starred2 }, refresh = hearts) { it.starred() } else null
    val playlists = Playlists.visible((playlistsLoad?.state as? Load.Ready<List<Playlist>>)?.value.orEmpty())
    val starred = (starredLoad?.state as? Load.Ready<SearchBody>)?.value
    val downloaded = Downloads.forAccount(downloads, account?.id).filter { it.done }
    val downloadedFavorites = downloaded.count { d -> starred?.song.orEmpty().any { it.id == d.song.id } || d.song.starred != null }
    val downloadedAlbums = downloaded.filter { it.song.albumId != null }.groupBy { it.song.albumId!! }
        .map { (id, l) -> Album(id, l.first().song.album ?: "", l.first().song.artist, coverArt = l.first().song.coverArt) }

    val history = remember(account?.id, state.current?.id) { app.history.dates(account?.id) }
    // When it was last played: music from what this phone noted, audiobooks from the server's progress
    fun lastPlayed(item: LibItem): Long = when (item) {
        is LibItem.B -> (bookProgress[item.b.id]?.lastUpdate ?: 0.0).toLong()
        is LibItem.U -> 0L
        else -> history[item.id] ?: 0L
    }
    // The books with a heart, like the albums and artists with one; their authors count as artists too
    fun bookEntries(wanted: (ABSItem) -> Boolean): List<LibItem> =
        if (!booksConnected) emptyList() else bookFavorites.values.filter { wanted(it.item) }.map { LibItem.B(it.item, it.date) }
    val authorEntries: List<LibItem> = if (!booksConnected) emptyList() else authorFavorites.values.map { LibItem.U(it.author, it.date) }
    fun sorted(items: List<LibItem>): List<LibItem> = when (sort) {
        LibrarySort.PLAYED -> items.withIndex().sortedWith(compareByDescending<IndexedValue<LibItem>> { lastPlayed(it.value) }
            .thenByDescending { it.value.date }.thenBy { it.index }).map { it.value }
        LibrarySort.RECENT -> items.withIndex().sortedWith(compareByDescending<IndexedValue<LibItem>> { it.value.date }.thenBy { it.index }).map { it.value }
        LibrarySort.NAME -> items.sortedBy { it.name.lowercase() }
        LibrarySort.CREATOR -> items.sortedWith(compareBy({ it.creator.lowercase() }, { it.name.lowercase() }))
    }

    val pinned: List<LibItem>
    val rest: List<LibItem>
    when (filter) {
        null -> {
            pinned = if (hasMusic) (if (djOn && DJ.configured && online) listOf(LibItem.DJItem) else emptyList()) + LibItem.Favorites else emptyList()
            val music: List<LibItem> = if (hasMusic) playlists.map { LibItem.P(it) } + starred?.album.orEmpty().map { LibItem.A(it) } + starred?.artist.orEmpty().map { LibItem.R(it) } else emptyList()
            rest = music + bookEntries { true } + authorEntries
        }
        LibFilter.PLAYLISTS -> { pinned = listOf(LibItem.Favorites); rest = playlists.map { LibItem.P(it) } }
        LibFilter.ALBUMS -> { pinned = emptyList(); rest = starred?.album.orEmpty().map { LibItem.A(it) } }
        LibFilter.ARTISTS -> { pinned = emptyList(); rest = starred?.artist.orEmpty().map { LibItem.R(it) } + authorEntries }
        LibFilter.DOWNLOADS -> {
            pinned = if (!hasMusic) emptyList() else listOf(LibItem.DownloadsItem) + if (downloadedFavorites > 0) listOf(LibItem.Favorites) else emptyList()
            rest = downloadedAlbums.map { LibItem.A(it) } + bookDownloads.map { LibItem.B(it.item, 0L) }
        }
        LibFilter.BOOKS -> { pinned = emptyList(); rest = bookEntries { !it.isPodcast } + authorEntries }
        LibFilter.PODCASTS -> { pinned = emptyList(); rest = bookEntries { it.isPodcast } }
    }
    val all = sorted(rest)
    val top = pins.mapNotNull { id -> all.firstOrNull { it.id == id } }
    val ordered = top + all.filter { it.id !in pins }
    val q = query.trim()
    val items = if (q.isEmpty()) pinned + ordered
    else ordered.filter { it.name.contains(q, ignoreCase = true) || it.creator.contains(q, ignoreCase = true) }

    fun isPinned(item: LibItem) = item.alwaysPinned || item.id in pins
    fun togglePin(item: LibItem) {
        if (item.id in pins) pins.remove(item.id) else pins.add(0, item.id)
        savePins(context, account?.id, pins.toList())
    }
    val djStart = rememberDJStarter()
    fun open(item: LibItem) = when (item) {
        LibItem.DJItem -> djStart()
        LibItem.Favorites -> nav.open("favorites")
        LibItem.DownloadsItem -> nav.open("downloads")
        is LibItem.P -> nav.open(playlistRoute(item.p.id))
        is LibItem.A -> nav.open(albumRoute(item.a.id))
        is LibItem.R -> nav.open(artistRoute(item.a.id))
        is LibItem.B -> nav.open(bookRoute(item.b.id))
        is LibItem.U -> nav.open(bookAuthorRoute(item.u.id))
    }
    @Composable
    fun title(item: LibItem) = when (item) {
        LibItem.DJItem -> "DJ"
        LibItem.Favorites -> stringResource(R.string.favorite_songs)
        LibItem.DownloadsItem -> stringResource(R.string.downloads)
        else -> item.name
    }
    @Composable
    fun subtitle(item: LibItem): String = when (item) {
        LibItem.DJItem -> if (state.context == "DJ" && state.isPlaying) djLine ?: stringResource(R.string.dj_playing_now) else stringResource(R.string.dj_tile)
        LibItem.Favorites -> if (filter == LibFilter.DOWNLOADS) stringResource(R.string.n_of_m_downloaded, downloadedFavorites, starred?.song?.size ?: 0)
            else stringResource(R.string.playlist) + " • " + pluralString(R.plurals.song_count, starred?.song?.size ?: 0)
        LibItem.DownloadsItem -> pluralString(R.plurals.song_count, downloaded.size)
        is LibItem.P -> listOfNotNull(stringResource(R.string.playlist), item.p.owner).joinToString(" • ")
        is LibItem.A -> listOfNotNull(stringResource(R.string.album), item.a.artist).joinToString(" • ")
        is LibItem.R -> stringResource(R.string.artist)
        is LibItem.B -> listOfNotNull(
            if (bookProgress[item.b.id]?.isFinished == true) stringResource(R.string.bk_finished) else null,
            stringResource(if (item.b.isPodcast) R.string.bk_podcast else R.string.bk_audiobook),
            item.b.creator.ifEmpty { null },
        ).joinToString(" • ")
        is LibItem.U -> stringResource(R.string.bk_author)
    }
    @Composable
    fun art(item: LibItem, size: androidx.compose.ui.unit.Dp?) {
        val m = if (size != null) Modifier.size(size) else Modifier.fillMaxWidth().aspectRatio(1f)
        when (item) {
            LibItem.DJItem -> Box(m) { DJArt() }
            LibItem.Favorites -> Box(m) { FavoritesArt() }
            LibItem.DownloadsItem -> Box(m) { DownloadsArt() }
            is LibItem.P -> FillCover(item.p.coverArt, m, Palette.corner(2.dp), Icons.AutoMirrored.Filled.QueueMusic)
            is LibItem.A -> FillCover(item.a.coverArt, m, Palette.corner(2.dp))
            is LibItem.R -> FillCover(item.a.coverArt ?: "ar-${item.a.id}", m, 999.dp, Icons.Default.Person)
            is LibItem.B -> Box(m) {
                BookCover(item.b.id, Modifier.fillMaxSize(), 300, 2.dp)
                val p = bookProgress[item.b.id]
                val value = p?.progress ?: 0.0
                if (p?.isFinished != true && value > 0) BookProgressBar(value, Modifier.align(Alignment.BottomCenter))
            }
            is LibItem.U -> AuthorImage(item.u.id, item.u.name, m, width = 300)
        }
    }

    Refreshable(refreshing = playlistsLoad?.refreshing == true || starredLoad?.refreshing == true || pulling, onRefresh = {
        playlistsLoad?.reload(); starredLoad?.reload()
        if (booksConnected) scope.launch {
            pulling = true
            try { app.books.load(force = true) } finally { pulling = false }
        }
    }) {
    LazyColumn(Modifier.fillMaxSize(), state = list, contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 24.dp)) {
        item {
            Row(Modifier.fillMaxWidth().statusBarsPadding().padding(top = 8.dp, bottom = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                Avatar(32.dp)
                Spacer(Modifier.width(12.dp))
                Text(stringResource(R.string.your_library), fontSize = 24.sp, fontWeight = FontWeight.Bold)
            }
            ChipRow {
                val chips = (if (hasMusic) listOf(LibFilter.PLAYLISTS to R.string.playlists, LibFilter.ALBUMS to R.string.albums,
                    LibFilter.ARTISTS to R.string.artists, LibFilter.DOWNLOADS to R.string.downloads) else emptyList()) +
                    (if (booksConnected && bookLibraries.any { !it.isPodcasts }) listOf(LibFilter.BOOKS to R.string.bk_audiobooks) else emptyList()) +
                    (if (booksConnected && bookLibraries.any { it.isPodcasts }) listOf(LibFilter.PODCASTS to R.string.bk_podcasts) else emptyList())
                chips.forEach { (f, label) ->
                    Chip(stringResource(label), filter == f) { filter = if (filter == f) null else f }
                }
            }
            Spacer(Modifier.height(14.dp))
            LibraryToolbar(searching, query, { query = it }, { searching = it; if (!it) query = "" }, sort, { app.settings.setLibrarySort(it) },
                grid, { app.settings.setLibraryGrid(!grid) })
            Spacer(Modifier.height(14.dp))
        }
        if (grid) {
            items(items.chunked(2).size) { r ->
                val row = items.chunked(2)[r]
                Row(Modifier.padding(bottom = 18.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    row.forEach { item ->
                        PinMenuBox(item.alwaysPinned, item.id in pins, { togglePin(item) }, Modifier.weight(1f), onClick = { open(item) }, extra = { close -> BookMenu(item, close) }) {
                            Column {
                                art(item, null)
                                Text(title(item), Modifier.padding(top = 6.dp), fontSize = 14.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                SubtitleLine(isPinned(item), subtitle(item), downloadedCollection(item, downloaded.map { it.song.id }.toSet(), starred))
                            }
                        }
                    }
                    if (row.size == 1) Spacer(Modifier.weight(1f))
                }
            }
        } else {
            items(items.size, key = { (if (items[it].id in pins) "pin." else "") + items[it].id }) { i ->
                val item = items[i]
                PinMenuBox(item.alwaysPinned, item.id in pins, { togglePin(item) }, Modifier.fillMaxWidth().padding(bottom = 12.dp), onClick = { open(item) }, extra = { close -> BookMenu(item, close) }) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        art(item, 64.dp)
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(title(item), fontSize = 16.sp, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            SubtitleLine(isPinned(item), subtitle(item), downloadedCollection(item, downloaded.map { it.song.id }.toSet(), starred))
                        }
                    }
                }
            }
        }
        item {
            if (items.isEmpty()) Text(
                when {
                    q.isNotEmpty() -> stringResource(R.string.library_no_match, q)
                    filter == LibFilter.ALBUMS -> stringResource(R.string.library_no_albums)
                    filter == LibFilter.ARTISTS -> stringResource(R.string.library_no_artists)
                    filter == LibFilter.DOWNLOADS -> stringResource(R.string.library_no_downloads)
                    filter == LibFilter.BOOKS || (filter == null && !hasMusic) -> stringResource(R.string.bka_no_fav_books)
                    filter == LibFilter.PODCASTS -> stringResource(R.string.bka_no_fav_podcasts)
                    else -> stringResource(R.string.nothing_here)
                },
                Modifier.fillMaxWidth().padding(top = 40.dp), color = Palette.secondaryText, fontSize = 15.sp, textAlign = TextAlign.Center,
            )
            // The library holds what you saved; the whole server is one tap away
            if (booksConnected && q.isEmpty() && (filter == LibFilter.BOOKS || (filter == null && !hasMusic)) && bookLibraries.any { !it.isPodcasts }) {
                BrowseRow(Icons.Default.Book, stringResource(R.string.bka_browse_audiobooks)) { nav.open("books") }
            }
            if (booksConnected && q.isEmpty() && filter == LibFilter.PODCASTS) {
                BrowseRow(Icons.Default.Mic, stringResource(R.string.bka_browse_podcasts)) { nav.open("books") }
            }
            if (filter == LibFilter.ALBUMS || filter == LibFilter.ARTISTS) {
                val albums = filter == LibFilter.ALBUMS
                BrowseRow(if (albums) Icons.Default.ViewModule else Icons.Default.Mic, stringResource(if (albums) R.string.browse_all_albums else R.string.browse_all_artists)) {
                    nav.open(if (albums) "albums/alphabeticalByName" else "artists")
                }
            }
        }
    }
    }
}

/** A row that opens everything on the server: icon, title, chevron. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun BrowseRow(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, onClick: () -> Unit) {
    Row(
        Modifier.padding(top = 8.dp).fillMaxWidth().height(52.dp).clip(RoundedCornerShape(12.dp)).background(Palette.elevated)
            .combinedClickable(onClick = onClick)
            .padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = Palette.accent, modifier = Modifier.width(28.dp))
        Text(title, Modifier.weight(1f), fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        Icon(Icons.Default.ChevronRight, null, tint = Palette.subtle)
    }
}

/** The heart for a book or author in the long-press menu. */
@Composable
private fun BookMenu(item: LibItem, close: () -> Unit) {
    when (item) {
        is LibItem.B -> BookFavoriteMenuItem(item.b, close)
        is LibItem.U -> AuthorFavoriteMenuItem(item.u.id, item.u.name, close)
        else -> Unit
    }
}

/** Is an album or the favorites on the phone: none, some, or all of it. */
private fun downloadedCollection(item: LibItem, ids: Set<String>, starred: SearchBody?): Boolean? = when (item) {
    is LibItem.A -> null // the album's songs aren't loaded here; the downloads filter shows only downloaded ones
    LibItem.Favorites -> starred?.song?.takeIf { it.isNotEmpty() }?.let { s -> s.all { it.id in ids } }?.takeIf { it }
    else -> null
}

@Composable
private fun SubtitleLine(pinned: Boolean, text: String, downloaded: Boolean?) {
    Row(Modifier.padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        if (pinned) {
            Icon(Icons.Default.PushPin, null, tint = Palette.accent, modifier = Modifier.size(11.dp).rotate(45f))
            Spacer(Modifier.width(4.dp))
        }
        if (downloaded == true) {
            Icon(Icons.Default.ArrowCircleDown, null, tint = Palette.accent, modifier = Modifier.size(13.dp))
            Spacer(Modifier.width(4.dp))
        }
        Text(text, color = Palette.secondaryText, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** Tap opens, a long press offers to pin or unpin (favorites, downloads and the DJ always stay on top). */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun PinMenuBox(
    fixed: Boolean, pinned: Boolean, toggle: () -> Unit, modifier: Modifier, onClick: () -> Unit,
    extra: @Composable (close: () -> Unit) -> Unit = {}, content: @Composable () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    Box(modifier.combinedClickable(onClick = onClick, onLongClick = { if (!fixed) menu = true })) {
        content()
        DropdownMenu(menu, { menu = false }) {
            if (!fixed) DropdownMenuItem(
                text = { Text(stringResource(if (pinned) R.string.unpin else R.string.pin_to_top)) },
                leadingIcon = { Icon(if (pinned) Icons.Outlined.PushPin else Icons.Default.PushPin, null) },
                onClick = { menu = false; toggle() },
            )
            extra { menu = false }
        }
    }
}

/** A cover that fills the size it's given. */
@Composable
fun FillCover(coverArt: String?, modifier: Modifier, corner: androidx.compose.ui.unit.Dp, placeholder: androidx.compose.ui.graphics.vector.ImageVector = Icons.Default.ViewModule) {
    androidx.compose.foundation.layout.BoxWithConstraints(modifier) {
        Cover(coverArt, maxWidth, corner = minOf(corner, maxWidth / 2), pixels = 300, placeholder = placeholder)
    }
}

/** Sort order on the left, search and list/grid on the right – or the search field while searching. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun LibraryToolbar(
    searching: Boolean, query: String, onQuery: (String) -> Unit, setSearching: (Boolean) -> Unit,
    sort: LibrarySort, onSort: (LibrarySort) -> Unit, grid: Boolean, toggleGrid: () -> Unit,
) {
    Row(Modifier.fillMaxWidth().height(36.dp), verticalAlignment = Alignment.CenterVertically) {
        if (searching) {
            val focus = remember { FocusRequester() }
            LaunchedEffect(Unit) { focus.requestFocus() }
            Row(
                Modifier.weight(1f).height(36.dp).clip(RoundedCornerShape(10.dp)).background(Palette.elevated).padding(horizontal = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Default.Search, null, tint = Palette.secondaryText, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Box(Modifier.weight(1f)) {
                    if (query.isEmpty()) Text(stringResource(R.string.search_library), color = Palette.subtle, fontSize = 15.sp)
                    BasicTextField(query, onQuery, Modifier.fillMaxWidth().focusRequester(focus), singleLine = true,
                        textStyle = TextStyle(color = Color.White, fontSize = 15.sp), cursorBrush = SolidColor(Palette.accent))
                }
            }
            Text(stringResource(R.string.cancel), Modifier.padding(start = 14.dp).combinedClickable(onClick = { setSearching(false) }),
                fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        } else {
            var open by remember { mutableStateOf(false) }
            Box {
                Row(Modifier.combinedClickable(onClick = { open = true }), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.SwapVert, null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(stringResource(sortLabel(sort)), fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                }
                DropdownMenu(open, { open = false }) {
                    LibrarySort.entries.forEach { s ->
                        DropdownMenuItem(text = { Text(stringResource(sortLabel(s))) },
                            leadingIcon = { if (s == sort) Icon(Icons.Default.Check, null, tint = Palette.accent) else Spacer(Modifier.size(24.dp)) },
                            onClick = { open = false; onSort(s) })
                    }
                }
            }
            Spacer(Modifier.weight(1f))
            IconButton(onClick = { setSearching(true) }) { Icon(Icons.Default.Search, stringResource(R.string.search_library)) }
            IconButton(onClick = toggleGrid) {
                Icon(if (grid) Icons.AutoMirrored.Filled.List else Icons.Default.GridView, stringResource(if (grid) R.string.show_as_list else R.string.show_as_grid))
            }
        }
    }
}

private fun sortLabel(s: LibrarySort) = when (s) {
    LibrarySort.RECENT -> R.string.recently_added
    LibrarySort.PLAYED -> R.string.recently_played
    LibrarySort.NAME -> R.string.alphabetical
    LibrarySort.CREATOR -> R.string.artist_or_creator
}
