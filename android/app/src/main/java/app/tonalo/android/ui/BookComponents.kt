@file:OptIn(ExperimentalFoundationApi::class)

package app.tonalo.android.ui

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowCircleDown
import androidx.compose.material.icons.filled.Book
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.HeartBroken
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.ArrowCircleDown
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavController
import app.tonalo.android.R
import app.tonalo.android.data.ABSEpisode
import app.tonalo.android.data.ABSItem
import app.tonalo.android.data.ABSProgress
import app.tonalo.android.data.AudiobookLibrary
import app.tonalo.android.data.bookErrorText
import app.tonalo.android.downloads.BookDownloadState
import app.tonalo.android.downloads.BookDownloads
import app.tonalo.android.playback.BookPlayer
import app.tonalo.android.tonalo
import coil3.compose.SubcomposeAsyncImage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableIntStateOf

// Audiobooks and podcasts: the pieces every book screen is made of (covers, cards, shelves, rows, download button),
// the routes, and small helpers. Port of BookCover, BookProgressBar, BookCard, BookShelf, AuthorImage,
// AuthorFavoriteMenu and BookDownloadButton of ios/Tonalo/Views/AudiobookViews.swift.

// region Routes

/** Route of the audiobook page "book/{id}". [episodeId] (a podcast episode to highlight) goes along as `?episode=`. */
fun bookRoute(id: String, episodeId: String? = null): String =
    "book/" + Uri.encode(id) + (episodeId?.let { "?episode=" + Uri.encode(it) } ?: "")

/**
 * Route of a group of books "bookgroup/{kind}/{name}". [kind] is `series`, `narrator`, `genre` or `tag`.
 * For `series` the name may be `"<seriesId>|<title>"` (see [bookSeriesRoute]).
 */
fun bookGroupRoute(kind: String, name: String): String = "bookgroup/" + Uri.encode(kind) + "/" + Uri.encode(name.ifBlank { "_" })

/** Route of a series page; carries the series id (the server's filter value) and the name for the title. */
fun bookSeriesRoute(id: String, name: String): String = bookGroupRoute("series", "$id|$name")

/** Route of an author page "bookauthor/{id}". */
fun bookAuthorRoute(id: String): String = "bookauthor/" + Uri.encode(id)

// endregion

// region Helpers

/** "5 h 12 min" for lengths and what is left. */
internal fun bookLength(seconds: Double): String {
    val s = maxOf(60, seconds.toInt())
    val m = s / 60
    return if (s >= 3600) "${m / 60} h ${m % 60} min" else "$m min"
}

/** "1:02:03" / "2:03" for chapter times. */
internal fun bookClock(seconds: Double): String {
    val s = maxOf(0, seconds.toInt())
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
}

/** Starts playback and opens the player (the route of the book player screen). */
internal fun playBook(context: Context, nav: NavController, item: ABSItem, episode: ABSEpisode? = null) {
    BookPlayer.play(context, item, episode)
    nav.open("bookplayer")
}

/** What is known without asking the server: shelves, what is in progress, hearts and downloads. One entry per item. */
internal fun knownBookItems(books: AudiobookLibrary): List<ABSItem> {
    val all = books.shelves.value.flatMap { it.items } + books.inProgress.value + books.favorites.value.values.map { it.item } +
        BookDownloads.books.value.map { it.item }
    return all.distinctBy { it.id }
}

/** A saved preference of the book screens (sort, tiles or list), remembered across launches. */
internal class BookPref(private val prefs: SharedPreferences, private val key: String, default: String) {
    private var state by mutableStateOf(prefs.getString(key, default) ?: default)

    /** The current value; setting it saves it. */
    var value: String
        get() = state
        set(v) { state = v; prefs.edit().putString(key, v).apply() }
}

@Composable
internal fun rememberBookPref(key: String, default: String): BookPref {
    val context = LocalContext.current
    return remember(key) { BookPref(context.getSharedPreferences("books_ui", Context.MODE_PRIVATE), key, default) }
}

