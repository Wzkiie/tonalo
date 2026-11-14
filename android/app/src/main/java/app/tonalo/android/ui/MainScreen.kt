package app.tonalo.android.ui

import android.net.Uri
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.windowInsetsTopHeight
import androidx.compose.foundation.layout.statusBars
import androidx.compose.material.icons.filled.LibraryBooks
import androidx.compose.material.icons.outlined.LibraryBooks
import app.tonalo.android.tonalo
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.ui.unit.sp
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Radio
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.LibraryMusic
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.rememberDrawerState
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.navigation.NavController
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import app.tonalo.android.R
import app.tonalo.android.link.JukeboxHost
import app.tonalo.android.link.TvLink
import app.tonalo.android.downloads.BookDownloads
import app.tonalo.android.downloads.Downloads
import app.tonalo.android.playback.BookPlayer
import app.tonalo.android.playback.PlayerConnection
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay

private data class Tab(val route: String, val label: Int, val icon: ImageVector, val selectedIcon: ImageVector)

private val tabs = listOf(
    Tab("home", R.string.tab_home, Icons.Outlined.Home, Icons.Default.Home),
    Tab("search", R.string.tab_search, Icons.Default.Search, Icons.Default.Search),
    Tab("library", R.string.your_library, Icons.Outlined.LibraryBooks, Icons.Default.LibraryBooks),
)

fun genreRoute(name: String) = "genre/" + Uri.encode(name.ifBlank { "_" })
fun albumRoute(id: String) = "album/" + Uri.encode(id)
fun artistRoute(id: String) = "artist/" + Uri.encode(id)
fun playlistRoute(id: String) = "playlist/" + Uri.encode(id)

/** Opens a page, but not a second time when it is already on top (double tap). */
fun NavController.open(route: String) = navigate(route) { launchSingleTop = true }

/** Pages that cover the whole screen, without tabs and mini player. */
private val fullScreenRoutes = setOf("player", "lyrics", "queue", "account/{id}", "account/new", "bookplayer")

/** The iPhone's tab bar: three icons with small labels, white when chosen, no highlight behind them. */
@Composable
private fun TabBar(chosen: String?, onTap: (Int) -> Unit) {
    Row(Modifier.fillMaxWidth().navigationBarsPadding().padding(top = 8.dp, bottom = 4.dp)) {
        tabs.forEachIndexed { i, tab ->
            val on = tab.route == chosen
            Column(
                Modifier.weight(1f).clickable(interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() }, indication = null) { onTap(i) },
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Icon(if (on) tab.selectedIcon else tab.icon, null, Modifier.size(26.dp), tint = if (on) Color.White else Palette.secondaryText)
                Spacer(Modifier.height(4.dp))
                Text(stringResource(tab.label), fontSize = 10.sp, fontWeight = FontWeight.Medium, color = if (on) Color.White else Palette.secondaryText)
            }
        }
    }
}

/** Short notes ("Added to favorites"): a white capsule with black text, like the iPhone's. */
@Composable
private fun Notices(host: SnackbarHostState) {
    SnackbarHost(host) { data ->
        Box(Modifier.fillMaxWidth().padding(bottom = 4.dp), contentAlignment = Alignment.Center) {
            Text(
                data.visuals.message, Modifier.clip(androidx.compose.foundation.shape.CircleShape).background(Color.White)
                    .padding(horizontal = 16.dp, vertical = 10.dp),
                color = Color.Black, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
            )
        }
    }
}

