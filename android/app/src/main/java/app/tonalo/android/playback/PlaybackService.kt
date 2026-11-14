package app.tonalo.android.playback

import android.app.PendingIntent
import android.content.Intent
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSourceBitmapLoader
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.extractor.DefaultExtractorsFactory
import androidx.media3.session.CacheBitmapLoader
import androidx.media3.session.DefaultMediaNotificationProvider
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaLibraryService
import androidx.media3.session.MediaLibraryService.LibraryParams
import androidx.media3.session.MediaLibraryService.MediaLibrarySession
import androidx.media3.session.CommandButton
import androidx.media3.session.MediaSession
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionError
import androidx.media3.session.SessionResult
import android.os.Bundle
import app.tonalo.android.MainActivity
import app.tonalo.android.R
import app.tonalo.android.data.Network
import app.tonalo.android.data.PendingScrobble
import app.tonalo.android.data.SavedQueue
import app.tonalo.android.data.Song
import app.tonalo.android.data.Station
import app.tonalo.android.data.await
import app.tonalo.android.dj.DJ
import app.tonalo.android.downloads.Downloads
import app.tonalo.android.link.JukeboxHost
import app.tonalo.android.link.TvLink
import app.tonalo.android.tonalo
import app.tonalo.android.ui.Favorites
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.MoreExecutors
import com.google.common.util.concurrent.SettableFuture
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChangedBy
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.Request
import java.util.concurrent.Executors

private const val COMMAND_FAVORITE = "tonalo.favorite"
private const val COMMAND_SHUFFLE = "tonalo.shuffle"
private const val COMMAND_RADIO = "tonalo.radio"
private const val COMMAND_BOOK_BACK = "tonalo.bookBack"
private const val COMMAND_BOOK_FORWARD = "tonalo.bookForward"

/** The sleep timer: a time to stop at, or the end of the current song. */
data class SleepTimer(val endsAt: Long? = null, val endOfSong: Boolean = false) {
    val active get() = endsAt != null || endOfSong
}

/**
 * The running playback service, for what a MediaController can't do (sleep timer, radio, stations).
 * Screens and service live in the same process; while a screen is visible, its controller keeps the service alive.
 */
object Playback {
    var service: PlaybackService? = null
        internal set

    internal val _sleep = MutableStateFlow(SleepTimer())
    val sleep: StateFlow<SleepTimer> = _sleep.asStateFlow()

    internal val _radio = MutableStateFlow(false)
    /** An endless radio is playing and tops itself up. */
    val radio: StateFlow<Boolean> = _radio.asStateFlow()
}

/**
 * Plays in the background with a notification, lock screen controls, headphone buttons, Bluetooth and Android Auto.
 * Owns the player; the screens talk to it through a MediaController ([PlayerConnection]).
 * Also scrobbles, keeps the queue on the device and – for continuing on another device – on the server.
 */
@OptIn(UnstableApi::class)
class PlaybackService : MediaLibraryService() {

    private var session: MediaLibrarySession? = null
    private lateinit var player: ExoPlayer
    private val scope = MainScope()
    private var ticker: Job? = null
    private var sleepJob: Job? = null

    /** How long the current song has really been listened to – seeking ahead doesn't count. */
    private var listenedMs = 0L
    private var scrobbled = false
    private var lastServerSync = 0L
    private var lastSong: Song? = null
    private var fadeInStart = 0L
    private var sleepFade = 1f
    @Volatile private var switching = false
    private var errorSkips = 0
    private var refilling = false

    /**
     * An audiobook or podcast episode owns the player ([BookPlayer]). The music queue was saved before; nothing of the book
     * is saved as a queue, scrobbled or sent to the server while this is set.
     */
    @Volatile private var bookMode = false
    private var stashShuffle = false
    private var stashRepeat = Player.REPEAT_MODE_OFF
    private lateinit var bookSources: DefaultMediaSourceFactory

    internal val app get() = tonalo
    private val radio by lazy { SmartRadio({ app.client() }, { songs() }) }

