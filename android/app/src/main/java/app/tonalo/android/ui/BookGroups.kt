package app.tonalo.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.LibraryBooks
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.tonalo.android.R
import app.tonalo.android.data.ABSAuthor
import app.tonalo.android.data.ABSAuthorPage
import app.tonalo.android.data.ABSItem
import app.tonalo.android.data.ABSSeriesEntry
import app.tonalo.android.tonalo
import java.text.Collator

// The pages of a group of books (series, narrator, genre, tag) and of an author: BookGroupView and BookAuthorView of
// ios/Tonalo/Views/AudiobookViews.swift, plus the small pieces they share with the browse screen.

// region Shared pieces

/** "Sort by" menu: a label with arrows that opens the [options] (key to label). Used on the browse and author pages. */
@Composable
internal fun BookSortMenu(options: List<Pair<String, Int>>, selected: String, onPick: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val label = (options.firstOrNull { it.first == selected } ?: options.first()).second
    Box {
        Row(
            Modifier.clip(RoundedCornerShape(8.dp)).clickable { open = true }.padding(horizontal = 4.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Default.SwapVert, stringResource(R.string.bk_sort_by), modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(6.dp))
            Text(stringResource(label), fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            options.forEach { (key, text) ->
                DropdownMenuItem(
                    text = { Text(stringResource(text), color = if (key == selected) Palette.accent else Color.Unspecified) },
                    onClick = { open = false; onPick(key) },
                )
            }
        }
    }
}

/** Switches the books between tiles and a list; remembered for all book pages. */
@Composable
internal fun BookLayoutButton(pref: BookPref) {
    val list = pref.value == "1"
    IconButton(onClick = { pref.value = if (list) "0" else "1" }) {
        Icon(
            if (list) Icons.Default.GridView else Icons.AutoMirrored.Filled.List,
            stringResource(if (list) R.string.bk_show_grid else R.string.bk_show_list), modifier = Modifier.size(22.dp),
        )
    }
}

/** An author in a list: round picture, name, number of books; long press offers the heart. */
@Composable
internal fun AuthorEntryRow(a: ABSAuthor, withCount: Boolean = true) {
    val nav = LocalNav.current
    val sub = a.numBooks?.takeIf { withCount }?.let { pluralString(R.plurals.bk_books, it) } ?: stringResource(R.string.bk_author)
    BookRowFrame(
        a.name, sub,
        leading = { AuthorImage(a.id, a.name, Modifier.fillMaxSize()) },
        menu = { close -> AuthorFavoriteMenuItem(a.id, a.name, close) },
        onClick = { nav.open(bookAuthorRoute(a.id)) },
    )
}

/** A series in a list: the cover of its first book, name, number of books. */
@Composable
internal fun SeriesEntryRow(s: ABSSeriesEntry) {
    val nav = LocalNav.current
    BookRowFrame(
        s.name, pluralString(R.plurals.bk_books, s.count),
        leading = {
            if (s.cover != null) BookCover(s.cover, Modifier.fillMaxSize(), width = 200, corner = 2.dp, marksFinished = false)
            else SeriesPlaceholder()
        },
        onClick = { nav.open(bookSeriesRoute(s.id, s.name)) },
    )
}

/** The square with the books icon, for a series without a cover. */
@Composable
internal fun SeriesPlaceholder() {
    Box(Modifier.fillMaxSize().clip(RoundedCornerShape(Palette.corner(2.dp))).background(Palette.elevated), contentAlignment = Alignment.Center) {
        Icon(Icons.AutoMirrored.Filled.LibraryBooks, null, tint = Palette.subtle)
    }
}

/** "Finished • 2019 • 5 h 12 min" under a book in a list of a series or author. */
@Composable
internal fun groupSubtitle(item: ABSItem): String {
    val finished = rememberBookFinished(item.id)
    return listOfNotNull(
        if (finished) stringResource(R.string.bk_finished) else null,
        item.media.metadata.publishedYear?.take(4)?.ifEmpty { null },
        item.media.duration?.let { bookLength(it) },
    ).joinToString(" • ")
}

// endregion

// region Group

/**
 * A group of books: a series (in the order of the series), the books a narrator read, a genre, a tag. [kind] is
 * `series`, `narrator`, `genre` or `tag`; [name] is the group's name (for a series the id and the name as
 * `"<id>|<name>"`, see [bookSeriesRoute]). Tiles or list, remembered. Used for route "bookgroup/{kind}/{name}".
 */
@Composable
fun BookGroupScreen(kind: String, name: String) {
    val books = LocalContext.current.tonalo.books
    val list = rememberBookPref("books.list", "0")
    val split = kind == "series" && '|' in name
    val value = if (split) name.substringBefore('|') else name
    val title = if (split) name.substringAfter('|') else name
    val group = when (kind) {
        "narrator", "narrators" -> "narrators"
        "genre", "genres" -> "genres"
        "tag", "tags" -> "tags"
        else -> kind
    }
    val loader = rememberBookLoad("bookgroup", kind, name, cached = {
        knownBookItems(books).filter { item ->
            when (group) {
                "series" -> item.media.metadata.series?.all.orEmpty().any { it.id == value || it.name == title }
                "narrators" -> value in item.media.metadata.narrators.orEmpty()
                else -> false
            }
        }.takeIf { it.isNotEmpty() }
    }) { b ->
        // A series that came without its id (only the name is known) is looked up first
        val filterValue = if (group == "series" && !split) b.allSeries().firstOrNull { it.name == name }?.id ?: name else value
        b.filtered(group, filterValue, null, sort = if (group == "series") "sequence" else "media.metadata.title")
    }
    Column(Modifier.fillMaxSize().background(Palette.canvas)) {
        TopBar(title)
        val items = (loader.state as? Load.Ready<List<ABSItem>>)?.value
        if (items == null) {
            LoadView(loader) {}
        } else Refreshable(loader.refreshing, loader.reload) {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(top = 8.dp, bottom = 24.dp)) {
                if (items.size > 1) item(key = "layout") {
                    Row(Modifier.fillMaxWidth().padding(end = 8.dp), horizontalArrangement = Arrangement.End) { BookLayoutButton(list) }
                }
                if (items.isEmpty()) item(key = "empty") {
                    Text(stringResource(R.string.nothing_here), Modifier.padding(16.dp), color = Palette.secondaryText)
                }
                bookItems(items, list.value == "1", subtitle = { groupSubtitle(it) })
            }
        }
    }
}