@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
fun MainScreen(player: PlayerConnection) {
    val nav = rememberNavController()
    val snackbar = remember { SnackbarHostState() }
    val entry by nav.currentBackStackEntryAsState()
    val fullScreen = entry?.destination?.route in fullScreenRoutes
    val bookState by BookPlayer.state.collectAsState()
    val bookActive = bookState.active

    val context = LocalContext.current
    // Notes from the TV link and this phone's Jukebox
    LaunchedEffect(Unit) {
        launch { TvLink.messages.collect { snackbar.showSnackbar(context.getString(R.string.not_answering, it)) } }
        launch { player.hostOnly.collect { snackbar.showSnackbar(context.getString(R.string.host_only)) } }
        launch {
            JukeboxHost.notes.collect { n ->
                snackbar.showSnackbar(when (n) {
                    is JukeboxHost.Note.Joined -> context.getString(R.string.joined_jukebox, n.name)
                    is JukeboxHost.Note.Added -> n.title?.let { context.getString(R.string.added_song_by, n.name, it) }
                        ?: context.getString(R.string.added_songs_by, n.name, n.count)
                    is JukeboxHost.Note.Skipped -> context.getString(R.string.skipped_by, n.name)
                })
            }
        }
    }
    val reselect = remember { androidx.compose.runtime.mutableStateListOf(0, 0, 0) }
    val startTab = remember { context.tonalo.settings.startTab.value.coerceIn(0, 2) }
    // The tab a page belongs to: the last tab page below it in the back stack (pages from the side menu keep the tab)
    val stack by nav.currentBackStack.collectAsState()
    val currentTab = stack.lastOrNull { e -> tabs.any { it.route == e.destination.route } }
        ?.let { e -> tabs.indexOfFirst { it.route == e.destination.route } } ?: startTab
    val ime = androidx.compose.foundation.layout.WindowInsets.isImeVisible
    var barHeight by remember { androidx.compose.runtime.mutableIntStateOf(0) }
    val density = androidx.compose.ui.platform.LocalDensity.current
    val drawer = rememberDrawerState(DrawerValue.Closed)
    val scope = rememberCoroutineScope()
    val openMenu: () -> Unit = { scope.launch { drawer.open() } }
    CompositionLocalProvider(LocalPlayer provides player, LocalNav provides nav, LocalSnackbar provides snackbar, LocalMenu provides openMenu) {
        JukeboxRequestDialog()
        // Back closes the side menu first
        androidx.activity.compose.BackHandler(enabled = drawer.isOpen) { scope.launch { drawer.close() } }
        ModalNavigationDrawer(
            drawerContent = {
                ProfileMenu(close = { scope.launch { drawer.close() } }) { route ->
                    scope.launch { drawer.close() }
                    nav.navigate(route) { launchSingleTop = true }
                }
            },
            drawerState = drawer,
            gesturesEnabled = drawer.isOpen,
            scrimColor = Color.Black.copy(alpha = 0.55f),
        ) {
        Box(Modifier.fillMaxSize().background(Palette.canvas)) {
            Box(Modifier.fillMaxSize().padding(bottom = if (fullScreen || ime) 0.dp else (with(density) { barHeight.toDp() } - 20.dp).coerceAtLeast(0.dp))) {
            NavHost(
                nav, startDestination = tabs[startTab].route,
                enterTransition = { fadeIn() }, exitTransition = { fadeOut() },
            ) {
                composable("home") { CompositionLocalProvider(LocalReselect provides reselect[0]) { HomeScreen() } }
                composable("search") { CompositionLocalProvider(LocalReselect provides reselect[1]) { SearchScreen() } }
                composable("library") { CompositionLocalProvider(LocalReselect provides reselect[2]) { LibraryScreen() } }
                composable("settings") { SettingsScreen() }
                composable("albums") { AlbumsScreen() }
                composable("albums/{type}") { AlbumsScreen(it.arguments?.getString("type") ?: "alphabeticalByName") }
                composable("artists") { ArtistsScreen() }
                composable("playlists") { PlaylistsScreen() }
                composable("genres") { GenresScreen() }
                composable("favorites") { FavoritesScreen() }
                composable("downloads") { DownloadsScreen() }
                composable("radio") { RadioScreen() }
                composable("devices") { DevicesScreen() }
                composable("dj") { DJScreen() }
                composable("dj/settings") { DJSettingsScreen() }
                composable("album/{id}") { AlbumScreen(it.arguments?.getString("id") ?: "") }
                composable("artist/{id}") { ArtistScreen(it.arguments?.getString("id") ?: "") }
                composable("playlist/{id}") { PlaylistScreen(it.arguments?.getString("id") ?: "") }
                composable("genre/{name}", arguments = listOf(navArgument("name") { type = NavType.StringType })) {
                    GenreScreen(it.arguments?.getString("name")?.takeUnless { n -> n == "_" } ?: "")
                }
                composable("player", enterTransition = { slideInVertically { it } }, exitTransition = { fadeOut() },
                    popExitTransition = { slideOutVertically { it } }) { PlayerScreen(onClose = { nav.popBackStack() }) }
                composable("lyrics", enterTransition = { slideInVertically { it } }, popExitTransition = { slideOutVertically { it } }) {
                    LyricsScreen(onClose = { nav.popBackStack() })
                }
                composable("queue", enterTransition = { slideInVertically { it } }, popExitTransition = { slideOutVertically { it } }) {
                    QueueScreen(onClose = { nav.popBackStack() })
                }
                composable("account/new") { LoginScreen(onClose = { nav.popBackStack() }) }
                composable("account/{id}") { AccountEditScreen(it.arguments?.getString("id") ?: "") }
                composable("settings/quality") { QualitySettingsScreen() }
                composable("settings/playback") { PlaybackSettingsScreen() }
                composable("settings/eq") { EqScreen() }
                composable("settings/offline") { OfflineSettingsScreen() }
                composable("settings/appearance") { AppearanceScreen() }
                composable("settings/news") { WhatsNewScreen() }
                composable("settings/bookplayback") { BookPlaybackSettingsScreen() }
                composable("settings/audiobookshelf") { AudiobookshelfSettingsScreen() }
                // Audiobooks and podcasts
                composable("books") { BooksBrowseScreen() }
                composable(
                    "book/{id}?episode={episode}",
                    arguments = listOf(
                        navArgument("id") { type = NavType.StringType },
                        navArgument("episode") { type = NavType.StringType; nullable = true; defaultValue = null },
                    ),
                ) { AudiobookScreen(it.arguments?.getString("id") ?: "", it.arguments?.getString("episode")) }
                composable("bookgroup/{kind}/{name}", arguments = listOf(navArgument("kind") { type = NavType.StringType }, navArgument("name") { type = NavType.StringType })) {
                    BookGroupScreen(it.arguments?.getString("kind") ?: "", it.arguments?.getString("name")?.takeUnless { n -> n == "_" } ?: "")
                }
                composable("bookauthor/{id}") { BookAuthorScreen(it.arguments?.getString("id") ?: "") }
                composable("bookplayer", enterTransition = { slideInVertically { it } }, exitTransition = { fadeOut() },
                    popExitTransition = { slideOutVertically { it } }) { BookPlayerScreen(onClose = { nav.popBackStack() }) }
                composable("jukebox") { DevicesScreen(jukebox = true) }
            }
            }
            // Solid behind the status bar on the tab pages, so content scrolling up doesn't run into the clock (like the iPhone)
            if (entry?.destination?.route in tabs.map { it.route }) Box(
                Modifier.align(Alignment.TopCenter).fillMaxWidth()
                    .windowInsetsTopHeight(androidx.compose.foundation.layout.WindowInsets.statusBars).background(Palette.canvas),
            )
            // The floating bottom: notes, "continue from …", the mini player and the tabs, over a fade into the page
            if (!fullScreen && !ime) Column(
                Modifier.align(Alignment.BottomCenter).fillMaxWidth()
                    .onSizeChanged { barHeight = it.height }
                    .background(Brush.verticalGradient(0f to Palette.canvas.copy(alpha = 0f), 0.12f to Palette.canvas.copy(alpha = 0.85f), 0.3f to Palette.canvas)),
            ) {
                Notices(snackbar)
                DownloadNote { nav.open("downloads") }
                // An audiobook or podcast that plays takes the music player's place (and no "continue from" offer starts music under it)
                if (bookActive) BookMiniBar { nav.open("bookplayer") }
                else {
                    ContinueBanner()
                    MiniPlayer { nav.open("player") }
                }
                TabBar(tabs.getOrNull(currentTab)?.route) { i ->
                    val route = tabs[i].route
                    when {
                        // The open tab again: back to its start page, and from there to all of it
                        i == currentTab && entry?.destination?.route == route -> reselect[i] = reselect[i] + 1
                        // Also from a page opened in the side menu (settings, downloads …) back to the tab's start page
                        i == currentTab && nav.popBackStack(route, inclusive = false) -> Unit
                        // The first tab sits at the bottom of the stack: going there clears everything above it
                        route == tabs[startTab].route && nav.popBackStack(route, inclusive = false) -> Unit
                        else -> nav.navigate(route) {
                            popUpTo(nav.graph.findStartDestination().id)
                            launchSingleTop = true
                        }
                    }
                }
            }
            else if (fullScreen) Box(Modifier.align(Alignment.BottomCenter)) { Notices(snackbar) }
        }
        }
    }
}

