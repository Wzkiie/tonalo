package app.tonalo.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
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
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.automirrored.filled.PlaylistAdd
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Radio
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.text.HtmlCompat
import app.tonalo.android.R
import app.tonalo.android.data.Album
import app.tonalo.android.data.Artist
import app.tonalo.android.data.ArtistInfo
import app.tonalo.android.data.Playlist
import app.tonalo.android.data.SearchBody
import app.tonalo.android.data.Song
import app.tonalo.android.dj.DJ
import app.tonalo.android.playback.Playback
import app.tonalo.android.tonalo
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch

fun durationText(seconds: Int): String {
    val m = seconds.coerceAtLeast(0) / 60
    return if (m < 60) "$m min" else "${m / 60} h ${m % 60} min"
}

/**
 * The iPhone's layout for albums, playlists and favorites: a 250 dp cover with a shadow on a gradient in the cover's
 * color, the title left-aligned, a few info lines, the action row, then the songs.
 */
@Composable
fun DetailPage(
    coverArt: String?,
    title: String,
    art: @Composable () -> Unit,
    info: @Composable ColumnScope.() -> Unit,
    actions: @Composable () -> Unit,
    refreshing: Boolean = false,
    onRefresh: (() -> Unit)? = null,
    content: LazyListScope.() -> Unit,
) {
    val tint = rememberCoverColor(coverArt)
    Box(Modifier.fillMaxSize().background(Palette.canvas)) {
        val list: @Composable () -> Unit = {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp)) {
            item {
                Box {
                    Box(Modifier.fillMaxWidth().height(560.dp).background(Brush.verticalGradient(listOf(tint ?: Color(0xFF333333), Palette.canvas))))
                    Column(Modifier.statusBarsPadding().padding(top = 56.dp).padding(horizontal = 16.dp)) {
                        Box(Modifier.fillMaxWidth().padding(top = 4.dp, bottom = 10.dp), contentAlignment = Alignment.Center) {
                            Box(Modifier.size(250.dp).shadow(18.dp, RoundedCornerShape(Palette.corner(4.dp)))) { art() }
                        }
                        Text(title, fontSize = 24.sp, fontWeight = FontWeight.Bold, maxLines = 3, overflow = TextOverflow.Ellipsis, lineHeight = 28.sp)
                        Column(Modifier.padding(top = 10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) { info() }
                        Box(Modifier.padding(vertical = 8.dp)) { actions() }
                    }
                }
            }
            content()
        }
        }
        if (onRefresh != null) Refreshable(refreshing, onRefresh) { list() } else list()
        RoundBackButton()
    }
}

/** A gray line of the info under a title. */
@Composable
fun InfoText(text: String) = Text(text, fontSize = 13.sp, color = Palette.secondaryText)

/** Round picture and a bold name – the artist of an album, the owner of a playlist. */
@Composable
fun OwnerLine(name: String, picture: @Composable () -> Unit, onClick: (() -> Unit)? = null) {
    Row(Modifier.then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(24.dp)) { picture() }
        Spacer(Modifier.width(8.dp))
        Text(name, fontSize = 13.sp, fontWeight = FontWeight.Bold)
    }
}

/** Gray icon button for the action row under a title. */
@Composable
fun ActionIcon(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, active: Boolean = false, onClick: () -> Unit) {
    IconButton(onClick = onClick) { Icon(icon, label, tint = if (active) Palette.accent else Palette.secondaryText, modifier = Modifier.size(26.dp)) }
}

/** Heart · download · … on the left, shuffle and play on the right. */
@Composable
fun ActionRow(left: @Composable () -> Unit, playing: Boolean, play: () -> Unit, shuffle: () -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        left()
        Spacer(Modifier.weight(1f))
        PlayButtons(playing, play, shuffle)
    }
}

/** The "…" button of a page, with its menu. */
@Composable
fun MoreMenu(items: @Composable (close: () -> Unit) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        IconButton(onClick = { open = true }) { Icon(Icons.Default.MoreHoriz, stringResource(R.string.cd_more), tint = Palette.secondaryText, modifier = Modifier.size(26.dp)) }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) { items { open = false } }
    }
}