/**
 * Loads something from the Audiobookshelf server for a page, like `rememberLoad` does for the music server (which
 * needs a music account). [cached] shows at once and stays when the server can't be reached.
 */
@Composable
internal fun <T> rememberBookLoad(vararg keys: Any?, cached: (() -> T?)? = null, block: suspend (AudiobookLibrary) -> T): Loader<T> {
    val context = LocalContext.current
    val app = context.tonalo
    val account by app.current.collectAsState()
    var attempt by remember { mutableIntStateOf(0) }
    var state by remember(*keys, account?.id) { mutableStateOf<Load<T>>(cached?.invoke()?.let { Load.Ready(it) } ?: Load.Loading) }
    var running by remember { mutableStateOf(false) }
    LaunchedEffect(*keys, account?.id, attempt) {
        if (state is Load.Failed) state = Load.Loading
        running = true
        try {
            state = try {
                Load.Ready(block(app.books))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (state is Load.Ready) state else Load.Failed(e.bookErrorText(context))
            }
        } finally {
            running = false
        }
    }
    return Loader(state, { attempt++ }, running && state is Load.Ready)
}

/** The progress record of one book or episode, following changes while it plays. Null when there is none. */
@Composable
internal fun rememberBookProgressByKey(key: String): ABSProgress? {
    val books = LocalContext.current.tonalo.books
    val flow = remember(key) { books.progress.map { it[key] }.distinctUntilChanged() }
    val p by flow.collectAsState(books.progress.value[key])
    return p
}

/** The progress of an item, of [episode] or of the episode a "new episodes" shelf is about. */
@Composable
fun rememberBookProgress(item: ABSItem, episode: ABSEpisode? = null): ABSProgress? =
    rememberBookProgressByKey(ABSProgress.key(item.id, episode?.id ?: item.recentEpisode?.id))

/** Whether a book (or an episode) was listened to the end. */
@Composable
fun rememberBookFinished(itemId: String, episodeId: String? = null): Boolean =
    rememberBookProgressByKey(ABSProgress.key(itemId, episodeId))?.isFinished == true

/** Whether something of this book is downloaded to the phone. */
@Composable
internal fun rememberBookDownloaded(itemId: String): Boolean {
    val list by BookDownloads.books.collectAsState()
    return list.any { it.item.id == itemId }
}

/** Splits a list into rows of two, for grids inside a `LazyColumn` (the pages also carry headers and paging). */
internal fun LazyListScope.bookGridRows(items: List<ABSItem>, onEnd: (() -> Unit)? = null) {
    val rows = items.chunked(2)
    items(rows.size) { i ->
        Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 18.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            rows[i].forEach { Box(Modifier.weight(1f)) { BookCard(it, null) } }
            if (rows[i].size == 1) Spacer(Modifier.weight(1f))
        }
        if (onEnd != null && i == rows.lastIndex) LaunchedEffect(rows.size) { onEnd() }
    }
}

/** Books as tiles or as a list, depending on [list] (the "books.list" preference). */
internal fun LazyListScope.bookItems(items: List<ABSItem>, list: Boolean, onEnd: (() -> Unit)? = null, subtitle: (@Composable (ABSItem) -> String?)? = null) {
    if (!list) {
        bookGridRows(items, onEnd)
    } else {
        items(items.size) { i ->
            val item = items[i]
            val nav = LocalNav.current
            BookRow(item, subtitle?.invoke(item)) { nav.open(bookRoute(item.id)) }
            if (onEnd != null && i == items.lastIndex) LaunchedEffect(items.size) { onEnd() }
        }
    }
}

// endregion

// region Covers

/**
 * Cover of a book or podcast, square, filling the width the caller gives it. Finished books look washed out and carry
 * a check mark when [marksFinished]. Used on every book screen (shelves, grids, rows, detail page).
 */