/** The song that's playing, above the tabs, in the cover's color. Tap opens the full player. */
@Composable
fun MiniPlayer(open: () -> Unit) {
    val context = LocalContext.current
    val player = LocalPlayer.current
    val snackbar = LocalSnackbar.current
    val scope = rememberCoroutineScope()
    val state by player.state.collectAsState()
    if (!state.hasMedia) return
    val song = state.current
    val station = state.station
    val tint = rememberCoverColor(song?.coverArt)
    var progress by remember { mutableFloatStateOf(0f) }
    LaunchedEffect(song?.id, state.isPlaying, state.durationMs) {
        while (true) {
            progress = if (state.durationMs > 0) (player.position().toFloat() / state.durationMs).coerceIn(0f, 1f) else 0f
            if (!state.isPlaying) break
            delay(500)
        }
    }
    Box(
        Modifier.padding(horizontal = 10.dp, vertical = 4.dp).clip(RoundedCornerShape(16.dp))
            .background(tint?.darken(0.75f) ?: Palette.elevated).clickable(onClick = open),
    ) {
        Column {
            Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                if (station != null) Box(Modifier.width(42.dp).height(42.dp).clip(RoundedCornerShape(8.dp)).background(Palette.hue(station.name)), contentAlignment = Alignment.Center) {
                    Icon(Icons.Default.Radio, null)
                } else Cover(song?.coverArt, 42.dp, corner = 8.dp, pixels = 120)
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text(song?.title ?: station?.name ?: "", maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.SemiBold,
                        style = MaterialTheme.typography.bodyMedium)
                    Text(state.tvName?.let { stringResource(if (state.tvGuest) R.string.guest_of else R.string.playing_on, it) }
                        ?: song?.artist ?: state.liveTitle ?: stringResource(R.string.live), maxLines = 1, overflow = TextOverflow.Ellipsis,
                        style = MaterialTheme.typography.bodySmall, color = Color.White.copy(alpha = 0.7f))
                }
                if (song != null) {
                    val starred = rememberStarred(song.id, song.starred)
                    IconButton(onClick = { toggleFavorite(context, song, player, scope, snackbar) }) {
                        Icon(if (starred) Icons.Default.Favorite else Icons.Default.FavoriteBorder, stringResource(R.string.cd_favorite),
                            tint = if (starred) Palette.accent else Color.White)
                    }
                }
                IconButton(onClick = { player.toggle() }) {
                    Icon(
                        if (state.isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                        stringResource(if (state.isPlaying) R.string.cd_pause else R.string.cd_play),
                    )
                }
            }
            if (station == null) LinearProgressIndicator(
                progress = { progress },
                modifier = Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, bottom = 2.dp).height(2.dp).clip(RoundedCornerShape(1.dp)),
                color = Color.White, trackColor = Color.White.copy(alpha = 0.2f),
                gapSize = 0.dp, drawStopIndicator = {},
            )
        }
    }
}