/** The songs of a page, ten dp apart like on the iPhone. */
private fun LazyListScope.songs(songs: List<Song>, showCover: Boolean, onPlay: (Int) -> Unit, extraMenu: ((Int) -> (@Composable (close: () -> Unit) -> Unit)?)? = null) {
    items(songs.size, key = { songs[it].id + "-" + it }) { i ->
        SongRow(songs[i], showCover = showCover, extraMenu = extraMenu?.invoke(i)) { onPlay(i) }
    }
}

@Composable
fun AlbumScreen(id: String) {
    val context = LocalContext.current
    val nav = LocalNav.current
    val player = LocalPlayer.current
    val state by player.state.collectAsState()
    val scope = rememberCoroutineScope()
    val djOn by DJ.enabled.collectAsState()
    val loader = rememberLoad("album", id, cached = { c -> c.cached("getAlbum", "id" to id)?.album }) { it.album(id) }
    var pick by remember { mutableStateOf(false) }

    when (val s = loader.state) {
        is Load.Ready -> {
            val a = s.value
            val songs = a.song.orEmpty()
            val starred = rememberStarred(a.id, a.starred)
            val cid = "a${a.id}"
            val playing = state.contextId == cid && state.isPlaying
            DetailPage(
                a.coverArt, a.name,
                art = { Cover(a.coverArt, 250.dp, corner = Palette.corner(4.dp), pixels = 600) },
                info = {
                    a.artistId?.let { aid ->
                        OwnerLine(a.artist ?: "", { FillCover("ar-$aid", Modifier.fillMaxSize(), 12.dp, Icons.Default.Person) }) { nav.open(artistRoute(aid)) }
                    }
                    InfoText(listOfNotNull(stringResource(R.string.album), a.year?.toString()).joinToString(" • "))
                },
                actions = {
                    ActionRow(
                        left = {
                            ActionIcon(if (starred) Icons.Default.Favorite else Icons.Default.FavoriteBorder,
                                stringResource(if (starred) R.string.remove_favorite else R.string.add_favorite), active = starred) {
                                val on = !starred
                                Favorites.set(a.id, on)
                                scope.launch { try { context.tonalo.client()?.setStar(albumId = a.id, on = on) } catch (e: CancellationException) { throw e } catch (e: Exception) { Favorites.set(a.id, !on) } }
                            }
                            DownloadButton(songs)
                            MoreMenu { close ->
                                MenuItem(R.string.add_to_queue, Icons.AutoMirrored.Filled.QueueMusic) { close(); player.enqueue(songs) }
                                MenuItem(R.string.add_to_playlist, Icons.AutoMirrored.Filled.PlaylistAdd) { close(); pick = true }
                                if (djOn && DJ.configured) MenuItem(R.string.dj_with_album, Icons.Default.AutoAwesome) {
                                    close(); songs.firstOrNull()?.let { s -> scope.launch { runCatching { DJ.takeOver(s) } } }
                                }
                                a.artistId?.let { aid -> MenuItem(R.string.go_to_artist, Icons.Default.Person) { close(); nav.open(artistRoute(aid)) } }
                            }
                        },
                        playing = playing,
                        play = { if (state.contextId == cid) player.toggle() else player.play(songs, context = a.name, contextId = cid) },
                        shuffle = { player.play(songs, shuffled = true, context = a.name, contextId = cid) },
                    )
                },
                refreshing = loader.refreshing, onRefresh = loader.reload,
            ) {
                songs(songs, showCover = false, onPlay = { i -> player.play(songs, i, context = a.name, contextId = cid) })
                item {
                    Text(listOfNotNull(pluralString(R.plurals.song_count, songs.size), a.duration?.let { durationText(it) }).joinToString(" • "),
                        Modifier.padding(horizontal = 16.dp, vertical = 12.dp), fontSize = 13.sp, color = Palette.secondaryText)
                }
            }
            if (pick) PlaylistPicker(songs) { pick = false }
        }
        else -> Box(Modifier.fillMaxSize()) { LoadView(loader) {}; RoundBackButton() }
    }
}

