package app.tonalo.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.font.FontWeight
import androidx.navigation.NavController
import app.tonalo.android.R
import app.tonalo.android.data.ABSEpisode
import app.tonalo.android.data.ABSItem
import app.tonalo.android.data.ABSSearchResults
import app.tonalo.android.data.AudiobookLibrary
import app.tonalo.android.data.bookErrorText
import app.tonalo.android.downloads.BookDownloadState
import app.tonalo.android.downloads.BookDownloads
import app.tonalo.android.downloads.DownloadedBook
import app.tonalo.android.tonalo
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

// All audiobooks and podcasts of the server (BooksBrowseView), the book results of the search, and the downloaded
// books (BookDownloadsView) of ios/Tonalo/Views/AudiobookViews.swift and BrowseViews.swift.

private val browseSorts = listOf("title" to R.string.bk_alphabetical, "added" to R.string.recently_added, "creator" to R.string.bk_author)

private fun sortField(key: String) = when (key) {
    "added" -> "addedAt"
    "creator" -> "media.metadata.authorName"
    else -> "media.metadata.title"
}

/** Titles of all libraries of one kind, page by page: one library after the other, 60 at a time. */
internal class BookPager(private val books: AudiobookLibrary, private val podcasts: Boolean, private val sort: String, private val descending: Boolean) {
    /** What is loaded so far. */
    val items = mutableStateListOf<ABSItem>()
    var loading by mutableStateOf(false)
        private set
    var done by mutableStateOf(false)
        private set
    var error by mutableStateOf<Throwable?>(null)
        private set
    private var libraries: List<app.tonalo.android.data.ABSLibrary>? = null
    private var library = 0
    private var page = 0
    private val seen = HashSet<String>()

    /** Loads the next page; does nothing while one is loading or when everything is here. */
    suspend fun next() {
        if (loading || done) return
        loading = true
        try {
            val all = libraries ?: books.libraries(podcasts).also { libraries = it }
            if (library >= all.size) { done = true; return }
            val answer = books.items(all[library].id, page, 60, sort, descending)
            items.addAll(answer.items.filter { seen.add(it.id) })
            page++
            if (answer.items.isEmpty() || page * 60 >= answer.total) {
                library++
                page = 0
                if (library >= all.size) done = true
            }
            error = null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            error = e
        } finally {
            loading = false
        }
    }
}

/**
 * All audiobooks and podcasts of the server: titles page by page (sortable, tiles or list), authors and series; a search
 * field; when there are both audiobook and podcast libraries a switch between them. Without a connection what is saved
 * on the phone shows. Used for route "books".
 */