@Composable
fun BookCover(itemId: String, modifier: Modifier = Modifier, width: Int = 300, corner: Dp = 4.dp, marksFinished: Boolean = true) {
    val books = LocalContext.current.tonalo.books
    val home by books.atHome.collectAsState()
    val connected by books.connected.collectAsState()
    val url = remember(itemId, width, home, connected) { books.coverURL(itemId, width) }
    val finished = marksFinished && rememberBookFinished(itemId)
    val fallback = @Composable {
        Box(Modifier.fillMaxSize().background(Palette.elevated), contentAlignment = Alignment.Center) {
            Icon(Icons.Default.Book, null, tint = Palette.subtle, modifier = Modifier.fillMaxSize(0.32f))
        }
    }
    BoxWithConstraints(modifier.aspectRatio(1f).clip(RoundedCornerShape(Palette.corner(corner))).background(Palette.elevated)) {
        if (url == null) fallback() else SubcomposeAsyncImage(
            model = url,
            contentDescription = null,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxSize(),
            alpha = if (finished) 0.5f else 1f,
            colorFilter = if (finished) ColorFilter.colorMatrix(ColorMatrix().apply { setToSaturation(0.15f) }) else null,
            loading = { fallback() },
            error = { fallback() },
        )
        if (finished) {
            val size = minOf(44f, maxOf(20f, maxWidth.value * 0.22f)).dp
            Box(
                Modifier.align(Alignment.TopEnd).padding(size * 0.22f).size(size).clip(CircleShape).background(Palette.accent),
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Default.Check, stringResource(R.string.bk_finished), tint = Color.Black, modifier = Modifier.size(size * 0.56f)) }
        }
    }
}

/** How far along: a thin bar under a cover or a row. [value] is 0..1. Used under covers, in rows and on the detail page. */
@Composable
fun BookProgressBar(value: Double, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().height(3.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.25f))) {
        Box(Modifier.fillMaxHeight().fillMaxWidth(value.coerceIn(0.0, 1.0).toFloat()).background(Palette.accent))
    }
}

/**
 * Round picture of an author; the initial where the server has none, and always for narrators (id null).
 * Used in author rows, the detail page's author line and the author page.
 */
@Composable
fun AuthorImage(id: String?, name: String, modifier: Modifier = Modifier, width: Int = 200) {
    val books = LocalContext.current.tonalo.books
    val home by books.atHome.collectAsState()
    val connected by books.connected.collectAsState()
    val url = remember(id, width, home, connected) { id?.let { books.authorImageURL(it, width) } }
    BoxWithConstraints(modifier.aspectRatio(1f).clip(CircleShape).background(Palette.elevated), contentAlignment = Alignment.Center) {
        val box = maxWidth
        val initial = @Composable {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    name.firstOrNull()?.uppercaseChar()?.toString() ?: "?", color = Palette.subtle, fontWeight = FontWeight.Bold,
                    fontSize = (box.value * 0.42f).sp,
                )
            }
        }
        if (url == null) initial() else SubcomposeAsyncImage(
            model = url, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize(),
            loading = { initial() }, error = { initial() },
        )
    }
}

// endregion

// region Cards, shelves, rows

/**
 * A book or podcast as a card: cover, progress bar, title, author. [width] null fills its place in a grid.
 * Tap opens the audiobook page; long press offers the heart. Used in shelves (Home) and grids (browse, groups, author).
 */
