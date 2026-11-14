@file:OptIn(ExperimentalMaterial3Api::class)

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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.LibraryBooks
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.PlayCircleOutline
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.text.HtmlCompat
import app.tonalo.android.R
import app.tonalo.android.data.ABSEpisode
import app.tonalo.android.data.ABSItem
import app.tonalo.android.data.bookErrorText
import app.tonalo.android.downloads.BookDownloads
import app.tonalo.android.playback.BookPlayer
import app.tonalo.android.tonalo
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

// The page of one audiobook or podcast (AudiobookView of ios/Tonalo/Views/AudiobookViews.swift).

/**
 * The detail page of a book or podcast: cover, author / narrator / series links, progress, heart, download, play or
 * resume, chapters, the episodes of a podcast, the description and more books by the author. Used for route
 * "book/{id}". [episodeId] marks a podcast episode (from `?episode=` of [bookRoute]).
 */
@Composable
fun AudiobookScreen(id: String, episodeId: String? = null) {
    val context = LocalContext.current
    val books = context.tonalo.books
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { books.load() }
    // What is known shows at once, and is what is left without a connection
    val loader = rememberBookLoad("book", id, cached = {
        books.savedItem(id) ?: BookDownloads.books.value.firstOrNull { it.item.id == id }?.item
    }) { it.item(id) }
    val item = (loader.state as? Load.Ready<ABSItem>)?.value
    if (item == null) {
        Box(Modifier.fillMaxSize()) { LoadView(loader) {}; RoundBackButton() }
        return
    }
    BookDetail(item, episodeId, loader.refreshing) { scope.launch { books.load(force = true) }; loader.reload() }
}