@Composable
fun BooksBrowseScreen() {
    val context = LocalContext.current
    val app = context.tonalo
    val books = app.books
    val nav = LocalNav.current
    val scope = rememberCoroutineScope()
    val libraries by books.libraries.collectAsState()
    val online by app.online.collectAsState()
    LaunchedEffect(Unit) { books.load() }
    val hasBooks = libraries.any { !it.isPodcasts }
    val hasPodcasts = libraries.any { it.isPodcasts }
    var pick by rememberSaveable { mutableStateOf<Boolean?>(null) }
    val podcasts = pick ?: (!hasBooks && hasPodcasts)
    var section by rememberSaveable { mutableIntStateOf(0) }
    var query by rememberSaveable { mutableStateOf("") }
    var gen by remember { mutableIntStateOf(0) }
    val sort = rememberBookPref("books.sort", "title")
    val list = rememberBookPref("books.list", "0")
    val shown = if (podcasts) 0 else section

    val pager = remember(podcasts, sort.value, gen) { BookPager(books, podcasts, sortField(sort.value), sort.value == "added") }
    LaunchedEffect(pager, shown) { if (shown == 0 && pager.items.isEmpty()) pager.next() }
    val authors = if (shown == 1) rememberBookLoad("authors", gen) { it.allAuthors() } else null
    val series = if (shown == 2) rememberBookLoad("series", gen) { it.allSeries() } else null
    val searching = query.trim().length >= 2
    val found by produceState<ABSSearchResults?>(null, query) {
        value = null
        val q = query.trim()
        if (q.length < 2) return@produceState
        delay(350)
        value = try { books.search(q) } catch (e: CancellationException) { throw e } catch (e: Exception) { ABSSearchResults() }
    }

    Column(Modifier.fillMaxSize().background(Palette.canvas)) {
        TopBar(stringResource(if (podcasts) R.string.bk_podcasts else R.string.bk_audiobooks))
        Refreshable(
            refreshing = pager.loading || authors?.refreshing == true || series?.refreshing == true,
            onRefresh = { scope.launch { books.load(force = true) }; gen++ },
        ) {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp)) {
                if (hasBooks && hasPodcasts) item(key = "kind") {
                    Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Chip(stringResource(R.string.bk_audiobooks), !podcasts) { pick = false }
                        Chip(stringResource(R.string.bk_podcasts), podcasts) { pick = true }
                    }
                }
                if (!podcasts) item(key = "sections") {
                    Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Chip(stringResource(R.string.bk_titles), section == 0) { section = 0 }
                        Chip(stringResource(R.string.bk_authors), section == 1) { section = 1 }
                        Chip(stringResource(R.string.bk_series), section == 2) { section = 2 }
                    }
                }
                item(key = "search") { BookSearchField(query) { query = it } }
                if (!online) item(key = "offline") { OfflineBanner() }
                if (searching) {
                    val result = found
                    if (result == null) item(key = "searching") { Wheel() }
                    else if (result.items.isEmpty() && result.authors.isEmpty() && result.series.isEmpty() && result.narrators.isEmpty()) {
                        item(key = "none") { Text(stringResource(R.string.nothing_here), Modifier.padding(16.dp), color = Palette.secondaryText) }
                    } else bookSearchItems(nav, result)
                } else when (shown) {
                    0 -> {
                        item(key = "sort") {
                            Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                                BookSortMenu(browseSorts, sort.value) { sort.value = it }
                                Spacer(Modifier.weight(1f))
                                BookLayoutButton(list)
                            }
                        }
                        val loaded = pager.items.toList()
                        // Without a connection: what is saved on the phone
                        val offline = if (loaded.isEmpty() && pager.error != null) {
                            knownBookItems(books).filter { it.isPodcast == podcasts }.sortedBy { it.title.lowercase() }
                        } else emptyList()
                        bookItems(loaded + offline, list.value == "1", onEnd = { scope.launch { pager.next() } })
                        if (pager.loading) item(key = "loading") { Wheel() }
                        if (loaded.isEmpty() && offline.isEmpty() && pager.error != null) item(key = "error") {
                            Retry(pager.error?.bookErrorText(context) ?: "") { gen++ }
                        }
                        if (loaded.isEmpty() && pager.done && pager.error == null) item(key = "empty") {
                            Text(stringResource(R.string.nothing_here), Modifier.padding(16.dp), color = Palette.secondaryText)
                        }
                    }
                    1 -> loadedItems(authors) { AuthorEntryRow(it) }
                    else -> loadedItems(series) { SeriesEntryRow(it) }
                }
            }
        }
    }
}

private fun <T> LazyListScope.loadedItems(loader: Loader<List<T>>?, row: @Composable (T) -> Unit) {
    when (val s = loader?.state) {
        null, is Load.Loading -> item(key = "wheel") { Wheel() }
        is Load.Failed -> item(key = "failed") { Retry(s.message) { loader?.reload?.invoke() } }
        is Load.Ready -> {
            val list = s.value
            items(list.size) { row(list[it]) }
        }
    }
}

@Composable
private fun Wheel() {
    Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
}

@Composable
private fun Retry(message: String, onRetry: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(message, color = Palette.secondaryText)
        Button(onClick = onRetry) { Text(stringResource(R.string.retry)) }
    }
}