@Composable
fun BookCard(item: ABSItem, width: Dp? = 140.dp) {
    val nav = LocalNav.current
    val scale = coverScale()
    val progress = rememberBookProgress(item)
    val bookFinished = rememberBookFinished(item.id)
    val finished = progress?.isFinished == true || bookFinished
    var menu by remember { mutableStateOf(false) }
    Box(if (width != null) Modifier.width(width * scale) else Modifier.fillMaxWidth()) {
        Column(
            Modifier.fillMaxWidth().combinedClickable(onClick = { nav.open(bookRoute(item.id)) }, onLongClick = { menu = true }),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            BookCover(item.id, Modifier.fillMaxWidth())
            val value = progress?.progress ?: 0.0
            if (!finished && value > 0) BookProgressBar(value)
            Text(
                item.recentEpisode?.title ?: item.title, maxLines = 2, overflow = TextOverflow.Ellipsis, fontSize = 13.sp, lineHeight = 16.sp,
                fontWeight = FontWeight.SemiBold, color = if (finished) Palette.subtle else Color.White,
            )
            if (finished) {
                Text(stringResource(R.string.bk_finished), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Palette.accent, maxLines = 1)
            } else {
                Text(
                    if (item.recentEpisode != null) item.title else item.creator,
                    fontSize = 12.sp, color = Palette.subtle, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) { BookFavoriteMenuItem(item) { menu = false } }
    }
}

/** A titled row of [BookCard]s, scrolling sideways. Used on Home (one per shelf of the server) and on the author page. */
@Composable
fun BookShelf(title: String, items: List<ABSItem>) {
    if (items.isEmpty()) return
    SectionHeader(title)
    LazyRow(contentPadding = HorizontalPadding, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        items(items.size) { BookCard(items[it]) }
    }
}

/**
 * The frame of one row in a list of books, authors or series: [leading] picture, title, subtitle (with an optional
 * [subtitlePrefix] such as the download mark) and a long-press [menu]. Used by every list on the book screens.
 */
@Composable
fun BookRowFrame(
    title: String,
    subtitle: String?,
    leading: @Composable () -> Unit,
    subtitlePrefix: (@Composable () -> Unit)? = null,
    menu: (@Composable (close: () -> Unit) -> Unit)? = null,
    onClick: () -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier.fillMaxWidth().combinedClickable(onClick = onClick, onLongClick = if (menu != null) ({ open = true }) else null)
                .padding(horizontal = 16.dp, vertical = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.size(52.dp)) { leading() }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis, style = androidx.compose.material3.MaterialTheme.typography.bodyLarge)
                if (!subtitle.isNullOrEmpty() || subtitlePrefix != null) Row(verticalAlignment = Alignment.CenterVertically) {
                    subtitlePrefix?.invoke()
                    if (!subtitle.isNullOrEmpty()) Text(
                        subtitle, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        style = androidx.compose.material3.MaterialTheme.typography.bodyMedium, color = Palette.secondaryText,
                    )
                }
            }
        }
        if (menu != null) DropdownMenu(expanded = open, onDismissRequest = { open = false }) { menu { open = false } }
    }
}

/**
 * A book or podcast as a list row: small cover with its progress bar, title, "Finished • Audiobook • Author" (or
 * [subtitle]), the download mark. Used in search results, lists of an author or series, and the Library.
 */
@Composable
fun BookRow(item: ABSItem, subtitle: String? = null, onClick: () -> Unit) {
    val progress = rememberBookProgress(item)
    val bookFinished = rememberBookFinished(item.id)
    val finished = progress?.isFinished == true || bookFinished
    val downloaded = rememberBookDownloaded(item.id)
    val finishedText = stringResource(R.string.bk_finished)
    val kind = stringResource(if (item.isPodcast) R.string.bk_podcast else R.string.bk_audiobook)
    val text = subtitle ?: listOfNotNull(if (finished) finishedText else null, kind, item.creator.ifEmpty { null }).joinToString(" • ")
    BookRowFrame(
        item.title, text,
        leading = {
            Box(Modifier.fillMaxSize()) {
                BookCover(item.id, Modifier.fillMaxSize(), width = 200, corner = 2.dp)
                val value = progress?.progress ?: 0.0
                if (!finished && value > 0) BookProgressBar(value, Modifier.align(Alignment.BottomCenter))
            }
        },
        subtitlePrefix = if (downloaded) ({
            Icon(Icons.Default.ArrowCircleDown, stringResource(R.string.downloaded), tint = Palette.accent, modifier = Modifier.size(12.dp))
            Spacer(Modifier.width(5.dp))
        }) else null,
        menu = { close -> BookFavoriteMenuItem(item, close) },
        onClick = onClick,
    )
}

// endregion

// region Favorites

/** "Add to favorites" / "Remove from favorites" for a book, as an item of a dropdown menu (long press, "…"). */
@Composable
fun BookFavoriteMenuItem(item: ABSItem, close: () -> Unit) {
    val books = LocalContext.current.tonalo.books
    val favorites by books.favorites.collectAsState()
    val on = item.id in favorites
    MenuItem(if (on) R.string.remove_favorite else R.string.add_favorite, if (on) Icons.Default.HeartBroken else Icons.Default.FavoriteBorder) {
        books.toggleFavorite(item)
        close()
    }
}