// endregion

// region Author

/**
 * An author: round picture, name, number of books, heart, biography, and the books (sortable, tiles or list) or the
 * series. Works from what is saved when there is no connection. Used for route "bookauthor/{id}".
 */
@Composable
fun BookAuthorScreen(id: String) {
    val books = LocalContext.current.tonalo.books
    val nav = LocalNav.current
    val favorites by books.favoriteAuthors.collectAsState()
    val sort = rememberBookPref("bookAuthor.sort", "title")
    val list = rememberBookPref("books.list", "0")
    var showSeries by rememberSaveable { mutableStateOf(false) }
    var expanded by rememberSaveable { mutableStateOf(false) }
    val loader = rememberBookLoad("bookauthor", id, cached = {
        val known = knownBookItems(books)
        val own = known.filter { item -> item.media.metadata.authors.orEmpty().any { it.id == id } }
        val author = favorites[id]?.author ?: own.firstNotNullOfOrNull { item -> item.media.metadata.authors?.firstOrNull { it.id == id } }
        author?.let { ABSAuthorPage(it, own, emptyList()) }
    }) { it.author(id) }
    val page = (loader.state as? Load.Ready<ABSAuthorPage>)?.value
    val name = page?.author?.name ?: favorites[id]?.author?.name ?: ""

    Column(Modifier.fillMaxSize().background(Palette.canvas)) {
        TopBar(name)
        if (page == null) { LoadView(loader) {}; return@Column }
        val collator = remember { Collator.getInstance() }
        val sorted = remember(page.items, sort.value) {
            val byTitle = Comparator<ABSItem> { x, y -> collator.compare(x.title, y.title) }
            fun year(i: ABSItem) = i.media.metadata.publishedYear?.takeIf { it.isNotEmpty() }
            when (sort.value) {
                "added" -> page.items.sortedWith(Comparator<ABSItem> { x, y ->
                    val a = x.addedAt ?: 0.0
                    val b = y.addedAt ?: 0.0
                    if (a != b) b.compareTo(a) else byTitle.compare(x, y)
                })
                "newest", "oldest" -> page.items.sortedWith(Comparator<ABSItem> { x, y ->
                    val a = year(x)
                    val b = year(y)
                    when {
                        a == null && b == null -> byTitle.compare(x, y)
                        a == null -> 1
                        b == null -> -1
                        a == b -> byTitle.compare(x, y)
                        sort.value == "newest" -> b.compareTo(a)
                        else -> a.compareTo(b)
                    }
                })
                else -> page.items.sortedWith(byTitle)
            }
        }
        Refreshable(loader.refreshing, loader.reload) {
            LazyColumn(Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(top = 8.dp, bottom = 24.dp)) {
                item(key = "header") {
                    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        AuthorImage(id, name, Modifier.size(140.dp), width = 400)
                        Text(name, fontSize = 24.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
                        if (page.items.isNotEmpty()) Text(pluralString(R.plurals.bk_books, page.items.size), fontSize = 13.sp, color = Palette.subtle)
                        val favorite = id in favorites
                        ActionIcon(
                            if (favorite) Icons.Default.Favorite else Icons.Default.FavoriteBorder,
                            stringResource(if (favorite) R.string.remove_favorite else R.string.add_favorite), active = favorite,
                        ) { books.toggleFavoriteAuthor(id, name) }
                    }
                }
                val bio = page.author.description
                if (!bio.isNullOrEmpty()) item(key = "bio") {
                    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(bio, fontSize = 14.sp, color = Palette.subtle, maxLines = if (expanded) Int.MAX_VALUE else 4, overflow = TextOverflow.Ellipsis)
                        Text(
                            stringResource(if (expanded) R.string.bk_less else R.string.bk_more), Modifier.clickable { expanded = !expanded },
                            fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                        )
                    }
                }
                if (page.series.isNotEmpty()) item(key = "tabs") {
                    Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Chip(stringResource(R.string.bk_titles), !showSeries) { showSeries = false }
                        Chip(stringResource(R.string.bk_series), showSeries) { showSeries = true }
                    }
                }
                if (showSeries && page.series.isNotEmpty()) {
                    items(page.series.size) { SeriesEntryRow(page.series[it]) }
                } else {
                    if (page.items.size > 1) item(key = "sort") {
                        Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                            BookSortMenu(authorSorts, sort.value) { sort.value = it }
                            Spacer(Modifier.weight(1f))
                            BookLayoutButton(list)
                        }
                    }
                    bookItems(sorted, list.value == "1", subtitle = { groupSubtitle(it) })
                }
            }
        }
    }
}

private val authorSorts = listOf(
    "title" to R.string.bk_alphabetical, "newest" to R.string.bk_newest, "oldest" to R.string.bk_oldest, "added" to R.string.recently_added,
)

// endregion