    override fun onCreate() {
        super.onCreate()

        // Downloaded songs come from the download cache, everything else from the server (with the custom headers)
        val dataSource = CacheDataSource.Factory()
            .setCache(Downloads.cache(this))
            .setUpstreamDataSourceFactory(OkHttpDataSource.Factory(app.mediaHttp))
            .setCacheWriteDataSinkFactory(null)
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
        // Converted streams (Opus, AAC, MP3) have no seek index; with the estimated length they can be seeked anyway
        val extractors = DefaultExtractorsFactory().setConstantBitrateSeekingEnabled(true)

        // Books: files on the phone and the books server (login and custom headers are added by mediaHttp), no cache
        bookSources = DefaultMediaSourceFactory(
            DefaultDataSource.Factory(this, OkHttpDataSource.Factory(app.mediaHttp)),
            DefaultExtractorsFactory().setConstantBitrateSeekingEnabled(true),
        )

        player = ExoPlayer.Builder(this)
            .setMediaSourceFactory(DefaultMediaSourceFactory(dataSource, extractors))
            .setAudioAttributes(
                AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(),
                /* handleAudioFocus = */ true,
            )
            .setHandleAudioBecomingNoisy(true)
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .build()
        player.addListener(listener)
        // An own audio session from the start, so the equalizer can attach before the first song plays
        runCatching { player.audioSessionId = androidx.media3.common.util.Util.generateAudioSessionIdV21(this) }

        val openApp = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        // Covers come from our own content provider (playback/Covers.kt)
        val covers = DataSourceBitmapLoader(
            MoreExecutors.listeningDecorator(Executors.newSingleThreadExecutor()),
            DefaultDataSource.Factory(this, OkHttpDataSource.Factory(app.mediaHttp)),
        )
        session = MediaLibrarySession.Builder(this, player, callback)
            .setBitmapLoader(CacheBitmapLoader(covers))
            .setSessionActivity(openApp)
            .build()
        setMediaNotificationProvider(DefaultMediaNotificationProvider.Builder(this).build().apply {
            setSmallIcon(R.drawable.ic_notification)
        })
        Playback.service = this
        BookPlayer.init(app)
        BookPlayer.attach(bookHost)

        // Another account: its queue is not this one's
        scope.launch {
            app.current.distinctUntilChangedBy { it?.id }.drop(1).collect {
                // Stopping must not save the old songs as the new account's queue (or send them to its server)
                switching = true
                saveJob?.cancel()
                saveJob = null
                try {
                    player.stop()
                    player.clearMediaItems()
                } finally { switching = false }
                Playback._radio.value = false
            }
        }
        scope.launch { app.settings.leveling.collect { applyVolume() } }
        // The equalizer follows its settings at once – also while the page with the sliders is open
        scope.launch {
            kotlinx.coroutines.flow.combine(app.settings.eqEnabled, app.settings.eqPreset, app.settings.eqCustomGains) { on, preset, custom ->
                Triple(on, preset, custom)
            }.collect { applyEq() }
        }
        app.scope.launch { app.client()?.let { app.scrobbles.flush(it) } }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaLibrarySession? = session

    override fun onTaskRemoved(rootIntent: Intent?) {
        saveQueue()
        // Swiped away while paused: nothing left to do. While playing, the music keeps going.
        if (!player.playWhenReady || player.mediaItemCount == 0) stopSelf()
    }

    override fun onDestroy() {
        // The book's last position goes to the server before the player is gone
        BookPlayer.detach()
        saveJob?.cancel()
        saveQueue()
        syncToServer(force = true)
        Playback.service = null
        Playback._radio.value = false
        cancelSleepTimer()
        scope.cancel()
        equalizer?.release()
        equalizer = null
        session?.release()
        player.release()
        session = null
        super.onDestroy()
    }

    // region Items

    /** Gives each item from the screens its stream address, in the quality that fits the network right now. */
    private fun resolve(item: MediaItem): MediaItem {
        item.station?.let { st -> return st.toMediaItem(item.stationUrl ?: st.streamUrl) }
        val song = item.song ?: return item
        val account = app.current.value
        val key = account?.let { Downloads.key(it.id, song.id) }?.takeIf { Downloads.isDownloaded(this, song.id) }
        return song.toMediaItem(app.client(), app.streamQuality(), cacheKey = key,
            context = item.mediaMetadata.extras?.getString(CONTEXT_KEY), contextId = item.mediaMetadata.extras?.getString(CONTEXT_ID_KEY))
    }

    private fun <T> future(block: suspend () -> T): ListenableFuture<T> {
        val f = SettableFuture.create<T>()
        scope.launch {
            try { f.set(block()) } catch (e: kotlinx.coroutines.CancellationException) { f.cancel(false) } catch (e: Throwable) { f.setException(e) }
        }
        return f
    }

    private val car by lazy { CarLibrary(app) }

    private val favoriteCommand = SessionCommand(COMMAND_FAVORITE, Bundle.EMPTY)
    private val shuffleCommand = SessionCommand(COMMAND_SHUFFLE, Bundle.EMPTY)
    private val radioCommand = SessionCommand(COMMAND_RADIO, Bundle.EMPTY)
    private val bookBackCommand = SessionCommand(COMMAND_BOOK_BACK, Bundle.EMPTY)
    private val bookForwardCommand = SessionCommand(COMMAND_BOOK_FORWARD, Bundle.EMPTY)

    private fun skipIcon(seconds: Int, back: Boolean) = when (seconds) {
        10 -> if (back) CommandButton.ICON_SKIP_BACK_10 else CommandButton.ICON_SKIP_FORWARD_10
        15 -> if (back) CommandButton.ICON_SKIP_BACK_15 else CommandButton.ICON_SKIP_FORWARD_15
        30 -> if (back) CommandButton.ICON_SKIP_BACK_30 else CommandButton.ICON_SKIP_FORWARD_30
        else -> if (back) CommandButton.ICON_SKIP_BACK else CommandButton.ICON_SKIP_FORWARD
    }

    /** Heart, shuffle and "radio from this song": in the car, the notification and on the lock screen. */
    private fun customLayout(): ImmutableList<CommandButton> {
        if (bookMode) {
            // A book: skip back and forward with the intervals the user chose
            val st = BookPlayer.state.value
            return ImmutableList.of(
                CommandButton.Builder(skipIcon(st.skipBack, back = true))
                    .setDisplayName(getString(R.string.bp_skip_back, st.skipBack)).setSessionCommand(bookBackCommand).build(),
                CommandButton.Builder(skipIcon(st.skipForward, back = false))
                    .setDisplayName(getString(R.string.bp_skip_forward, st.skipForward)).setSessionCommand(bookForwardCommand).build(),
            )
        }
        val song = player.currentMediaItem?.song
        val buttons = mutableListOf<CommandButton>()
        if (song != null) {
            val starred = Favorites.isStarred(song)
            buttons += CommandButton.Builder(if (starred) CommandButton.ICON_HEART_FILLED else CommandButton.ICON_HEART_UNFILLED)
                .setDisplayName(getString(if (starred) R.string.remove_favorite else R.string.add_favorite))
                .setSessionCommand(favoriteCommand).build()
        }
        buttons += CommandButton.Builder(if (player.shuffleModeEnabled) CommandButton.ICON_SHUFFLE_ON else CommandButton.ICON_SHUFFLE_OFF)
            .setDisplayName(getString(R.string.shuffle)).setSessionCommand(shuffleCommand).build()
        if (song != null) buttons += CommandButton.Builder(CommandButton.ICON_RADIO)
            .setDisplayName(getString(R.string.car_radio)).setSessionCommand(radioCommand).build()
        return ImmutableList.copyOf(buttons)
    }

    private fun updateLayout() { session?.setCustomLayout(customLayout()) }

    /** The songs of a car pick or voice request, ready for the player. */
    private suspend fun itemsFor(pick: CarLibrary.Pick?): MediaSession.MediaItemsWithStartPosition {
        pick ?: throw UnsupportedOperationException("Nothing found")
        pick.station?.let { st ->
            return MediaSession.MediaItemsWithStartPosition(listOf(st.toMediaItem(resolveStation(st.streamUrl))), 0, 0)
        }
        if (pick.songs.isEmpty()) throw UnsupportedOperationException("Nothing found")
        if (pick.radio) Playback._radio.value = true
        val items = pick.songs.map { resolve(it.toMediaItem(context = pick.context)) }
        return MediaSession.MediaItemsWithStartPosition(items, pick.start.coerceIn(0, items.lastIndex), 0)
    }

    private val carRadio: suspend (String, List<Song>, String?) -> List<Song> = { _, seeds, genre ->
        radio.start(seedId = seeds.firstOrNull()?.let { it.artistId ?: it.id }, seeds = seeds, genre = genre)
    }

    /** Is this item only an id (from the car or a voice request), without the song or station that the screens send? */
    private fun MediaItem.isRequest() = song == null && station == null

    /** Items from the screens get their address; items that are only an id become the songs they stand for. */
    private suspend fun expand(mediaItems: List<MediaItem>): List<MediaItem> = mediaItems.flatMap { item ->
        if (!item.isRequest()) listOf(resolve(item))
        else try { itemsFor(request(item)).mediaItems } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: Exception) { emptyList() }
    }