/** The same for an author (long press on an author wherever they are listed). */
@Composable
fun AuthorFavoriteMenuItem(id: String, name: String, close: () -> Unit) {
    val books = LocalContext.current.tonalo.books
    val favorites by books.favoriteAuthors.collectAsState()
    val on = id in favorites
    MenuItem(if (on) R.string.remove_favorite else R.string.add_favorite, if (on) Icons.Default.HeartBroken else Icons.Default.FavoriteBorder) {
        books.toggleFavoriteAuthor(id, name)
        close()
    }
}

// endregion

// region Download button

/**
 * Arrow, progress ring or check mark for a book or one episode. Tapping a finished one offers removal, a running one
 * offers cancelling. Used on the detail page (book and episodes). Hidden when the server doesn't let this user download.
 */
@Composable
fun BookDownloadButton(item: ABSItem, episode: ABSEpisode? = null, size: Dp = 22.dp) {
    val context = LocalContext.current
    val books = context.tonalo.books
    val canDownload by books.canDownload.collectAsState()
    val states by BookDownloads.states.collectAsState()
    val key = ABSProgress.key(item.id, episode?.id)
    val state = states[key] ?: BookDownloadState.None
    var confirmRemove by remember { mutableStateOf(false) }
    var confirmCancel by remember { mutableStateOf(false) }
    val untouched = state is BookDownloadState.None
    if (untouched && !canDownload) return
    Box(
        Modifier.size(size + 14.dp).clip(CircleShape).clickable {
            when (state) {
                is BookDownloadState.None, is BookDownloadState.Failed -> BookDownloads.download(context, item, episode)
                is BookDownloadState.Done -> confirmRemove = true
                else -> confirmCancel = true
            }
        },
        contentAlignment = Alignment.Center,
    ) {
        when (state) {
            is BookDownloadState.Done -> Icon(Icons.Default.ArrowCircleDown, stringResource(R.string.remove_download), tint = Palette.accent, modifier = Modifier.size(size))
            is BookDownloadState.Failed -> Icon(Icons.Default.Warning, stringResource(R.string.download), tint = Color(0xFFFF9F0A), modifier = Modifier.size(size))
            is BookDownloadState.Downloading -> CircularProgressIndicator(
                progress = { state.progress.coerceIn(0f, 1f) }, modifier = Modifier.size(size), color = Palette.accent, strokeWidth = 3.dp,
                trackColor = Palette.elevated,
            )
            is BookDownloadState.Queued -> CircularProgressIndicator(Modifier.size(size), color = Palette.accent, strokeWidth = 3.dp, trackColor = Palette.elevated)
            else -> Icon(Icons.Outlined.ArrowCircleDown, stringResource(R.string.download), tint = Palette.subtle, modifier = Modifier.size(size))
        }
    }
    if (confirmRemove) AlertDialog(
        onDismissRequest = { confirmRemove = false },
        title = { Text(stringResource(R.string.bk_remove_download_q)) },
        confirmButton = {
            TextButton(onClick = { confirmRemove = false; BookDownloads.remove(context, item, episode) }) {
                Text(stringResource(R.string.remove_download), color = Color(0xFFFF5A5F))
            }
        },
        dismissButton = { TextButton(onClick = { confirmRemove = false }) { Text(stringResource(R.string.cancel)) } },
    )
    if (confirmCancel) AlertDialog(
        onDismissRequest = { confirmCancel = false },
        title = { Text(stringResource(R.string.bk_cancel_download_q)) },
        confirmButton = {
            TextButton(onClick = { confirmCancel = false; BookDownloads.cancel(context, item, episode) }) {
                Text(stringResource(R.string.cancel_download), color = Color(0xFFFF5A5F))
            }
        },
        dismissButton = { TextButton(onClick = { confirmCancel = false }) { Text(stringResource(R.string.bk_keep_downloading)) } },
    )
}

// endregion
