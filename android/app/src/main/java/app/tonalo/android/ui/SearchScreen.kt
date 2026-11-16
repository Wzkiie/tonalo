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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.offset
import androidx.compose.ui.draw.shadow
import app.tonalo.android.R
import app.tonalo.android.data.SubsonicClient
import app.tonalo.android.data.Song
import app.tonalo.android.data.RecentSearches
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.material.icons.filled.History
import androidx.compose.foundation.layout.heightIn
import app.tonalo.android.data.ABSSearchResults
import app.tonalo.android.data.Album
import app.tonalo.android.data.Genre
import app.tonalo.android.data.SearchBody
import app.tonalo.android.tonalo
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay

/**
 * Search like the iPhone's: title, the white field that stays at the top while scrolling, genre tiles until two
 * letters are typed, then artists, songs and albums in one list.
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun SearchScreen() {
    val nav = LocalNav.current
    val player = LocalPlayer.current
    var query by rememberSaveable { mutableStateOf("") }
    val text = query.trim()
    val focus = androidx.compose.ui.platform.LocalFocusManager.current
    val keyboard = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
    val list = androidx.compose.foundation.lazy.rememberLazyListState()
    OnReselect { list.animateScrollToItem(0) }
    // Goes up to ask again – pulling down
    var attempt by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(0) }
    val app = androidx.compose.ui.platform.LocalContext.current.tonalo
    val account by app.current.collectAsState()
    // An account with audiobooks only has no music server: only the audiobooks are searched
    val hasMusic = account?.hasMusic != false
    val booksConnected by app.books.connected.collectAsState()
    var focused by androidx.compose.runtime.remember { mutableStateOf(false) }
    var recent by androidx.compose.runtime.remember(account?.id) { mutableStateOf(RecentSearches.load(app, account?.id)) }
    val suggestedTitle = stringResource(R.string.suggested_for_you)
    // Songs that fit what was listened to lately, shown while the field is empty. Nothing if the server knows no similar ones.
    val suggested by produceState<List<Song>>(emptyList(), account?.id, attempt) {
        if (!hasMusic) return@produceState
        value = try { app.client()?.let { suggestedSongs(it) }.orEmpty() } catch (e: CancellationException) { throw e } catch (e: Exception) { emptyList() }
    }
    val loader = if (hasMusic && text.length >= 2) rememberLoad("search", text, refresh = attempt) { c -> delay(200); c.search(text) } else null
    // The same wait for typing to pause as the music search
    val found by produceState<ABSSearchResults?>(null, text, attempt, booksConnected) {
        value = null
        if (!booksConnected || text.length < 2) return@produceState
        delay(200)
        value = try {
            app.books.search(text)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            ABSSearchResults()
        }
    }

    // Searches that found something and stayed for a moment are worth keeping, not every half-typed word
    val foundMusic = (loader?.state as? Load.Ready<SearchBody>)?.value?.let { it.artist.orEmpty().isNotEmpty() || it.album.orEmpty().isNotEmpty() || it.song.orEmpty().isNotEmpty() } == true
    val foundBooks = found?.let { it.items.isNotEmpty() || it.authors.isNotEmpty() || it.series.isNotEmpty() || it.narrators.isNotEmpty() } == true
    LaunchedEffect(text, foundMusic, foundBooks) {
        if (text.length >= 2 && (foundMusic || foundBooks)) {
            delay(1_500)
            recent = RecentSearches.remember(app, account?.id, text)
        }
    }

    Refreshable(refreshing = loader?.refreshing ?: false, onRefresh = { attempt++ }) {
    LazyColumn(Modifier.fillMaxSize(), state = list, contentPadding = PaddingValues(bottom = 24.dp)) {
        item {
            Row(Modifier.fillMaxWidth().statusBarsPadding().padding(start = 16.dp, top = 8.dp, bottom = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                Avatar(32.dp)
                Spacer(Modifier.width(12.dp))
                Text(stringResource(R.string.tab_search), fontSize = 24.sp, fontWeight = FontWeight.Bold)
            }
        }
        stickyHeader {
            Row(
                Modifier.background(Palette.canvas).padding(start = 16.dp, end = 16.dp, bottom = 12.dp).fillMaxWidth().height(46.dp)
                    .clip(RoundedCornerShape(8.dp)).background(Color.White).padding(horizontal = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Default.Search, null, tint = Color.Black, modifier = Modifier.size(22.dp))
                Spacer(Modifier.size(10.dp))
                Box(Modifier.weight(1f)) {
                    if (query.isEmpty()) Text(stringResource(R.string.search_prompt), color = Color(0xFF595959), fontSize = 16.sp, fontWeight = FontWeight.Medium)
                    BasicTextField(
                        query, { query = it }, Modifier.fillMaxWidth().onFocusChanged { focused = it.isFocused },
                        singleLine = true,
                        textStyle = TextStyle(color = Color.Black, fontSize = 16.sp, fontWeight = FontWeight.Medium),
                        cursorBrush = SolidColor(Color.Black),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                        keyboardActions = androidx.compose.foundation.text.KeyboardActions(onSearch = {
                            recent = RecentSearches.remember(app, account?.id, query)
                            keyboard?.hide(); focus.clearFocus()
                        }),
                    )
                }
                if (query.isNotEmpty()) IconButton(onClick = { query = "" }) { Icon(Icons.Default.Close, stringResource(R.string.cd_close), tint = Color.Black) }
            }
        }
        if (text.length < 2) {
            // Tapping into the field swaps the tiles for earlier searches and suggestions – as long as there are any
            val earlier = if (text.isEmpty()) recent else recent.filter { it.contains(text, ignoreCase = true) && !it.equals(text, ignoreCase = true) }
            val showSuggested = text.isEmpty() && suggested.isNotEmpty()
            if (focused && (earlier.isNotEmpty() || showSuggested)) {
                if (earlier.isNotEmpty()) {
                    item(key = "recent-head") {
                        Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(stringResource(R.string.recent_searches), fontSize = 17.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                            Text(stringResource(R.string.clear_all), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Palette.secondaryText,
                                modifier = Modifier.clip(RoundedCornerShape(6.dp)).clickable { recent = RecentSearches.forget(app, account?.id, null) }.padding(8.dp))
                        }
                    }
                    items(earlier, key = { "recent-" + it }) { s ->
                        Row(
                            Modifier.fillMaxWidth().heightIn(min = 48.dp)
                                .clickable { query = s; recent = RecentSearches.remember(app, account?.id, s); focus.clearFocus() }.padding(start = 16.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(Icons.Default.History, null, tint = Palette.secondaryText, modifier = Modifier.size(20.dp))
                            Spacer(Modifier.width(14.dp))
                            Text(s, fontSize = 16.sp, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                            IconButton(onClick = { recent = RecentSearches.forget(app, account?.id, s) }) {
                                Icon(Icons.Default.Close, stringResource(R.string.remove), tint = Palette.secondaryText, modifier = Modifier.size(18.dp))
                            }
                        }
                    }
                }
                if (showSuggested) {
                    item(key = "suggested-head") {
                        Text(stringResource(R.string.suggested_for_you), fontSize = 17.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 4.dp))
                    }
                    items(suggested.size, key = { "suggested-" + suggested[it].id }) { i ->
                        SongRow(suggested[i], showCover = true) { player.play(suggested, i, context = suggestedTitle, contextId = "search") }
                    }
                }
            } else {
                // The genres are the music server's: an account with audiobooks only has nothing to browse here
                if (hasMusic) browseAll(attempt)
            }
            return@LazyColumn
        }
        val music = (loader?.state as? Load.Ready<SearchBody>)?.value
        val artists = music?.artist.orEmpty()
        val songs = music?.song.orEmpty()
        val albums = music?.album.orEmpty()
        items(artists, key = { "r" + it.id }) { a ->
            Box(Modifier.padding(horizontal = 16.dp, vertical = 6.dp)) {
                ItemRow(a.name, stringResource(R.string.artist), onClick = { nav.open(artistRoute(a.id)) }) {
                    FillCover(a.coverArt ?: "ar-${a.id}", Modifier.size(52.dp), 26.dp, Icons.Default.Person)
                }
            }
        }
        items(songs.size, key = { "s" + songs[it].id + it }) { i -> SongRow(songs[i], showCover = true) { player.play(songs, i, context = text, contextId = "search") } }
        items(albums, key = { "a" + it.id }) { a ->
            Box(Modifier.padding(horizontal = 16.dp, vertical = 6.dp)) {
                ItemRow(a.name, listOfNotNull(stringResource(R.string.album), a.artist).joinToString(" • "), onClick = { nav.open(albumRoute(a.id)) }) {
                    FillCover(a.coverArt, Modifier.size(52.dp), 2.dp)
                }
            }
        }
        // Each server shows its results as they arrive; audiobooks and podcasts follow the music
        val books = found
        if (books != null) bookSearchItems(nav, books)
        val booksEmpty = books == null || (books.items.isEmpty() && books.authors.isEmpty() && books.series.isEmpty() && books.narrators.isEmpty())
        val musicEmpty = artists.isEmpty() && songs.isEmpty() && albums.isEmpty()
        if (musicEmpty && booksEmpty) {
            val waiting = loader?.state is Load.Loading || (booksConnected && books == null)
            val failed = loader?.state as? Load.Failed
            if (waiting) item(key = "waiting") {
                Box(Modifier.fillMaxWidth().padding(top = 60.dp), contentAlignment = Alignment.Center) { androidx.compose.material3.CircularProgressIndicator() }
            } else if (failed != null) item(key = "failed") {
                ErrorView(failed.message, loader?.reload ?: {})
            } else item(key = "none") {
                Column(Modifier.fillMaxWidth().padding(top = 60.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(stringResource(R.string.no_results_for, text), fontSize = 18.sp, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.height(8.dp))
                    Text(stringResource(R.string.no_results_hint), color = Palette.secondaryText)
                }
            }
        }
    }
    }
}

/** "Browse all": colored tiles, one per genre (the 30 with the most albums), each with a tilted cover from that genre. */
private fun androidx.compose.foundation.lazy.LazyListScope.browseAll(refresh: Int) {
    item {
        val nav = LocalNav.current
        val genres = rememberLoad("browse-genres", cached = { c -> c.cached("getGenres")?.genres?.genre }, refresh = refresh) { c -> c.genres() }
        val list = (genres.state as? Load.Ready<List<Genre>>)?.value.orEmpty()
            .filter { it.value.isNotBlank() && (it.albumCount ?: 0) > 0 }.sortedByDescending { it.albumCount ?: 0 }.take(30)
        Column(Modifier.padding(horizontal = 16.dp)) {
            Text(stringResource(R.string.browse_all_ios), Modifier.padding(top = 8.dp, bottom = 14.dp), fontSize = 17.sp, fontWeight = FontWeight.Bold)
            list.chunked(2).forEach { row ->
                Row(Modifier.padding(bottom = 12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    row.forEach { g -> GenreTile(g, Modifier.weight(1f)) { nav.open(genreRoute(g.value)) } }
                    if (row.size == 1) Spacer(Modifier.weight(1f))
                }
            }
            if (genres.state is Load.Loading) Box(Modifier.fillMaxWidth().padding(30.dp), contentAlignment = Alignment.Center) { androidx.compose.material3.CircularProgressIndicator() }
        }
    }
}

/** The iPhone's hand-made genre colors: neighbors rarely look alike. */
private val genreColors = listOf("#C2410C", "#7C3AED", "#0E7490", "#BE185D", "#1D4ED8", "#B45309", "#4D7C0F", "#9D174D",
    "#0F766E", "#6D28D9", "#B91C1C", "#1E40AF", "#A16207", "#7E22CE", "#15803D", "#C026D3")

private fun genreColor(name: String): Color {
    var h = 7
    name.lowercase().forEach { h = (h * 31 + it.code) and 0x7fffffff }
    return Palette.parse(genreColors[h % genreColors.size]) ?: Color.Gray
}

@Composable
private fun GenreTile(genre: Genre, modifier: Modifier, onClick: () -> Unit) {
    val cover = rememberLoad("genre-cover", genre.value) { c -> c.albumList("byGenre", size = 1, genre = genre.value).firstOrNull() }
    val album = (cover.state as? Load.Ready<Album?>)?.value
    Box(modifier.height(100.dp).clip(RoundedCornerShape(Palette.corner(6.dp))).background(genreColor(genre.value)).clickable(onClick = onClick)) {
        if (album != null) Box(Modifier.align(Alignment.BottomEnd).offset(x = 16.dp, y = 6.dp).rotate(25f).shadow(4.dp, RoundedCornerShape(4.dp))) {
            Cover(album.coverArt, 70.dp, corner = 4.dp, pixels = 200)
        }
        Text(genre.value, Modifier.padding(12.dp).padding(end = 40.dp), fontWeight = FontWeight.Bold, fontSize = 16.sp, color = Color.White, maxLines = 2)
    }
}

/**
 * Songs similar to the last few albums played, without the songs of those albums. It takes the server's own idea of
 * "similar" (the same one the song radio uses), so it is nothing when the server has none.
 */
private suspend fun suggestedSongs(client: SubsonicClient): List<Song> {
    val albums = client.albumList("recent", size = 4)
    if (albums.isEmpty()) return emptyList()
    val heard = HashSet<String>()
    val seeds = ArrayList<Song>()
    for (a in albums.take(3)) {
        val songs = runCatching { client.album(a.id).song }.getOrNull().orEmpty()
        songs.forEach { heard += it.id }
        songs.randomOrNull()?.let { seeds += it }
    }
    val lists = seeds.map { client.similarSongs(it.id) }
    // One from each list in turn, so it isn't all about the newest album
    val out = ArrayList<Song>()
    val seen = HashSet(heard)
    var i = 0
    while (out.size < 10 && lists.any { i < it.size }) {
        for (l in lists) if (i < l.size && out.size < 10 && seen.add(l[i].id)) out += l[i]
        i++
    }
    return out
}