@Composable
fun PlaylistScreen(id: String) {
    val context = LocalContext.current
    val nav = LocalNav.current
    val player = LocalPlayer.current
    val state by player.state.collectAsState()
    val snackbar = LocalSnackbar.current
    val scope = rememberCoroutineScope()
    val account by context.tonalo.current.collectAsState()
    val djOn by DJ.enabled.collectAsState()
    // Reloads when songs were added to this playlist from somewhere else (a song's menu, "Add to other playlist")
    val plVersion by Playlists.version.collectAsState()
    val loader = rememberLoad("playlist", id, cached = { c -> c.cached("getPlaylist", "id" to id)?.playlist }, refresh = plVersion) { it.playlist(id) }
    var confirmDelete by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf(false) }
    var newName by remember { mutableStateOf("") }
    var pick by remember { mutableStateOf(false) }
    var removing by remember { mutableStateOf(false) }
    val order = remember { mutableStateListOf<Song>() }

    val p = (loader.state as? Load.Ready<Playlist>)?.value
        ?: return Box(Modifier.fillMaxSize()) { LoadView(loader) {}; RoundBackButton() }
    val songs = p.entry.orEmpty()
    val owned = p.owner == null || p.owner == account?.username
    val editable = owned && p.readonly != true
    val cid = "p${p.id}"
    val playing = state.contextId == cid && state.isPlaying

    DetailPage(
        p.coverArt, p.name,
        art = { Cover(p.coverArt, 250.dp, corner = Palette.corner(4.dp), pixels = 600, placeholder = Icons.AutoMirrored.Filled.QueueMusic) },
        info = {
            p.comment?.takeIf { it.isNotBlank() }?.let { Text(it, fontSize = 13.sp, color = Palette.secondaryText, maxLines = 3, overflow = TextOverflow.Ellipsis) }
            p.owner?.let { o -> OwnerLine(o, { NameAvatar(o, 24.dp) }) }
            if (p.readonly == true && owned) Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Lock, null, tint = Palette.secondaryText, modifier = Modifier.size(13.dp))
                Spacer(Modifier.width(6.dp))
                InfoText(stringResource(R.string.playlist_managed))
            }
            InfoText(listOfNotNull(pluralString(R.plurals.song_count, songs.size), p.duration?.let { durationText(it) }).joinToString(" • "))
        },
        actions = {
            ActionRow(
                left = {
                    DownloadButton(songs)
                    if (editing) TextButton(onClick = {
                        val ids = order.map { it.id }
                        editing = false
                        scope.launch {
                            try { context.tonalo.client()?.replacePlaylistSongs(p.id, ids); loader.reload() }
                            catch (e: CancellationException) { throw e } catch (e: Exception) { snackbar.showSnackbar(errorText(context, e)) }
                        }
                    }) { Text(stringResource(R.string.done), color = Palette.accent) }
                    else MoreMenu { close ->
                        MenuItem(R.string.add_to_queue, Icons.AutoMirrored.Filled.QueueMusic) { close(); player.enqueue(songs) }
                        MenuItem(R.string.add_to_other_playlist, Icons.AutoMirrored.Filled.PlaylistAdd) { close(); pick = true }
                        if (djOn && DJ.configured) MenuItem(R.string.dj_with_playlist, Icons.Default.AutoAwesome) {
                            close(); songs.firstOrNull()?.let { s -> scope.launch { runCatching { DJ.takeOver(s) } } }
                        }
                        if (owned) {
                            if (editable) MenuItem(R.string.edit_songs, Icons.AutoMirrored.Filled.List) { close(); order.clear(); order.addAll(songs); editing = true }
                            MenuItem(R.string.rename, Icons.Default.Edit) { close(); newName = p.name; renaming = true }
                            MenuItem(R.string.delete_playlist, Icons.Default.Delete) { close(); confirmDelete = true }
                        }
                    }
                },
                playing = playing,
                play = { if (state.contextId == cid) player.toggle() else player.play(songs, context = p.name, contextId = cid) },
                shuffle = { player.play(songs, shuffled = true, context = p.name, contextId = cid) },
            )
        },
        refreshing = loader.refreshing, onRefresh = loader.reload,
    ) {
        if (editing) {
            items(order.size, key = { "e" + order[it].id + "-" + it }) { i ->
                val s = order[i]
                Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = { order.removeAt(i) }) { Icon(Icons.Default.Close, stringResource(R.string.remove_from_playlist), tint = Color(0xFFFF5A5F)) }
                    Cover(s.coverArt, 44.dp, corner = 2.dp, pixels = 120)
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f)) {
                        Text(s.title, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(s.artist ?: "", fontSize = 13.sp, color = Palette.secondaryText, maxLines = 1)
                    }
                    IconButton(onClick = { order.add(i - 1, order.removeAt(i)) }, enabled = i > 0) { Icon(Icons.Default.KeyboardArrowUp, stringResource(R.string.cd_move_up)) }
                    IconButton(onClick = { order.add(i + 1, order.removeAt(i)) }, enabled = i < order.lastIndex) { Icon(Icons.Default.KeyboardArrowDown, stringResource(R.string.cd_move_down)) }
                }
            }
        } else {
            songs(songs, showCover = true, onPlay = { i -> player.play(songs, i, context = p.name, contextId = cid) }, extraMenu = { i ->
                if (!editable) null else { close ->
                    MenuItem(R.string.remove_from_playlist, Icons.Default.Delete) {
                        close()
                        // One removal at a time, and not before the list has reloaded: the index would point at another song
                        if (removing || loader.refreshing) return@MenuItem
                        removing = true
                        scope.launch {
                            try { context.tonalo.client()?.updatePlaylist(p.id, removeIndexes = listOf(i)); Playlists.changed(); loader.reload() }
                            catch (e: CancellationException) { throw e } catch (e: Exception) { snackbar.showSnackbar(errorText(context, e)) }
                            finally { removing = false }
                        }
                    }
                }
            })
            if (songs.isEmpty()) item { Text(stringResource(R.string.playlist_empty), Modifier.padding(16.dp), fontSize = 14.sp, color = Palette.secondaryText) }
        }
    }
    if (pick) PlaylistPicker(songs) { pick = false }
    if (renaming) AlertDialog(
        onDismissRequest = { renaming = false },
        containerColor = Palette.elevated,
        title = { Text(stringResource(R.string.rename_playlist)) },
        text = { OutlinedTextField(newName, { newName = it }, singleLine = true) },
        confirmButton = {
            TextButton(onClick = {
                renaming = false
                val n = newName.trim()
                if (n.isNotEmpty()) scope.launch {
                    try { context.tonalo.client()?.updatePlaylist(p.id, name = n); Playlists.changed(); loader.reload() }
                    catch (e: CancellationException) { throw e } catch (e: Exception) { snackbar.showSnackbar(errorText(context, e)) }
                }
            }) { Text(stringResource(R.string.save)) }
        },
        dismissButton = { TextButton(onClick = { renaming = false }) { Text(stringResource(R.string.cancel)) } },
    )
    if (confirmDelete) AlertDialog(
        onDismissRequest = { confirmDelete = false },
        containerColor = Palette.elevated,
        title = { Text(stringResource(R.string.delete_playlist_q, p.name)) },
        text = { Text(stringResource(R.string.delete_playlist_info)) },
        confirmButton = {
            TextButton(onClick = {
                confirmDelete = false
                scope.launch {
                    try {
                        context.tonalo.client()?.deletePlaylist(p.id)
                        Playlists.deleted(p.id)
                        // Leave the page first; the note comes from a scope that outlives it
                        nav.popBackStack()
                        val note = context.getString(R.string.playlist_deleted)
                        context.tonalo.scope.launch { snackbar.showSnackbar(note) }
                    } catch (e: CancellationException) { throw e } catch (e: Exception) { snackbar.showSnackbar(errorText(context, e)) }
                }
            }) { Text(stringResource(R.string.delete_playlist), color = Color(0xFFFF5A5F)) }
        },
        dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text(stringResource(R.string.cancel)) } },
    )
}