/** The search field on top of the browse page. */
@Composable
private fun BookSearchField(query: String, onChange: (String) -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).height(44.dp)
            .clip(RoundedCornerShape(Palette.corner(12.dp))).background(Palette.elevated).padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Default.Search, null, tint = Palette.secondaryText, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(8.dp))
        Box(Modifier.weight(1f)) {
            if (query.isEmpty()) Text(stringResource(R.string.bk_search_hint), color = Palette.subtle, fontSize = 16.sp)
            BasicTextField(
                query, onChange, Modifier.fillMaxWidth(), singleLine = true,
                textStyle = TextStyle(color = Color.White, fontSize = 16.sp), cursorBrush = SolidColor(Palette.accent),
            )
        }
        if (query.isNotEmpty()) Icon(
            Icons.Default.Close, stringResource(R.string.cd_close), tint = Palette.secondaryText,
            modifier = Modifier.size(20.dp).clickable { onChange("") },
        )
    }
}

// region Search

/**
 * What the search found in the audiobook libraries: authors, books and podcasts, series, narrators. Used by the Search
 * screen (after the music results or alone for accounts without music).
 */
fun LazyListScope.bookSearchItems(nav: NavController, results: ABSSearchResults) {
    items(results.authors.size) { AuthorEntryRow(results.authors[it], withCount = false) }
    items(results.items.size) { i ->
        val item = results.items[i]
        BookRow(item) { nav.open(bookRoute(item.id)) }
    }
    items(results.series.size) { i ->
        val s = results.series[i]
        BookRowFrame(s.name, stringResource(R.string.bk_series_one), leading = { SeriesPlaceholder() }) { nav.open(bookSeriesRoute(s.id, s.name)) }
    }
    items(results.narrators.size) { i ->
        val n = results.narrators[i]
        BookRowFrame(n, stringResource(R.string.bk_narrator), leading = { AuthorImage(null, n, Modifier.fillMaxSize()) }) { nav.open(bookGroupRoute("narrator", n)) }
    }
}

// endregion

// region Downloads

private class DownloadEntry(val key: String, val item: ABSItem, val episode: ABSEpisode?, val state: BookDownloadState)

private fun removeBook(context: android.content.Context, book: DownloadedBook) {
    if (book.episodeIds.isEmpty()) BookDownloads.remove(context, book.item, null)
    else book.episodeIds.forEach { id ->
        BookDownloads.remove(context, book.item, book.item.media.episodes?.firstOrNull { it.id == id } ?: ABSEpisode(id = id))
    }
}

/**
 * The downloaded audiobooks and podcasts, what is downloading right now and what failed, for the Downloads screen
 * (inside its `GroupedPage`): storage, progress, cancel / retry, the finished books with removal, "delete all".
 * Draws nothing when there is no audiobook server and nothing downloaded.
 */
fun LazyListScope.bookDownloadItems(nav: NavController) {
    item(key = "book-downloads") { BookDownloadsContent(nav) }
}

