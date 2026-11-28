package app.tonalo.android.data

import android.content.Context
import app.tonalo.android.TonaloApplication
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable

/**
 * Loads the whole library onto the phone once: every album, artist and playlist page goes into the library cache,
 * so everything opens at once and offline – not only what was browsed before. Only music metadata is stored, like
 * the rest of the cache (no login details). Running it again later picks up changes.
 */
object LibrarySync {
    @Serializable
    data class Summary(val date: Long, val albums: Int, val artists: Int, val playlists: Int, val genres: Int, val songs: Int)

    sealed interface Phase {
        data object Overview : Phase
        data class Albums(val count: Int) : Phase
        data object Details : Phase
    }

    private val _running = MutableStateFlow(false)
    val running: StateFlow<Boolean> = _running.asStateFlow()
    private val _done = MutableStateFlow(0)
    val done: StateFlow<Int> = _done.asStateFlow()
    private val _total = MutableStateFlow(0)
    val total: StateFlow<Int> = _total.asStateFlow()
    private val _phase = MutableStateFlow<Phase>(Phase.Overview)
    val phase: StateFlow<Phase> = _phase.asStateFlow()
    private val _error = MutableStateFlow<Throwable?>(null)
    val error: StateFlow<Throwable?> = _error.asStateFlow()
    private val _summary = MutableStateFlow<Summary?>(null)
    val summary: StateFlow<Summary?> = _summary.asStateFlow()

    private var job: Job? = null
    private var accountId: String? = null

    /** Requests at the same time: fast, without hammering a small home server. */
    private const val PARALLEL = 4
    /** The same page size and order as the library page asks for, so the saved answers are the ones it shows. */
    private const val PAGE = 60
    private const val STALE_MS = 30L * 24 * 3600 * 1000

    fun isStale(summary: Summary?): Boolean = summary != null && System.currentTimeMillis() - summary.date > STALE_MS

    private fun prefs(context: Context) = context.getSharedPreferences("librarysync", Context.MODE_PRIVATE)

    /** Shows the state of this account's library; a sync of another account stops. */
    fun show(context: Context, id: String?) {
        if (id == accountId) return
        cancel()
        accountId = id
        _error.value = null
        _summary.value = id?.let { prefs(context).getString(it, null) }
            ?.let { runCatching { Network.json.decodeFromString(Summary.serializer(), it) }.getOrNull() }
    }

    /** The cache was cleared or the account removed: nothing is synced any more. */
    fun forget(context: Context, id: String) {
        prefs(context).edit().remove(id).apply()
        if (id == accountId) { cancel(); _summary.value = null }
    }

    fun cancel() {
        job?.cancel()
        job = null
        _running.value = false
    }

    fun start(app: TonaloApplication) {
        if (_running.value) return
        val client = app.client() ?: return
        val id = client.account.id
        accountId = id
        _running.value = true
        _error.value = null
        _done.value = 0
        _total.value = 0
        _phase.value = Phase.Overview
        val mine = app.scope.launch {
            try {
                val result = run(client)
                prefs(app).edit().putString(id, Network.json.encodeToString(Summary.serializer(), result)).apply()
                if (accountId == id) _summary.value = result
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _error.value = e
            } finally {
                if (job === coroutineContext[Job]) { _running.value = false; job = null }
            }
        }
        job = mine
    }

    /**
     * A hiccup (Wi-Fi switching, a busy home server) must not end a sync that has been running for minutes: a failed
     * request is asked again a few times. Real answers from the server and a stop are passed on at once.
     */
    private suspend fun refresh(client: SubsonicClient, method: String, vararg params: Pair<String, String>): Payload {
        var wait = 1_000L
        repeat(3) {
            try { return client.refresh(method, *params) } catch (e: Exception) {
                if (e is CancellationException || e.isServerAnswer) throw e
            }
            delay(wait)
            wait *= 3
        }
        return client.refresh(method, *params)
    }

    private suspend fun run(client: SubsonicClient): Summary = coroutineScope {
        val artistsAnswer = async { refresh(client, "getArtists") }
        val genresAnswer = async { refresh(client, "getGenres") }
        val playlistsAnswer = async { refresh(client, "getPlaylists") }
        val starredAnswer = async { refresh(client, "getStarred2") }
        val artists = artistsAnswer.await().artists?.index.orEmpty().flatMap { it.artist.orEmpty() }
        val genres = genresAnswer.await().genres?.genre.orEmpty()
        val playlists = playlistsAnswer.await().playlists?.playlist.orEmpty()
        starredAnswer.await()

        // The album list in pages, exactly like the library page asks for it
        val albums = ArrayList<Album>()
        while (true) {
            currentCoroutineContext().ensureActive()
            _phase.value = Phase.Albums(albums.size)
            val page = refresh(client, "getAlbumList2", "type" to "alphabeticalByName", "size" to "$PAGE", "offset" to "${albums.size}")
                .albumList2?.album.orEmpty()
            albums += page
            if (page.size < PAGE) break
        }

        // Then every album, artist and playlist page on its own
        val jobs = albums.map { "getAlbum" to it.id } + artists.map { "getArtist" to it.id } + playlists.map { "getPlaylist" to it.id }
        _total.value = jobs.size
        _phase.value = Phase.Details
        var failed = 0
        var finished = 0
        for (batch in jobs.chunked(PARALLEL)) {
            currentCoroutineContext().ensureActive()
            val lost = batch.map { (method, id) ->
                async {
                    try { refresh(client, method, "id" to id); false } catch (e: CancellationException) { throw e } catch (e: Exception) {
                        // One album the server can't find (just deleted, say) doesn't stop the sync – many failures do:
                        // then the connection is gone
                        !e.isServerAnswer
                    }
                }
            }.awaitAll().count { it }
            failed += lost
            if (failed > 10) throw java.io.IOException("connection lost")
            finished += batch.size
            _done.value = finished
        }
        Summary(System.currentTimeMillis(), albums.size, artists.size, playlists.size, genres.size, albums.sumOf { it.songCount ?: 0 })
    }
}