/**
 * A small note above the player while downloads run, songs and audiobooks together ("Downloading 2 of 5"):
 * a ring and the count. Tapping it opens the downloads. Nothing when nothing downloads.
 */
@Composable
private fun DownloadNote(open: () -> Unit) {
    val activity by BookDownloads.activity.collectAsState()
    val all by Downloads.all.collectAsState()
    val account by LocalContext.current.tonalo.current.collectAsState()
    val books = activity ?: return
    // Songs still loading count as not done yet
    val songs = Downloads.forAccount(all, account?.id).count { !it.done && !it.failed }
    val total = books.total + songs
    if (total <= 0) return
    val value = (books.progress * books.total / total).coerceIn(0f, 1f)
    Box(Modifier.fillMaxWidth().padding(bottom = 4.dp), contentAlignment = Alignment.Center) {
        Row(
            Modifier.clip(androidx.compose.foundation.shape.CircleShape).background(Palette.elevated).clickable(onClick = open)
                .padding(horizontal = 14.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            androidx.compose.material3.CircularProgressIndicator(
                progress = { value }, modifier = Modifier.size(16.dp), color = Color.White, trackColor = Color.White.copy(alpha = 0.2f), strokeWidth = 2.5.dp,
            )
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.bka_downloading_of, books.done, total), fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}