    private val callback = object : MediaLibrarySession.Callback {
        override fun onConnect(session: MediaSession, controller: MediaSession.ControllerInfo): MediaSession.ConnectionResult =
            MediaSession.ConnectionResult.AcceptedResultBuilder(session)
                .setAvailableSessionCommands(
                    MediaSession.ConnectionResult.DEFAULT_SESSION_AND_LIBRARY_COMMANDS.buildUpon()
                        .add(favoriteCommand).add(shuffleCommand).add(radioCommand)
                        .add(bookBackCommand).add(bookForwardCommand).build()
                )
                .setCustomLayout(customLayout())
                .build()

        override fun onCustomCommand(
            session: MediaSession, controller: MediaSession.ControllerInfo, customCommand: SessionCommand, args: Bundle,
        ): ListenableFuture<SessionResult> {
            when (customCommand.customAction) {
                COMMAND_FAVORITE -> toggleFavorite()
                COMMAND_SHUFFLE -> { player.shuffleModeEnabled = !player.shuffleModeEnabled; updateLayout() }
                COMMAND_RADIO -> player.currentMediaItem?.song?.let { song ->
                    scope.launch { startRadio(getString(R.string.more_like, song.artist ?: song.title), seedId = song.artistId ?: song.id, seeds = listOf(song)) }
                }
                COMMAND_BOOK_BACK -> BookPlayer.skip(-BookPlayer.state.value.skipBack)
                COMMAND_BOOK_FORWARD -> BookPlayer.skip(BookPlayer.state.value.skipForward)
                else -> return Futures.immediateFuture(SessionResult(SessionError.ERROR_NOT_SUPPORTED))
            }
            return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS))
        }

        override fun onAddMediaItems(
            mediaSession: MediaSession, controller: MediaSession.ControllerInfo, mediaItems: MutableList<MediaItem>,
        ): ListenableFuture<MutableList<MediaItem>> {
            if (mediaItems.any { it.isRequest() }) return future { expand(mediaItems).toMutableList() }
            return Futures.immediateFuture(mediaItems.map(::resolve).toMutableList())
        }

        /** Something new to play from a screen or the car: a radio that was playing stops topping itself up. */
        override fun onSetMediaItems(
            mediaSession: MediaSession, controller: MediaSession.ControllerInfo, mediaItems: MutableList<MediaItem>,
            startIndex: Int, startPositionMs: Long,
        ): ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
            Playback._radio.value = false
            DJ.ended()
            val single = mediaItems.singleOrNull()
            if (single != null && single.isRequest()) return future { itemsFor(request(single)) }
            if (mediaItems.any { it.isRequest() }) return future {
                // Several items, some only ids: each becomes its songs, the start moves along with them
                val parts = mediaItems.map { expand(listOf(it)) }
                val items = parts.flatten()
                val start = if (startIndex in 1..parts.size) parts.take(startIndex).sumOf { it.size } else startIndex
                if (items.isEmpty()) throw UnsupportedOperationException("Nothing found")
                MediaSession.MediaItemsWithStartPosition(items, if (startIndex == C.INDEX_UNSET) startIndex else start.coerceIn(0, items.lastIndex), startPositionMs)
            }
            return Futures.immediateFuture(
                MediaSession.MediaItemsWithStartPosition(mediaItems.map(::resolve), startIndex, startPositionMs)
            )
        }

        /** Play pressed on the headphones, in the car, or the "resume" card after the app was closed: the saved queue. */
        override fun onPlaybackResumption(
            mediaSession: MediaSession, controller: MediaSession.ControllerInfo,
        ): ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
            Playback._radio.value = false
            val account = app.current.value
            val saved = account?.let { app.queues.load(it.id) }?.takeIf { it.songs.isNotEmpty() }
                ?: return Futures.immediateFailedFuture(UnsupportedOperationException("Nothing to resume"))
            val items = saved.songs.map { resolve(it.toMediaItem()) }
            return Futures.immediateFuture(
                MediaSession.MediaItemsWithStartPosition(items, saved.index.coerceIn(0, items.lastIndex), saved.positionMs)
            )
        }

        // Android Auto

        override fun onGetLibraryRoot(
            session: MediaLibrarySession, browser: MediaSession.ControllerInfo, params: LibraryParams?,
        ): ListenableFuture<LibraryResult<MediaItem>> {
            // The car's "recent" row asks for a root that only holds what played last
            if (params?.isRecent == true) {
                val recent = LibraryParams.Builder().setRecent(true).setExtras(car.rootExtras()).build()
                return Futures.immediateFuture(LibraryResult.ofItem(car.folder("recent", getString(R.string.recently_played)), recent))
            }
            val out = LibraryParams.Builder().setExtras(car.rootExtras()).build()
            return Futures.immediateFuture(LibraryResult.ofItem(car.root(), out))
        }

        override fun onGetItem(
            session: MediaLibrarySession, browser: MediaSession.ControllerInfo, mediaId: String,
        ): ListenableFuture<LibraryResult<MediaItem>> {
            car.item(mediaId)?.let { return Futures.immediateFuture(LibraryResult.ofItem(it, null)) }
            return future {
                val item = try {
                    car.itemFor(mediaId) ?: queuedItem(mediaId)
                } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: Exception) {
                    return@future LibraryResult.ofError<MediaItem>(SessionError.ERROR_IO)
                }
                if (item == null) LibraryResult.ofError(SessionError.ERROR_BAD_VALUE) else LibraryResult.ofItem(item, null)
            }
        }

        override fun onGetChildren(
            session: MediaLibrarySession, browser: MediaSession.ControllerInfo, parentId: String,
            page: Int, pageSize: Int, params: LibraryParams?,
        ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> = future {
            val all = try {
                if (parentId == "recent") recentForCar() else car.children(parentId)
            } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: Exception) {
                return@future LibraryResult.ofError<ImmutableList<MediaItem>>(SessionError.ERROR_IO)
            }
            LibraryResult.ofItemList(ImmutableList.copyOf(page(all, page, pageSize)), params)
        }

        override fun onSearch(
            session: MediaLibrarySession, browser: MediaSession.ControllerInfo, query: String, params: LibraryParams?,
        ): ListenableFuture<LibraryResult<Void>> = future {
            val found = try { car.search(query) } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: Exception) {
                return@future LibraryResult.ofError<Void>(SessionError.ERROR_IO)
            }
            session.notifySearchResultChanged(browser, query, found.size, params)
            LibraryResult.ofVoid()
        }

        override fun onGetSearchResult(
            session: MediaLibrarySession, browser: MediaSession.ControllerInfo, query: String,
            page: Int, pageSize: Int, params: LibraryParams?,
        ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> = future {
            val all = try { car.searchResult(query) ?: car.search(query) } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: Exception) {
                return@future LibraryResult.ofError<ImmutableList<MediaItem>>(SessionError.ERROR_IO)
            }
            LibraryResult.ofItemList(ImmutableList.copyOf(page(all, page, pageSize)), params)
        }
    }

    private fun <T> page(all: List<T>, page: Int, pageSize: Int): List<T> {
        if (pageSize <= 0 || pageSize == Int.MAX_VALUE) return all
        val from = page.toLong() * pageSize
        if (from >= all.size) return emptyList()
        return all.subList(from.toInt(), minOf(all.size, (from + pageSize).toInt()))
    }

    /** An id from the car, or a voice request ("Hey Google, play … on Tonalo"). */
    private suspend fun request(item: MediaItem): CarLibrary.Pick? {
        val query = item.requestMetadata.searchQuery
        return if (item.mediaId.isEmpty() || query != null) car.voice(query ?: "", carRadio)
        else car.pick(item.mediaId, carRadio)
    }

    /** A song the car asks about by its bare id: from the queue or the saved queue. */
    private fun queuedItem(id: String): MediaItem? {
        val song = songs().firstOrNull { it.id == id }
            ?: app.current.value?.let { app.queues.load(it.id) }?.songs?.firstOrNull { it.id == id }
            ?: return null
        return car.songItem(song)
    }

    /** What played last, for the car's "continue" card. */
    private fun recentForCar(): List<MediaItem> {
        val saved = app.current.value?.let { app.queues.load(it.id) } ?: return emptyList()
        val song = saved.songs.getOrNull(saved.index) ?: return emptyList()
        return listOf(resolve(song.toMediaItem()))
    }

    /** The heart from the car or the notification: on the server, in the queue and on the screens. */
    private fun toggleFavorite() {
        val index = player.currentMediaItemIndex
        val item = player.currentMediaItem ?: return
        val song = item.song ?: return
        val on = !Favorites.isStarred(song)
        Favorites.set(song.id, on)
        val updated = song.copy(starred = if (on) java.time.Instant.now().toString() else null)
        player.replaceMediaItem(index, item.buildUpon().setMediaMetadata(
            updated.toMediaItem(app.client(), context = item.mediaMetadata.extras?.getString(CONTEXT_KEY)).mediaMetadata
        ).build())
        if (on) liked(updated)
        updateLayout()
        app.scope.launch {
            try { app.client()?.setStar(songId = song.id, on = on) }
            catch (e: kotlinx.coroutines.CancellationException) { throw e }
            catch (e: Exception) { Favorites.set(song.id, !on); updateLayout() }
        }
    }

    // endregion

    // region Radio and stations (called by the screens through Playback.service)

    /** Starts an endless radio from a song/artist, songs or a genre. Returns false when nothing was found. */
    suspend fun startRadio(name: String, seedId: String? = null, seeds: List<Song> = emptyList(), genre: String? = null, first: Song? = null): Boolean {
        val songs = radio.start(seedId, seeds, genre, first)
        if (songs.isEmpty()) return false
        // The own TV plays: the radio goes there (without topping itself up)
        if (TvLink.remote.value != null) { TvLink.play(songs, 0, shuffled = false, context = name); return true }
        player.setMediaItems(songs.map { resolve(it.toMediaItem(context = name)) }, 0, 0)
        player.prepare()
        player.play()
        Playback._radio.value = true
        return true
    }

    /** The first songs of a radio without playing them here – for a radio started while the TV plays. */
    suspend fun radioSongs(seedId: String? = null, seeds: List<Song> = emptyList(), genre: String? = null, first: Song? = null): List<Song> =
        radio.start(seedId, seeds, genre, first)

    fun liked(song: Song) { if (Playback._radio.value) radio.liked(song) }

    // region DJ (dj/DJ.kt)

    fun playDJ(songs: List<Song>) {
        Playback._radio.value = false
        player.setMediaItems(songs.map { resolve(it.toMediaItem(context = "DJ")) }, 0, 0)
        player.prepare()
        player.play()
    }

    /** Keeps the song that plays and replaces everything after it. */
    fun replaceUpNext(songs: List<Song>, context: String) {
        val i = player.currentMediaItemIndex
        if (i + 1 < player.mediaItemCount) player.removeMediaItems(i + 1, player.mediaItemCount)
        player.addMediaItems(songs.map { resolve(it.toMediaItem(context = context)) })
        Playback._radio.value = false
    }

    fun queuedIds(): Set<String> = songs().map { it.id }.toSet()

    /** A DJ session asks for its next set before the queue runs out; if the provider can't be reached, the radio fills in. */
    private var djFilling = false
    private fun refillDJ() {
        if (!DJ.active.value || djFilling) return
        if (player.mediaItemCount - player.currentMediaItemIndex - 1 >= 4) return
        djFilling = true
        scope.launch {
            try {
                val songs = DJ.nextSet() ?: radio.continueAfter(songs())
                if (DJ.active.value && songs.isNotEmpty()) player.addMediaItems(songs.map { resolve(it.toMediaItem(context = "DJ")) })
            } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: Exception) {
            } finally { djFilling = false }
        }
    }

    // endregion

    // endregion

    // region TV and Jukebox (link/TvLink, link/JukeboxHost)

    fun isPlayingLocally() = player.isPlaying

    /** The own TV started playing: this phone goes quiet and shows the TV. */
    fun pauseForTv() {
        saveQueue()
        player.pause()
        Playback._radio.value = false
        cancelSleepTimer()
    }

    /** The TV's music goes on here (it went away, or "play here"). */
    fun takeOver(songs: List<Song>, index: Int, positionMs: Long, play: Boolean) {
        if (songs.isEmpty()) return
        Playback._radio.value = false
        player.setMediaItems(songs.map { resolve(it.toMediaItem()) }, index.coerceIn(0, songs.lastIndex), positionMs)
        player.prepare()
        if (play) player.play()
    }

    fun addFromGuest(songs: List<Song>, next: Boolean) {
        val items = songs.map { resolve(it.toMediaItem()) }
        when {
            player.mediaItemCount == 0 -> { player.setMediaItems(items); player.prepare(); player.play() }
            next -> player.addMediaItems(player.currentMediaItemIndex + 1, items)
            else -> player.addMediaItems(items)
        }
    }

    fun skipFromGuest() = player.seekToNext()

    /** What the Jukebox's guests see: the fields of Link.snapshot() on the TV, without the account name. */
    fun jukeboxSnapshot(guests: List<String>): kotlinx.serialization.json.JsonObject {
        val station = player.currentMediaItem?.station
        val all = songs()
        if (all.isEmpty() && station == null) return kotlinx.serialization.json.buildJsonObject {
            put("active", kotlinx.serialization.json.JsonPrimitive(false))
            put("guests", kotlinx.serialization.json.JsonArray(guests.map { kotlinx.serialization.json.JsonPrimitive(it) }))
        }
        val index = player.currentMediaItemIndex.coerceIn(0, maxOf(0, all.lastIndex))
        val from = maxOf(0, index - 20)
        val window = if (all.isEmpty()) emptyList() else all.subList(from, minOf(all.size, index + 101))
        val now = System.currentTimeMillis().toDouble()
        return kotlinx.serialization.json.buildJsonObject {
            put("active", kotlinx.serialization.json.JsonPrimitive(true))
            put("server", kotlinx.serialization.json.JsonPrimitive(app.current.value?.serverURL ?: ""))
            put("playing", kotlinx.serialization.json.JsonPrimitive(player.isPlaying))
            put("position", kotlinx.serialization.json.JsonPrimitive(player.currentPosition / 1000.0))
            put("duration", kotlinx.serialization.json.JsonPrimitive(player.duration.takeIf { it > 0 }?.div(1000.0) ?: 0.0))
            put("at", kotlinx.serialization.json.JsonPrimitive(now))
            put("sent", kotlinx.serialization.json.JsonPrimitive(now))
            put("queue", kotlinx.serialization.json.JsonArray(window.map { Network.json.encodeToJsonElement(Song.serializer(), it.copy(starred = null)) }))
            put("index", kotlinx.serialization.json.JsonPrimitive(index - from))
            put("offset", kotlinx.serialization.json.JsonPrimitive(from))
            put("shuffle", kotlinx.serialization.json.JsonPrimitive(player.shuffleModeEnabled))
            put("repeat", kotlinx.serialization.json.JsonPrimitive(when (player.repeatMode) { Player.REPEAT_MODE_ALL -> "all"; Player.REPEAT_MODE_ONE -> "one"; else -> "off" }))
            put("guests", kotlinx.serialization.json.JsonArray(guests.map { kotlinx.serialization.json.JsonPrimitive(it) }))
            station?.let { put("station", Network.json.encodeToJsonElement(Station.serializer(), it)) }
            player.currentMediaItem?.mediaMetadata?.extras?.getString(CONTEXT_KEY)?.let { name ->
                put("context", kotlinx.serialization.json.buildJsonObject { put("kind", kotlinx.serialization.json.JsonPrimitive("mix")); put("name", kotlinx.serialization.json.JsonPrimitive(name)) })
            }
        }
    }

    suspend fun playStation(station: Station) {
        TvLink.remote.value?.let { r -> if (!r.guest) { TvLink.playStation(station, listOf(station)); return } }
        val url = resolveStation(station.streamUrl)
        Playback._radio.value = false
        player.setMediaItem(station.toMediaItem(url))
        player.prepare()
        player.play()
    }

    /** Many stations give a playlist (.m3u/.pls) instead of the stream itself: the first address in it. */
    private suspend fun resolveStation(url: String): String {
        val lower = url.substringBefore('?').lowercase()
        if (!lower.endsWith(".m3u") && !lower.endsWith(".pls")) return url
        return runCatching {
            val text = Network.http.newCall(Request.Builder().url(url).build()).await().use { r -> withContext(Dispatchers.IO) { r.body?.string() ?: "" } }
            text.lines().map { it.trim().substringAfter('=', it.trim()) }.firstOrNull { it.startsWith("http") } ?: url
        }.getOrDefault(url)
    }

    // endregion

    // region Audiobooks (BookPlayer)

    private val bookHost = object : BookHost {
        override val player: ExoPlayer get() = this@PlaybackService.player
        override val sourceFactory: MediaSource.Factory get() = bookSources
        override fun start() = startBook()
        override fun finish(restoreMusic: Boolean) = finishBook(restoreMusic)
        override fun refreshLayout() = updateLayout()
    }

    private fun audioAttributes(speech: Boolean) = AudioAttributes.Builder().setUsage(C.USAGE_MEDIA)
        .setContentType(if (speech) C.AUDIO_CONTENT_TYPE_SPEECH else C.AUDIO_CONTENT_TYPE_MUSIC).build()

    /** The music is put aside: its queue (with the position) is saved, it pauses, and the player is the book's. */
    private fun startBook() {
        if (bookMode) return
        if (songs().isNotEmpty() && !switching) saveQueue()
        stashShuffle = player.shuffleModeEnabled
        stashRepeat = player.repeatMode
        player.pause()
        Playback._radio.value = false
        DJ.ended()
        cancelSleepTimer()
        bookMode = true
        // A book is neither shuffled nor repeated, whatever the music was
        player.shuffleModeEnabled = false
        player.repeatMode = Player.REPEAT_MODE_OFF
        player.setAudioAttributes(audioAttributes(speech = true), true)
        lastSong = null
        updateLayout()
    }

    /** Back to music: speed, focus type and volume as before; with [restore] the saved queue is loaded back, paused. */
    private fun finishBook(restore: Boolean) {
        bookMode = false
        player.playbackParameters = PlaybackParameters.DEFAULT
        player.pauseAtEndOfMediaItems = false
        player.setAudioAttributes(audioAttributes(speech = false), true)
        if (restore) {
            player.pause()
            player.shuffleModeEnabled = stashShuffle
            player.repeatMode = stashRepeat
            val saved = app.current.value?.let { app.queues.load(it.id) }
            if (saved != null) {
                player.setMediaItems(saved.songs.map { resolve(it.toMediaItem()) }, saved.index.coerceIn(0, saved.songs.lastIndex), saved.positionMs)
                player.prepare()
            } else {
                player.clearMediaItems()
            }
        }
        applyVolume()
        updateLayout()
    }

    // endregion

    // region Sleep timer

    fun setSleepTimer(minutes: Int) {
        cancelSleepTimer()
        val endsAt = System.currentTimeMillis() + minutes * 60_000L
        Playback._sleep.value = SleepTimer(endsAt = endsAt)
        sleepJob = scope.launch {
            delay(minutes * 60_000L - 10_000L)
            // The last 10 seconds fade out, then it pauses
            for (i in 10 downTo 1) { sleepFade = i / 10f; applyVolume(); delay(1000) }
            player.pause()
            sleepFade = 1f
            applyVolume()
            Playback._sleep.value = SleepTimer()
        }
    }

    fun sleepAtEndOfSong() {
        cancelSleepTimer()
        player.pauseAtEndOfMediaItems = true
        Playback._sleep.value = SleepTimer(endOfSong = true)
    }

    fun cancelSleepTimer() {
        sleepJob?.cancel()
        sleepJob = null
        sleepFade = 1f
        if (::player.isInitialized) { player.pauseAtEndOfMediaItems = false; applyVolume() }
        Playback._sleep.value = SleepTimer()
    }

    // endregion

    // region Events

    private val listener = object : Player.Listener {
        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            // Music started (screens, car, radio…) while a book had the player: the book is closed
            if (bookMode) BookPlayer.onMediaItem()
            if (bookMode) {
                lastSong = null
                updateLayout()
                applyVolume()
                return
            }
            // What happened to the song before: played to the end, or skipped
            lastSong?.let { prev ->
                if (DJ.active.value) {
                    if (reason == Player.MEDIA_ITEM_TRANSITION_REASON_AUTO) DJ.listened(prev)
                    else if (reason == Player.MEDIA_ITEM_TRANSITION_REASON_SEEK && listenedMs < 30_000) DJ.skipped(prev)
                }
                if (Playback._radio.value) {
                    if (reason == Player.MEDIA_ITEM_TRANSITION_REASON_AUTO) radio.listened(prev)
                    else if (reason == Player.MEDIA_ITEM_TRANSITION_REASON_SEEK && listenedMs < 30_000) radio.skipped(prev)
                }
            }
            if (Playback.sleep.value.endOfSong && reason == Player.MEDIA_ITEM_TRANSITION_REASON_AUTO) cancelSleepTimer()
            // The same song loaded again part-way (e.g. the item replaced after a heart) is the same listen:
            // not counted twice, not announced as "now playing" again
            val sameListen = reason == Player.MEDIA_ITEM_TRANSITION_REASON_PLAYLIST_CHANGED &&
                mediaItem?.song?.id != null && mediaItem.song?.id == lastSong?.id && player.currentPosition > 1000
            if (!sameListen) {
                listenedMs = 0
                scrobbled = false
            }
            fadeInStart = if (reason == Player.MEDIA_ITEM_TRANSITION_REASON_AUTO) System.currentTimeMillis() else 0
            lastSong = mediaItem?.song
            updateLayout()
            applyVolume()
            refillRadio()
            refillDJ()
            val song = mediaItem?.song ?: return
            app.current.value?.id?.let { acc ->
                app.history.note(acc, song.albumId?.let { "a$it" }, song.artistId?.let { "r$it" }, mediaItem.mediaMetadata.extras?.getString(CONTEXT_ID_KEY))
            }
            if (app.settings.scrobble.value && !sameListen) app.scope.launch { app.client()?.scrobble(song.id, submission = false) }
            saveQueue()
            syncToServer()
        }

        override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
            if (bookMode) { BookPlayer.onPlayerError(error); return }
            // A song that can't be played (gone from the server, network lost): on to the next, a few times at most
            if (errorSkips < 3 && player.hasNextMediaItem()) {
                errorSkips++
                player.seekToNextMediaItem()
                player.prepare()
                player.play()
            }
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            if (isPlaying) errorSkips = 0
            if (isPlaying) startTicker() else {
                ticker?.cancel()
                saveQueue()
                syncToServer(force = true)
            }
        }

        override fun onPlaybackStateChanged(state: Int) {
            if (state == Player.STATE_ENDED && !bookMode) {
                // "Stop after this song" on the last song of the queue: no autoplay on top of it
                val stopHere = Playback.sleep.value.endOfSong
                if (stopHere) cancelSleepTimer() else autoplay()
            }
        }

        override fun onShuffleModeEnabledChanged(shuffleModeEnabled: Boolean) = updateLayout()

        override fun onAudioSessionIdChanged(audioSessionId: Int) {
            equalizer?.release()
            equalizer = null
            applyEq()
        }

        override fun onEvents(player: Player, events: Player.Events) {
            if (bookMode) BookPlayer.onEvents(player, events)
            // A heart set on the screens shows in the car and the notification too
            if (events.contains(Player.EVENT_MEDIA_METADATA_CHANGED)) updateLayout()
            // Guests of this phone's Jukebox see changes right away
            if (JukeboxHost.running.value) app.scope.launch { JukeboxHost.push() }
        }

        override fun onTimelineChanged(timeline: androidx.media3.common.Timeline, reason: Int) {
            if (reason == Player.TIMELINE_CHANGE_REASON_PLAYLIST_CHANGED) saveQueueSoon()
        }
    }

    /** A radio tops itself up before it runs out. */
    private fun refillRadio() {
        if (!Playback._radio.value || refilling) return
        if (player.mediaItemCount - player.currentMediaItemIndex - 1 >= 5) return
        refilling = true
        scope.launch {
            try {
                val more = radio.more()
                if (Playback._radio.value) player.addMediaItems(more.map { resolve(it.toMediaItem(context = player.currentMediaItem?.mediaMetadata?.extras?.getString(CONTEXT_KEY))) })
            } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: Exception) {
            } finally { refilling = false }
        }
    }

    /** An album or playlist ended: keep going with similar songs (if switched on). */
    private fun autoplay() {
        if (!app.settings.autoplay.value || Playback._radio.value || DJ.active.value || player.currentMediaItem?.station != null) return
        val queue = songs()
        if (queue.isEmpty()) return
        scope.launch {
            val more = radio.continueAfter(queue)
            // Something else was started while the songs were fetched: leave it alone
            if (more.isEmpty() || player.playbackState != Player.STATE_ENDED || player.mediaItemCount != queue.size) return@launch
            val start = player.mediaItemCount
            player.addMediaItems(more.map { resolve(it.toMediaItem()) })
            player.seekTo(start, 0)
            player.play()
        }
    }

    private fun startTicker() {
        ticker?.cancel()
        ticker = scope.launch {
            var n = 0
            while (isActive) {
                delay(250)
                if (!player.isPlaying) continue
                if (++n % 4 == 0) {
                    listenedMs += 1000
                    checkScrobble()
                }
                applyVolume()
                if (n % 60 == 0) saveQueue()
            }
        }
    }

    /** Counts as played after half the song or four minutes, whichever comes first (the Last.fm rule). */
    private fun checkScrobble() {
        if (scrobbled || !app.settings.scrobble.value) return
        val song = player.currentMediaItem?.song ?: return
        val duration = player.duration.takeIf { it > 0 } ?: (song.duration ?: 0) * 1000L
        if (duration < 30_000 || listenedMs < minOf(duration / 2, 240_000L)) return
        scrobbled = true
        val at = System.currentTimeMillis()
        val account = app.current.value?.id ?: return
        app.scope.launch {
            val client = app.client() ?: return@launch
            // No connection: sent later, with the time it was really played
            if (client.scrobble(song.id, submission = true, timeMillis = at)) app.scrobbles.flush(client)
            else app.scrobbles.add(account, PendingScrobble(song.id, at))
        }
    }

    /**
     * Volume = leveling × fade in after a song change × fade out before the next one × sleep timer fade.
     * ExoPlayer has one output, so "crossfade" is a quick fade out and in rather than two songs overlapping.
     */
    private fun applyVolume() {
        if (bookMode) { player.volume = BookPlayer.volumeFactor; return }
        var v = app.settings.leveling.value.factor(player.currentMediaItem?.song)
        val fade = app.settings.crossfade.value * 1000L
        if (fade > 0 && player.currentMediaItem?.station == null) {
            if (fadeInStart > 0) {
                val t = System.currentTimeMillis() - fadeInStart
                if (t < fade) v *= (t.toFloat() / fade).coerceIn(0.05f, 1f) else fadeInStart = 0
            }
            val remaining = player.duration - player.currentPosition
            if (player.duration > 0 && remaining in 0 until fade && player.hasNextMediaItem()) v *= (remaining.toFloat() / fade).coerceIn(0f, 1f)
        }
        player.volume = v * sleepFade
    }

    // endregion

    // region Equalizer

    private var equalizer: android.media.audiofx.Equalizer? = null

    /** Created when first switched on, for the player's audio session; some phones have no equalizer at all. */
    private fun applyEq() {
        val s = app.settings
        val on = s.eqEnabled.value
        if (!on && equalizer == null) return
        val session = player.audioSessionId
        if (session == C.AUDIO_SESSION_ID_UNSET) return
        runCatching {
            val eq = equalizer ?: android.media.audiofx.Equalizer(0, session).also { equalizer = it }
            Eq.apply(eq, on, Eq.gains(s.eqPreset.value, Eq.parse(s.eqCustomGains.value)))
        }.onFailure { runCatching { equalizer?.release() }; equalizer = null }
    }

    // endregion

    // region Saving the queue

    private fun songs() = (0 until player.mediaItemCount).mapNotNull { player.getMediaItemAt(it).song }

    private var saveJob: Job? = null

    /** The queue changes in bursts (adding, moving, removing): saved at most every 2 seconds. */
    private fun saveQueueSoon() {
        if (switching || bookMode || saveJob?.isActive == true) return
        val account = app.current.value?.id ?: return
        saveJob = scope.launch {
            delay(2_000)
            saveJob = null
            if (app.current.value?.id == account) saveQueue()
        }
    }

    private fun saveQueue() {
        if (switching || bookMode) return
        val account = app.current.value ?: return
        val songs = songs()
        if (songs.isEmpty()) { if (player.mediaItemCount == 0) app.queues.delete(account.id); return }
        app.queues.save(account.id, SavedQueue(songs, player.currentMediaItemIndex.coerceAtMost(songs.lastIndex), player.currentPosition))
    }

    /** The queue on the server, so the TV or the iPhone can pick up here. At most every few seconds. */
    private fun syncToServer(force: Boolean = false) {
        if (!app.settings.syncQueue.value || switching || bookMode) return
        val now = System.currentTimeMillis()
        if (!force && now - lastServerSync < 5_000) return
        val current = player.currentMediaItem?.song ?: return
        val ids = songs().map { it.id }
        val position = player.currentPosition
        val client = app.client() ?: return
        lastServerSync = now
        app.scope.launch { client.savePlayQueue(ids, current.id, position) }
    }

    // endregion
}