/** Favorite songs, laid out like a playlist. */
@Composable
fun FavoritesScreen() {
    val context = LocalContext.current
    val player = LocalPlayer.current
    val state by player.state.collectAsState()
    val account by context.tonalo.current.collectAsState()
    val overrides by Favorites.overrides.collectAsState()
    // Also when a song gets a heart elsewhere (the player, a song's menu) while this page is open: it isn't in the list yet
    val hearts = overrides.filterValues { it }.keys.sorted().hashCode()
    val loader = rememberLoad("favorites", cached = { c -> c.cached("getStarred2")?.starred2 }, refresh = hearts) { it.starred() }
    val name = stringResource(R.string.favorite_songs)
    // A heart removed here leaves the list at once
    val list = ((loader.state as? Load.Ready<SearchBody>)?.value?.song.orEmpty()).filter { overrides[it.id] ?: true }
    val playing = state.contextId == "favorites" && state.isPlaying
    DetailPage(
        null, name,
        art = { FavoritesArt(Modifier.fillMaxSize(), corner = Palette.corner(4.dp)) },
        info = {
            account?.username?.let { u -> OwnerLine(u, { NameAvatar(u, 24.dp) }) }
            InfoText(pluralString(R.plurals.song_count, list.size))
        },
        actions = {
            ActionRow(
                left = { DownloadButton(list) },
                playing = playing,
                play = { if (state.contextId == "favorites") player.toggle() else player.play(list, context = name, contextId = "favorites") },
                shuffle = { player.play(list, shuffled = true, context = name, contextId = "favorites") },
            )
        },
        refreshing = loader.refreshing, onRefresh = loader.reload,
    ) {
        when (val s = loader.state) {
            is Load.Loading -> item { Box(Modifier.fillMaxWidth().padding(40.dp), contentAlignment = Alignment.Center) { androidx.compose.material3.CircularProgressIndicator() } }
            is Load.Failed -> item { ErrorView(s.message, loader.reload) }
            else -> if (list.isEmpty()) item { Text(stringResource(R.string.no_favorites), Modifier.fillMaxWidth().padding(40.dp), color = Palette.secondaryText) }
        }
        songs(list, showCover = true, onPlay = { i -> player.play(list, i, context = name, contextId = "favorites") })
    }
}