@Composable
private fun BookDownloadsContent(nav: NavController) {
    val context = LocalContext.current
    val books = context.tonalo.books
    val connected by books.connected.collectAsState()
    val downloaded by BookDownloads.books.collectAsState()
    val states by BookDownloads.states.collectAsState()
    val batch by BookDownloads.batchProgress.collectAsState()
    var confirm by remember { mutableStateOf(false) }
    LaunchedEffect(connected) { books.restore() }

    val known = knownBookItems(books).associateBy { it.id }
    val entries = states.mapNotNull { (key, state) ->
        val item = known[key.substringBefore('/')] ?: return@mapNotNull null
        val episodeId = key.substringAfter('/', "")
        val episode = if (episodeId.isEmpty()) null else item.media.episodes?.firstOrNull { it.id == episodeId } ?: ABSEpisode(id = episodeId)
        DownloadEntry(key, item, episode, state)
    }
    val active = entries.filter { it.state is BookDownloadState.Queued || it.state is BookDownloadState.Downloading }
    val failed = entries.filter { it.state is BookDownloadState.Failed }
    if (!connected && downloaded.isEmpty() && active.isEmpty() && batch == null) return

    Column(Modifier.fillMaxWidth()) {
        if (downloaded.isNotEmpty() || active.isNotEmpty() || batch != null) Group(stringResource(R.string.bk_audiobooks)) {
            val bytes = remember(downloaded) { BookDownloads.storageBytes() }
            ValueRow(stringResource(R.string.storage_used), android.text.format.Formatter.formatShortFileSize(context, bytes))
            batch?.let { p ->
                GroupRow {
                    Text(stringResource(R.string.downloading, (p * 100).toInt().coerceIn(0, 100)))
                    LinearProgressIndicator(progress = { p.coerceIn(0f, 1f) }, Modifier.fillMaxWidth().padding(top = 6.dp), color = Palette.accent, trackColor = Palette.elevated)
                }
            }
        }
        if (active.isNotEmpty()) Group(stringResource(R.string.downloading_n, active.size)) {
            active.forEach { e ->
                GroupRow(
                    icon = { BookCover(e.item.id, Modifier.size(44.dp), width = 160, corner = 3.dp, marksFinished = false) },
                    trailing = {
                        IconButton(onClick = { BookDownloads.cancel(context, e.item, e.episode) }) {
                            Icon(Icons.Default.Close, stringResource(R.string.cancel), tint = Palette.subtle)
                        }
                    },
                ) {
                    Text(e.episode?.title ?: e.item.title, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    val state = e.state
                    if (state is BookDownloadState.Downloading) {
                        LinearProgressIndicator(progress = { state.progress.coerceIn(0f, 1f) }, Modifier.fillMaxWidth().padding(top = 6.dp), color = Palette.accent, trackColor = Palette.elevated)
                    } else {
                        LinearProgressIndicator(Modifier.fillMaxWidth().padding(top = 6.dp), color = Palette.accent, trackColor = Palette.elevated)
                    }
                }
            }
            ActionRow(stringResource(R.string.cancel_all), destructive = true) { active.forEach { BookDownloads.cancel(context, it.item, it.episode) } }
        }
        if (failed.isNotEmpty()) Group {
            ActionRow(stringResource(R.string.retry_failed, failed.size), Icons.Default.Refresh) {
                failed.forEach { BookDownloads.download(context, it.item, it.episode) }
            }
        }
        if (downloaded.isNotEmpty()) {
            Group {
                downloaded.sortedByDescending { it.dateMs }.forEach { book ->
                    GroupRow(
                        onClick = { nav.open(bookRoute(book.item.id)) },
                        icon = { BookCover(book.item.id, Modifier.size(44.dp), width = 160, corner = 3.dp, marksFinished = false) },
                        trailing = {
                            IconButton(onClick = { removeBook(context, book) }) {
                                Icon(Icons.Default.Close, stringResource(R.string.remove_download), tint = Palette.subtle)
                            }
                        },
                    ) {
                        Text(book.item.title, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        val size = android.text.format.Formatter.formatShortFileSize(context, book.bytes)
                        Text(
                            if (book.episodeIds.isEmpty()) size else pluralString(R.plurals.bk_episodes_n, book.episodeIds.size) + " • " + size,
                            fontSize = 12.sp, color = Palette.secondaryText,
                        )
                    }
                }
            }
            Group { ActionRow(stringResource(R.string.bk_delete_all), destructive = true, centered = true) { confirm = true } }
        }
    }
    if (confirm) AlertDialog(
        onDismissRequest = { confirm = false },
        title = { Text(stringResource(R.string.bk_delete_all_q)) },
        confirmButton = {
            TextButton(onClick = { confirm = false; BookDownloads.removeAll(context) }) {
                Text(stringResource(R.string.bk_delete_all), color = Color(0xFFFF5A5F))
            }
        },
        dismissButton = { TextButton(onClick = { confirm = false }) { Text(stringResource(R.string.cancel)) } },
    )
}

// endregion