@Composable
private fun BookDetail(item: ABSItem, episodeId: String?, refreshing: Boolean, onRefresh: () -> Unit) {
    val context = LocalContext.current
    val nav = LocalNav.current
    val books = context.tonalo.books
    val scope = rememberCoroutineScope()
    val snackbar = LocalSnackbar.current
    val player by BookPlayer.state.collectAsState()
    val favorites by books.favorites.collectAsState()
    val progress = rememberBookProgressByKey(item.id)
    var expanded by rememberSaveable { mutableStateOf(false) }
    var showChapters by remember { mutableStateOf(false) }
    val author = item.media.metadata.authors?.firstOrNull()
    val more by produceState<List<ABSItem>>(emptyList(), item.id, author?.id) {
        val a = author ?: return@produceState
        value = try { books.author(a.id).items.filter { it.id != item.id } } catch (e: CancellationException) { throw e } catch (e: Exception) { emptyList() }
    }
    val description = remember(item.id, item.media.metadata.description) {
        item.media.metadata.description?.let { HtmlCompat.fromHtml(it, HtmlCompat.FROM_HTML_MODE_COMPACT).toString().trim() }.orEmpty()
    }

    DetailPage(
        null, item.title,
        art = { BookCover(item.id, Modifier.fillMaxSize(), width = 800, corner = 6.dp) },
        info = {
            val m = item.media.metadata
            val finished = rememberBookFinished(item.id)
            if (finished) Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.CheckCircle, null, tint = Palette.accent, modifier = Modifier.size(15.dp))
                Spacer(Modifier.width(6.dp))
                Text(stringResource(R.string.bk_finished), color = Palette.accent, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            }
            m.subtitle?.takeIf { it.isNotEmpty() }?.let { Text(it, fontSize = 15.sp, color = Palette.subtle) }
            val authors = m.authors.orEmpty()
            if (authors.isNotEmpty()) authors.forEach { a ->
                OwnerLine(a.name, { AuthorImage(a.id, a.name, Modifier.fillMaxSize(), width = 60) }) { nav.open(bookAuthorRoute(a.id)) }
            } else if (item.creator.isNotEmpty()) Text(item.creator, fontSize = 13.sp, fontWeight = FontWeight.Bold)
            m.narrators.orEmpty().forEach { n ->
                Text(stringResource(R.string.bk_read_by, n), Modifier.clickable { nav.open(bookGroupRoute("narrator", n)) }, fontSize = 13.sp, color = Palette.subtle)
            }
            m.series?.all.orEmpty().forEach { s ->
                Row(Modifier.clickable { nav.open(bookSeriesRoute(s.id, s.name)) }, verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.AutoMirrored.Filled.LibraryBooks, null, tint = Palette.subtle, modifier = Modifier.size(12.dp))
                    Spacer(Modifier.width(4.dp))
                    Text(s.sequence?.let { "${s.name} #$it" } ?: s.name, fontSize = 13.sp, color = Palette.subtle)
                }
            }
            Text(
                listOfNotNull(
                    stringResource(if (item.isPodcast) R.string.bk_podcast else R.string.bk_audiobook), m.publishedYear?.ifEmpty { null },
                    item.media.duration?.let { bookLength(it) },
                ).joinToString(" • "),
                fontSize = 13.sp, color = Palette.subtle,
            )
        },
        actions = {
            val here = player.item?.id == item.id
            val started = !item.isPodcast && (progress?.currentTime ?: 0.0) > 0 && progress?.isFinished != true
            val favorite = item.id in favorites
            Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (started) progress?.progress?.let { value ->
                    BookProgressBar(value)
                    Text(
                        stringResource(R.string.bk_left, bookLength((item.media.duration ?: 0.0) - (progress?.currentTime ?: 0.0))),
                        fontSize = 13.sp, color = Palette.subtle,
                    )
                }
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    ActionIcon(
                        if (favorite) Icons.Default.Favorite else Icons.Default.FavoriteBorder,
                        stringResource(if (favorite) R.string.remove_favorite else R.string.add_favorite), active = favorite,
                    ) { books.toggleFavorite(item) }
                    if (!item.isPodcast) {
                        BookDownloadButton(item)
                        MoreMenu { close ->
                            val finished = progress?.isFinished == true
                            MenuItem(if (finished) R.string.bk_mark_unfinished else R.string.bk_mark_finished, Icons.Default.CheckCircle) {
                                close()
                                scope.launch {
                                    try { books.setFinished(item, null, !finished) }
                                    catch (e: CancellationException) { throw e }
                                    catch (e: Exception) { snackbar.showSnackbar(e.bookErrorText(context)) }
                                }
                            }
                        }
                    }
                    Spacer(Modifier.weight(1f))
                    if (!item.isPodcast) PlayCircle(here && player.playing) {
                        if (here) BookPlayer.toggle() else playBook(context, nav, item)
                    }
                }
            }
        },
        refreshing = refreshing, onRefresh = onRefresh,
    ) {
        if (item.isPodcast) {
            val episodes = item.media.episodes.orEmpty().sortedByDescending { it.publishedAt ?: 0.0 }
            item(key = "episodes-title") {
                Text(stringResource(R.string.bk_episodes), Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp), fontSize = 18.sp, fontWeight = FontWeight.Bold)
            }
            items(episodes.size, key = { "ep-" + episodes[it].id }) { i ->
                BookEpisodeRow(item, episodes[i], highlighted = episodes[i].id == episodeId || player.episode?.id == episodes[i].id)
            }
        } else {
            val chapters = item.media.chapters.orEmpty()
            if (chapters.isNotEmpty()) item(key = "chapters") {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 4.dp).height(48.dp)
                        .clip(RoundedCornerShape(Palette.corner(10.dp))).background(Palette.elevated)
                        .clickable { showChapters = true }.padding(horizontal = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.AutoMirrored.Filled.List, null, tint = Palette.subtle, modifier = Modifier.size(24.dp))
                    Spacer(Modifier.width(10.dp))
                    Text(stringResource(R.string.bk_chapters), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                    Text("${chapters.size}", fontSize = 14.sp, color = Palette.subtle)
                    Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = Palette.subtle)
                }
            }
        }
        if (description.isNotEmpty()) item(key = "description") {
            Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(description, fontSize = 14.sp, color = Palette.subtle, maxLines = if (expanded) Int.MAX_VALUE else 4, overflow = TextOverflow.Ellipsis)
                Text(
                    stringResource(if (expanded) R.string.bk_less else R.string.bk_more), Modifier.clickable { expanded = !expanded },
                    fontSize = 13.sp, fontWeight = FontWeight.SemiBold,
                )
            }
        }
        if (more.isNotEmpty() && author != null) item(key = "more-by") { BookShelf(stringResource(R.string.bk_more_by, author.name), more) }
    }

    if (showChapters) ModalBottomSheet(onDismissRequest = { showChapters = false }) {
        val chapters = item.media.chapters.orEmpty()
        val current = if (player.item?.id == item.id) player.chapterIndex else -1
        Text(stringResource(R.string.bk_chapters), Modifier.padding(horizontal = 16.dp, vertical = 8.dp), fontSize = 18.sp, fontWeight = FontWeight.Bold)
        LazyColumn(Modifier.navigationBarsPadding()) {
            itemsIndexed(chapters) { index, c ->
                Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 11.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        c.title ?: "", Modifier.weight(1f), fontSize = 15.sp, maxLines = 2, overflow = TextOverflow.Ellipsis,
                        fontWeight = if (index == current) FontWeight.SemiBold else FontWeight.Normal,
                        color = if (index == current) Palette.accent else Color.White,
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(bookClock(c.end - c.start), fontSize = 13.sp, color = Palette.subtle)
                }
            }
        }
    }
}

/** One episode of a podcast: title, length or "Finished", progress, play and download. Used on the podcast's page. */
@Composable
private fun BookEpisodeRow(item: ABSItem, episode: ABSEpisode, highlighted: Boolean) {
    val context = LocalContext.current
    val nav = LocalNav.current
    val progress = rememberBookProgressByKey(app.tonalo.android.data.ABSProgress.key(item.id, episode.id))
    val finished = progress?.isFinished == true
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically) {
        Row(
            Modifier.weight(1f).clickable { playBook(context, nav, item, episode) },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    episode.title ?: "", fontSize = 15.sp, fontWeight = FontWeight.Medium, maxLines = 2, overflow = TextOverflow.Ellipsis,
                    color = if (highlighted) Palette.accent else Color.White,
                )
                val sub = if (finished) stringResource(R.string.bk_finished) else if (episode.length > 0) bookLength(episode.length) else ""
                if (sub.isNotEmpty()) Text(sub, fontSize = 12.sp, color = Palette.subtle)
                val value = progress?.progress ?: 0.0
                if (value > 0 && !finished) BookProgressBar(value)
            }
            Spacer(Modifier.width(8.dp))
            Icon(Icons.Default.PlayCircleOutline, stringResource(R.string.cd_play), modifier = Modifier.size(28.dp))
        }
        Spacer(Modifier.width(6.dp))
        BookDownloadButton(item, episode, 24.dp)
    }
}