/**
 * An artist like on the iPhone: the picture across the whole width with the name on it, popular songs
 * (or the ones you played most), the discography, similar artists and a short biography.
 */
@Composable
fun ArtistScreen(id: String) {
    val context = LocalContext.current
    val player = LocalPlayer.current
    val state by player.state.collectAsState()
    val snackbar = LocalSnackbar.current
    val scope = rememberCoroutineScope()
    val loader = rememberLoad("artist", id, cached = { c -> c.cached("getArtist", "id" to id)?.artist }) { it.artist(id) }
    val artist = (loader.state as? Load.Ready<Artist>)?.value
        ?: return Box(Modifier.fillMaxSize()) { LoadView(loader) {}; RoundBackButton() }

    var top by remember(id) { mutableStateOf<List<Song>>(emptyList()) }
    var topIsOwn by remember(id) { mutableStateOf(false) }
    var info by remember(id) { mutableStateOf<ArtistInfo?>(null) }
    var showAll by remember(id) { mutableStateOf(false) }
    LaunchedEffect(id) {
        val c = context.tonalo.client() ?: return@LaunchedEffect
        info = runCatching { c.artistInfo(id) }.getOrNull()
        top = runCatching { c.topSongs(artist.name) }.getOrDefault(emptyList())
        if (top.isEmpty()) {
            // No top songs from the server (Navidrome needs Last.fm for them): the ones you played most instead
            val all = coroutineScope { artist.album.orEmpty().take(12).map { a -> async { runCatching { c.album(a.id).song.orEmpty() }.getOrDefault(emptyList()) } }.awaitAll().flatten() }
            top = all.filter { (it.playCount ?: 0) > 0 }.sortedByDescending { it.playCount ?: 0 }.take(10)
            topIsOwn = top.isNotEmpty()
        }
    }
    val albums = artist.album.orEmpty().sortedByDescending { it.year ?: 0 }
    val similar = info?.similarArtist.orEmpty().filter { it.id.isNotEmpty() && it.id != id }
    val bio = info?.biography?.let { HtmlCompat.fromHtml(it, HtmlCompat.FROM_HTML_MODE_COMPACT).toString().trim() }?.takeIf { it.isNotEmpty() }
    val starred = rememberStarred(artist.id, artist.starred)
    val cid = "r${artist.id}"
    val playing = state.contextId == cid && state.isPlaying
    fun playAll(shuffled: Boolean) = scope.launch {
        val c = context.tonalo.client() ?: return@launch
        val songs = albums.flatMap { a -> runCatching { c.album(a.id).song.orEmpty() }.getOrDefault(emptyList()) }
        player.play(songs, shuffled = shuffled, context = artist.name, contextId = cid)
    }

    Box(Modifier.fillMaxSize().background(Palette.canvas)) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp)) {
            item {
                Box(Modifier.fillMaxWidth().aspectRatio(1f)) {
                    FillCover(artist.coverArt ?: "ar-${artist.id}", Modifier.fillMaxSize(), 0.dp, Icons.Default.Person)
                    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.45f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.85f))))
                    Text(artist.name, Modifier.align(Alignment.BottomStart).padding(horizontal = 16.dp, vertical = 12.dp),
                        fontSize = 40.sp, lineHeight = 42.sp, fontWeight = FontWeight.Black, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
                Column(Modifier.padding(horizontal = 16.dp).padding(top = 16.dp)) {
                    InfoText(pluralString(R.plurals.album_count, albums.size))
                    Spacer(Modifier.height(8.dp))
                    ActionRow(
                        left = {
                            ActionIcon(if (starred) Icons.Default.Favorite else Icons.Default.FavoriteBorder,
                                stringResource(if (starred) R.string.remove_favorite else R.string.add_favorite), active = starred) {
                                val on = !starred
                                Favorites.set(artist.id, on)
                                scope.launch { try { context.tonalo.client()?.setStar(artistId = artist.id, on = on) } catch (e: CancellationException) { throw e } catch (e: Exception) { Favorites.set(artist.id, !on) } }
                            }
                            MoreMenu { close ->
                                MenuItem(R.string.artist_radio, Icons.Default.Radio) {
                                    close()
                                    scope.launch {
                                        val ok = Playback.service?.startRadio(context.getString(R.string.song_radio, artist.name), seedId = id, seeds = top.take(5)) ?: false
                                        if (!ok) snackbar.showSnackbar(context.getString(R.string.radio_failed))
                                    }
                                }
                            }
                        },
                        playing = playing,
                        play = { when { state.contextId == cid -> player.toggle(); top.isEmpty() -> playAll(false); else -> player.play(top, context = artist.name, contextId = cid) } },
                        shuffle = { playAll(true) },
                    )
                }
                if (top.isNotEmpty()) Text(stringResource(if (topIsOwn) R.string.your_most_played else R.string.popular),
                    Modifier.padding(start = 16.dp, top = 12.dp, bottom = 8.dp), fontSize = 22.sp, fontWeight = FontWeight.Bold)
            }
            val shown = top.take(if (showAll) 10 else 5)
            items(shown.size, key = { "top-" + shown[it].id }) { i -> SongRow(shown[i], number = i + 1) { player.play(top, i, context = artist.name, contextId = cid) } }
            if (top.size > 5) item {
                Text(stringResource(if (showAll) R.string.show_less else R.string.see_more), Modifier.clickable { showAll = !showAll }.padding(16.dp),
                    fontSize = 13.sp, fontWeight = FontWeight.Bold, color = Palette.secondaryText)
            }
            if (albums.isNotEmpty()) item {
                SectionHeader(stringResource(R.string.discography))
                LazyRow(contentPadding = HorizontalPadding, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    items(albums, key = { it.id }) { a -> AlbumCard(a) }
                }
            }
            if (similar.isNotEmpty()) item {
                SectionHeader(stringResource(R.string.fans_also_like))
                LazyRow(contentPadding = HorizontalPadding, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    items(similar, key = { it.id }) { a -> ArtistCard(Artist(a.id, a.name, a.coverArt)) }
                }
            }
            if (bio != null) item {
                Column(Modifier.padding(horizontal = 16.dp).padding(top = 28.dp)) {
                    Text(stringResource(R.string.about_artist), fontSize = 22.sp, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.height(10.dp))
                    Text(bio, Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(Palette.elevated).padding(16.dp),
                        fontSize = 14.sp, color = Color(0xFFD9D9D9), maxLines = 6, overflow = TextOverflow.Ellipsis)
                }
            }
        }
        RoundBackButton()
    }
}
