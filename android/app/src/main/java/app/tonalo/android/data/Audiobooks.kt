package app.tonalo.android.data

import android.content.Context
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.put
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.io.IOException
import java.net.URLEncoder
import java.text.Collator
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong

// Audiobooks and podcasts from an Audiobookshelf server, connected to a Tonalo account (port of ios/Tonalo/Audiobooks.swift).

/**
 * Where everything of the audiobooks stays on this phone: `filesDir/books/<accountId>/`, one folder per account.
 * Separate from the music data, so disconnecting the music server keeps it. Holds `state.json` (favorites, progress,
 * unsent positions) and whatever the download code puts next to it.
 */
object AudiobookFiles {
    @Volatile private var base: File? = null
    private val deleted = HashSet<String>()

    /** Called once at launch (TonaloApplication.onCreate), before anything else here is used. */
    fun init(context: Context) {
        base = File(context.filesDir, "books").apply { mkdirs() }
    }

    /** `filesDir/books`. */
    val root: File get() = base ?: throw IllegalStateException("AudiobookFiles.init(context) was not called")

    /** The folder of one account (not created until something is written). */
    fun folder(account: String): File = File(root, account)

    /** Allows writing for an account again after [deleteAccount] (it was disconnected and now connects anew). */
    fun reopen(account: String) { synchronized(deleted) { deleted.remove(account) } }

    /** Deletes everything kept for an account, and keeps a write that is still in flight from bringing the folder back. */
    fun deleteAccount(id: String) {
        synchronized(deleted) {
            deleted.add(id)
            runCatching { folder(id).deleteRecursively() }
        }
    }

    /** Moves the folder of one account to another one (a books-only account joining a music account). */
    internal fun move(from: String, to: String) {
        synchronized(deleted) {
            val source = folder(from)
            val target = folder(to)
            if (!source.exists()) return
            if (target.exists() || !runCatching { source.renameTo(target) }.getOrDefault(false)) source.deleteRecursively()
            deleted.add(from)
        }
    }

    internal fun write(account: String, name: String, data: ByteArray): Boolean = synchronized(deleted) {
        if (account in deleted) return false
        runCatching {
            val file = File(folder(account), name)
            file.parentFile?.mkdirs()
            val tmp = File(file.parentFile, "$name.tmp")
            tmp.writeBytes(data)
            tmp.renameTo(file) || run { file.writeBytes(data); tmp.delete(); true }
        }.getOrDefault(false)
    }

    internal fun read(account: String, name: String): ByteArray? =
        runCatching { File(folder(account), name).takeIf { it.exists() }?.readBytes() }.getOrNull()
}

/**
 * What [AudiobookLibrary] needs from the app (TonaloApplication implements it). Keeps the library free of Android
 * classes and testable with a stand-in.
 */
interface AudiobookHost {
    /** The account in use; its [Account.audiobooks] is the connection. */
    val current: StateFlow<Account?>

    /** There is a network. */
    val online: StateFlow<Boolean>

    /** Lives as long as the app: for requests that must finish when the screen that started them is gone. */
    val scope: CoroutineScope

    /** Stores the connection (new tokens, new address, or null to take it out) in the current account. False if saving failed. */
    fun setAudiobooks(server: AudiobookServer?): Boolean

    /** Adds or replaces an account and switches to it. False if saving failed. */
    fun save(account: Account): Boolean

    /** Deletes an account with everything of it, the audiobooks included. */
    fun remove(account: Account)

    /** Checks again whether the home address answers. */
    fun checkRoute()
}

/**
 * The Audiobookshelf connection of the current account and everything read from it: libraries, shelves, progress,
 * favorites, search, listening sessions. Create one, call [attach], and read the StateFlows from the screens.
 * All suspend functions can be called from any dispatcher; they throw [AudiobookError] or an `IOException` (no
 * connection). A reply of an unknown shape becomes [AudiobookError.Unexpected].
 */
class AudiobookLibrary {
    private lateinit var host: AudiobookHost

    /** Called on the main thread when playback must stop (account switched, disconnected, signed out). The book player sets this. */
    @Volatile var onPlayerClose: (() -> Unit)? = null

    /** Called on the main thread when the address in use changed (left home, other address saved): a running stream must continue from the new one. */
    @Volatile var onAddressChanged: (() -> Unit)? = null

    private val _connected = MutableStateFlow(false)
    /** The current account has an Audiobookshelf connection. */
    val connected: StateFlow<Boolean> = _connected.asStateFlow()

    private val _libraries = MutableStateFlow<List<ABSLibrary>>(emptyList())
    /** The server's libraries (audiobooks and podcasts). */
    val libraries: StateFlow<List<ABSLibrary>> = _libraries.asStateFlow()

    private val _shelves = MutableStateFlow<List<ABSShelf>>(emptyList())
    /** The overview shelves of all libraries, "continue listening" first when there is one. */
    val shelves: StateFlow<List<ABSShelf>> = _shelves.asStateFlow()

    private val _progress = MutableStateFlow<Map<String, ABSProgress>>(emptyMap())
    /** Progress by [ABSProgress.key]. Includes positions the server hasn't heard about yet. */
    val progress: StateFlow<Map<String, ABSProgress>> = _progress.asStateFlow()

    private val _loading = MutableStateFlow(false)
    /** [load] is running. */
    val loading: StateFlow<Boolean> = _loading.asStateFlow()

    private val _error = MutableStateFlow<Throwable?>(null)
    /** Why loading failed – only set while there is nothing to show (use `bookErrorText(context)` for the message). */
    val error: StateFlow<Throwable?> = _error.asStateFlow()

    private val _inProgress = MutableStateFlow<List<ABSItem>>(emptyList())
    /** What you started and haven't finished, however many. Kept for opening them without a connection. */
    val inProgress: StateFlow<List<ABSItem>> = _inProgress.asStateFlow()

    private val _favorites = MutableStateFlow<Map<String, FavoriteBook>>(emptyMap())
    /** Books with a heart by item id, kept on this phone per account. */
    val favorites: StateFlow<Map<String, FavoriteBook>> = _favorites.asStateFlow()

    private val _favoriteAuthors = MutableStateFlow<Map<String, FavoriteAuthor>>(emptyMap())
    /** Authors with a heart by author id. */
    val favoriteAuthors: StateFlow<Map<String, FavoriteAuthor>> = _favoriteAuthors.asStateFlow()

    private val _canDownload = MutableStateFlow(true)
    /** The server decides per user whether downloading is allowed. */
    val canDownload: StateFlow<Boolean> = _canDownload.asStateFlow()

    private val _atHome = MutableStateFlow(false)
    /** Whether the home address is in use right now. The app checks that whenever the network changes. */
    val atHome: StateFlow<Boolean> = _atHome.asStateFlow()

    private fun closePlayer() { host.scope.launch { onPlayerClose?.invoke() } }
    private fun addressChanged() { host.scope.launch { onAddressChanged?.invoke() } }

    @Volatile private var unsent: List<ABSProgress> = emptyList()
    @Volatile private var restoredFor: String? = null
    @Volatile private var loadedFor: String? = null
    private var refreshing: Deferred<Boolean>? = null
    private val sendMutex = Mutex()
    private val saveSeq = AtomicLong()
    private val writeLock = Any()
    private var written = 0L
    @Volatile private var lastNoteSave = 0L

    /** Connects the library to the app. Call once at launch, after the current account is known. */
    fun attach(host: AudiobookHost) {
        this.host = host
        _connected.value = host.current.value?.audiobooks != null
        host.scope.launch { host.current.collect { _connected.value = it?.audiobooks != null } }
        restore()
    }

    // region Connection and addresses

    /** The connection as it's saved (the address outside). To talk to the server, use [server]. */
    val stored: AudiobookServer? get() = host.current.value?.audiobooks

    /** The connection routed to what answers right now: the home address when [atHome], otherwise [stored]. */
    val server: AudiobookServer? get() = stored?.route(_atHome.value)

    private val currentId: String? get() = host.current.value?.id

    /** Item ids of the current "continue listening" shelf, as a list of items. */
    val continueListening: List<ABSItem> get() = _shelves.value.firstOrNull { it.id == ABSShelf.CONTINUE_LISTENING }?.items.orEmpty()

    /** A cover as an address Coil can load, or null when not connected. The request needs the server's headers: `app.mediaHttp` adds them. */
    fun coverURL(itemId: String, width: Int = 400): String? =
        server?.let { "${it.url}/api/items/$itemId/cover?width=$width&format=jpeg" }

    /** An author's picture, the same way. The server answers 404 when the author has none. */
    fun authorImageURL(id: String, width: Int = 200): String? =
        server?.let { "${it.url}/api/authors/$id/image?width=$width&format=jpeg" }

    /**
     * The address of one audio file of a session, for the player. Needs no login (the session id is the permission),
     * but a proxy's custom headers: stream it through `app.mediaHttp`, which adds them.
     */
    fun trackURL(session: ABSSession, track: ABSSession.Track): String? =
        server?.let { "${it.url}/public/session/${session.id}/track/${track.index}" }

    /** Whether the home address is in use. Set by the app after checking that the same server answers there. */
    fun setAtHome(value: Boolean) {
        if (value == _atHome.value) return
        _atHome.value = value
        // Leaving home: a stream from the home address breaks. Arriving needs nothing, the outside address keeps working.
        if (!value) addressChanged()
        if (loadedFor == null) host.scope.launch { runCatching { load() } }
    }

    // endregion

    // region Kept on this phone

    /** Brings back the last known state, so the library shows at once and without a connection. Safe to call often. */
    fun restore() {
        val id = currentId ?: return
        if (restoredFor == id || stored == null) return
        restoredFor = id
        val data = AudiobookFiles.read(id, "state.json") ?: return
        val saved = try {
            Network.json.decodeFromString(SavedBookState.serializer(), data.decodeToString())
        } catch (e: IllegalArgumentException) { return }
        _favorites.value = saved.favorites
        _favoriteAuthors.value = saved.authors
        _inProgress.value = saved.inProgress
        unsent = saved.unsent
        _progress.value = (saved.progress + saved.unsent).associateBy { it.key }
    }

    private fun saveState() {
        val id = currentId ?: return
        val state = SavedBookState(_favorites.value, _inProgress.value, _progress.value.values.toList(), unsent, _favoriteAuthors.value)
        val ticket = saveSeq.incrementAndGet()
        host.scope.launch(Dispatchers.IO) {
            val bytes = Network.json.encodeToString(SavedBookState.serializer(), state).toByteArray()
            // An older snapshot never overwrites a newer one
            synchronized(writeLock) {
                if (ticket > written && AudiobookFiles.write(id, "state.json", bytes)) written = ticket
            }
        }
    }

    /** Whether the book has a heart. */
    fun isFavorite(id: String): Boolean = id in _favorites.value

    /** Hearts or un-hearts a book (kept on this phone only; the server has no favorites). */
    fun toggleFavorite(item: ABSItem) {
        _favorites.update { if (item.id in it) it - item.id else it + (item.id to FavoriteBook(item, System.currentTimeMillis())) }
        saveState()
    }

    /** Whether the author has a heart. */
    fun isFavoriteAuthor(id: String): Boolean = id in _favoriteAuthors.value

    /** Hearts or un-hearts an author. */
    fun toggleFavoriteAuthor(id: String, name: String) {
        _favoriteAuthors.update {
            if (id in it) it - id else it + (id to FavoriteAuthor(ABSAuthor(id = id, name = name), System.currentTimeMillis()))
        }
        saveState()
    }

    /** The best copy of an item known without asking the server (favorite or in progress). */
    fun savedItem(id: String): ABSItem? = _favorites.value[id]?.item ?: _inProgress.value.firstOrNull { it.id == id }

    /** Whether the book or episode was listened to the end. */
    fun isFinished(id: String): Boolean = _progress.value[id]?.isFinished == true

    /** The progress of an item, of [episode] or (on a "new episodes" shelf) of the episode the shelf is about. */
    fun progressOf(item: ABSItem, episode: ABSEpisode? = null): ABSProgress? =
        _progress.value[ABSProgress.key(item.id, episode?.id ?: item.recentEpisode?.id)]

    /**
     * What is playing right now: the progress bars and the "Continue listening" shelf follow it at once, without
     * waiting for the server. The server hears about it through the playback session ([syncSession]). Call it
     * about every few seconds while playing.
     */
    fun noteListening(item: ABSItem, episode: ABSEpisode?, currentTime: Double, duration: Double) {
        val episodeId = episode?.id ?: item.recentEpisode?.id
        val key = ABSProgress.key(item.id, episodeId)
        val entry = (_progress.value[key] ?: ABSProgress(item.id, episodeId)).copy(
            currentTime = currentTime,
            duration = duration,
            progress = if (duration > 0) minOf(1.0, currentTime / duration) else 0.0,
            isFinished = duration > 0 && currentTime >= duration - 5,
            lastUpdate = System.currentTimeMillis().toDouble(),
        )
        _progress.update { it + (key to entry) }
        var changed = false
        // A podcast episode other than the one the shelf shows comes with the next refresh from the server
        if (entry.isFinished != true && (episode == null || episode.id == item.recentEpisode?.id)) {
            val shelves = _shelves.value
            val shelf = shelves.firstOrNull { it.id == ABSShelf.CONTINUE_LISTENING } ?: ABSShelf(ABSShelf.CONTINUE_LISTENING, "", emptyList())
            if (shelf.items.firstOrNull()?.shelfKey != item.shelfKey) {
                val updated = shelf.copy(items = listOf(item) + shelf.items.filterNot { it.shelfKey == item.shelfKey })
                _shelves.value = if (shelves.any { it.id == shelf.id }) shelves.map { if (it.id == shelf.id) updated else it } else listOf(updated) + shelves
                if (_inProgress.value.none { it.id == item.id }) _inProgress.update { listOf(item) + it }
                changed = true
            }
        }
        val now = System.currentTimeMillis()
        if (changed || now - lastNoteSave > 15_000) { lastNoteSave = now; saveState() }
    }

    /**
     * Tells the server where a downloaded book stands (playing offline without a session). Without a connection it's
     * kept and sent on the next occasion ([flushUnsent], called when the network is back and after every [load]).
     */
    fun saveProgress(item: String, episode: String?, currentTime: Double, duration: Double) {
        val entry = ABSProgress(
            libraryItemId = item, episodeId = episode, currentTime = currentTime,
            progress = if (duration > 0) minOf(1.0, currentTime / duration) else 0.0,
            isFinished = duration > 0 && currentTime >= duration - 5, lastUpdate = System.currentTimeMillis().toDouble(), duration = duration,
        )
        _progress.update { it + (entry.key to entry) }
        synchronized(this) { unsent = unsent.filterNot { it.key == entry.key } + entry }
        saveState()
        host.scope.launch { flushUnsent() }
    }

    /** Sends the positions the server hasn't heard about. Stops at the first failure (no connection); a gone item is dropped. */
    suspend fun flushUnsent() {
        if (stored == null || unsent.isEmpty() || !sendMutex.tryLock()) return
        try {
            val account = currentId
            for (entry in unsent.toList()) {
                if (currentId != account) return
                val path = "/api/me/progress/${entry.libraryItemId}" + (entry.episodeId?.let { "/$it" } ?: "")
                val body = buildJsonObject {
                    entry.currentTime?.let { put("currentTime", it) }
                    entry.progress?.let { put("progress", it) }
                    entry.isFinished?.let { put("isFinished", it) }
                    entry.duration?.let { put("duration", it) }
                }
                try {
                    send(path, "PATCH", body, 10)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: AudiobookError.Http) {
                    if (e.status != 404 && e.status != 410) return
                } catch (e: Exception) {
                    return
                }
                synchronized(this) { unsent = unsent.filterNot { it.key == entry.key && it.lastUpdate == entry.lastUpdate } }
            }
        } finally {
            sendMutex.unlock()
        }
        saveState()
    }

    // endregion

    // region Connect

    /** Signs in and gives back the connection, without saving anything yet. */
    suspend fun signIn(address: String, username: String, password: String, headers: List<HeaderField>): AudiobookServer {
        val url = SubsonicClient.normalize(address)
        try {
            return login(url, username, password, headers)
        } catch (first: IOException) {
            // No scheme typed and https didn't connect: plain http, but only for home-network addresses
            if ("://" in address || !SubsonicClient.isLocal(url)) throw first
            return login("http://" + url.removePrefix("https://"), username, password, headers)
        }
    }

    /** Adds Audiobookshelf to the account in use, signs in and loads. [home] is an optional address inside the home network. */
    suspend fun connect(address: String, username: String, password: String, headers: List<HeaderField>, home: String? = null) {
        val new = signIn(address, username, password, headers).copy(localURL = home?.let { SubsonicClient.normalizeLocal(it) })
        if (!host.setAudiobooks(new)) throw AudiobookError.SaveFailed()
        currentId?.let { AudiobookFiles.reopen(it) }
        clear()
        _connected.value = true
        host.checkRoute()
        load(force = true)
    }

    /**
     * Signs in and creates an account that has only audiobooks (blank music server, `username` = the Audiobookshelf
     * user), switching to it. The same login signed in again stays one account.
     */
    suspend fun connectAsAccount(address: String, username: String, password: String, headers: List<HeaderField>, home: String? = null) {
        val new = signIn(address, username, password, headers).copy(localURL = home?.let { SubsonicClient.normalizeLocal(it) })
        val account = Account(serverURL = "", username = new.username, salt = "", token = "", audiobooks = new)
        if (!host.save(account)) throw AudiobookError.SaveFailed()
        currentId?.let { AudiobookFiles.reopen(it) }
        accountChanged()
        host.checkRoute()
        load(force = true)
    }

    /**
     * Changes where the server is found, keeping the login, the downloads and the hearts. The login is checked at the
     * new address (and renewed if it ran out); [AudiobookError.Refused] means it isn't the same server.
     */
    suspend fun updateConnection(address: String, home: String?, headers: List<HeaderField>) {
        val old = stored ?: throw AudiobookError.NotConnected()
        var new = old.copy(
            url = SubsonicClient.normalize(address), headers = headers,
            localURL = home?.let { SubsonicClient.normalizeLocal(it) },
        )
        // A server that was only known by its home address keeps that as the address at home
        if (new.localURL == null && old.localURL == null && SubsonicClient.isLocal(old.url) && !SubsonicClient.isLocal(new.url)) {
            new = new.copy(localURL = old.url)
        }
        if (new.localURL == new.url) new = new.copy(localURL = null)
        new = try {
            checked(new)
        } catch (first: IOException) {
            if ("://" in address || !SubsonicClient.isLocal(new.url)) throw first
            checked(new.copy(url = "http://" + new.url.removePrefix("https://")))
        }
        if (!host.setAudiobooks(new)) throw AudiobookError.SaveFailed()
        _atHome.value = false
        loadedFor = null
        host.checkRoute()
        addressChanged()
        load(force = true)
    }

    /**
     * Takes Audiobookshelf out of the account: stops playback, deletes the downloads and hearts, ends the login on the
     * server. An account with no music server is deleted entirely (it would be empty).
     */
    fun disconnect() {
        val account = host.current.value ?: return
        closePlayer()
        if (!account.hasMusic) { host.remove(account); return }
        val old = stored
        if (!host.setAudiobooks(null)) return
        AudiobookFiles.deleteAccount(account.id)
        clear()
        _connected.value = false
        if (old != null) logout(old)
    }

    /** Ends the login on the server too, so the tokens stop working. Fire and forget. */
    fun logout(server: AudiobookServer) {
        val refresh = server.refreshToken ?: return
        val url = "${server.url}/logout".toHttpUrlOrNull() ?: return
        val request = Request.Builder().url(url).apply {
            server.httpHeaders.forEach { (k, v) -> header(k, v) }
            header("x-refresh-token", refresh)
            header("x-return-tokens", "true")
        }.post(ByteArray(0).toRequestBody()).build()
        host.scope.launch { runCatching { exchange(request, client(10, retry = false)) } }
    }

    /** The account in use changed (or its Audiobookshelf connection): stops playback and starts from what was saved for it. */
    fun accountChanged() {
        closePlayer()
        clear()
        _connected.value = stored != null
        restore()
    }

    private fun clear() {
        _libraries.value = emptyList(); _shelves.value = emptyList(); _progress.value = emptyMap(); _error.value = null
        loadedFor = null; _atHome.value = false
        _inProgress.value = emptyList(); _favorites.value = emptyMap(); _favoriteAuthors.value = emptyMap()
        unsent = emptyList(); restoredFor = null; _canDownload.value = true
    }

    // endregion

    // region Requests

    /**
     * A request to the server with the login. A 401 renews the token once (several requests failing at once share
     * one renewal) and asks again. Returns the body of a 2xx answer; otherwise throws [AudiobookError.Login] (401),
     * [AudiobookError.Http], or an `IOException` when there is no connection. Requests that change something are
     * not repeated by the network layer after a broken connection.
     */
    suspend fun send(path: String, method: String = "GET", body: JsonElement? = null, timeoutSeconds: Long = 20): ByteArray {
        val first = server ?: throw AudiobookError.NotConnected()
        val text = body?.toString()
        val http = client(timeoutSeconds, retry = method == "GET")
        var (status, data) = exchange(request(first, path, method, text), http)
        if (status == 401 && refreshToken()) {
            val again = server
            if (again != null) exchange(request(again, path, method, text), http).let { status = it.first; data = it.second }
        }
        if (status !in 200..299) throw if (status == 401) AudiobookError.Login() else AudiobookError.Http(status)
        return data
    }

    private suspend fun getJson(path: String): JsonElement {
        val data = send(path)
        return withContext(Dispatchers.Default) {
            try { Network.json.parseToJsonElement(data.decodeToString()) } catch (e: IllegalArgumentException) { throw AudiobookError.Unexpected() }
        }
    }

    private suspend fun <T> get(serializer: KSerializer<T>, path: String): T {
        val data = send(path)
        return withContext(Dispatchers.Default) {
            try { Network.json.decodeFromString(serializer, data.decodeToString()) } catch (e: IllegalArgumentException) { throw AudiobookError.Unexpected() }
        }
    }

    /**
     * Renews the login of the current account with its refresh token (the access token lasts about an hour). Several
     * requests failing at once share one renewal. True if there is a fresh token now. [send] does this by itself on a
     * 401; `app.mediaHttp` does it for covers and downloads.
     */
    suspend fun renewLogin(): Boolean = refreshToken()

    private suspend fun refreshToken(): Boolean {
        val job = synchronized(this) {
            refreshing ?: host.scope.async {
                val s = server ?: return@async false
                val savedUrl = stored?.url
                val savedUser = stored?.username
                val savedAccount = currentId
                val answer = renewed(s) ?: return@async false
                val now = stored
                // The account was switched or re-pointed while this ran: the tokens belong to another login
                if (now == null || now.url != savedUrl || now.username != savedUser || currentId != savedAccount) return@async false
                host.setAudiobooks(now.copy(accessToken = answer.accessToken, refreshToken = answer.refreshToken))
            }.also { refreshing = it }
        }
        val ok = try { job.await() } finally { synchronized(this) { if (refreshing === job) refreshing = null } }
        return ok
    }

    // endregion

    // region Library

    /**
     * Libraries, shelves and progress, and sends what was queued offline. Pages call this as they appear; it only
     * asks again when [force]d. A failure is kept in [error] only while there is nothing to show.
     */
    suspend fun load(force: Boolean = false) {
        restore()
        val s = stored ?: return
        val account = currentId
        val key = s.url + s.username
        if (!force && loadedFor == key) return
        _loading.value = true
        try {
            flushUnsent()
            coroutineScope {
                val me = async { runCatching { getJson("/api/me") }.getOrNull() }
                val started = async { runCatching { getJson("/api/me/items-in-progress?limit=100") }.getOrNull() }
                val libs = fetchLibraries()
                // All libraries at once, one slow one doesn't hold up the others
                val answers = libs.map { lib ->
                    async { runCatching { getJson("/api/libraries/${lib.id}/personalized?limit=12&minified=1") }.getOrNull() }
                }.awaitAll()
                val merged = LinkedHashMap<String, ABSShelf>()
                for (answer in answers) {
                    for (raw in (answer as? JsonArray).orEmpty()) {
                        val shelf = raw as? JsonObject ?: continue
                        val id = shelf["id"].text() ?: continue
                        if (shelf["type"].text() !in setOf("book", "podcast", "episode")) continue
                        val items = shelf["entities"].lossy(ABSItem.serializer())
                        if (items.isEmpty()) continue
                        val known = merged[id]
                        merged[id] = if (known != null) known.copy(items = known.items + items) else ABSShelf(id, shelf["label"].text() ?: "", items)
                    }
                }
                val user = me.await() as? JsonObject
                val list = started.await() as? JsonObject
                // The account was switched while this was loading: none of it applies
                if (currentId != account || stored?.url != s.url) return@coroutineScope
                _libraries.value = libs
                _shelves.value = merged.values.toList()
                if (user != null) {
                    val fromServer = user["mediaProgress"].lossy(ABSProgress.serializer()).associateBy { it.key }.toMutableMap()
                    for (entry in unsent) fromServer[entry.key] = entry
                    _progress.value = fromServer
                    _canDownload.value = ((user["permissions"] as? JsonObject)?.get("download") as? JsonPrimitive)?.booleanOrNull ?: true
                }
                if (list != null) _inProgress.value = list["libraryItems"].lossy(ABSItem.serializer())
                loadedFor = key
                _error.value = null
                saveState()
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // What's already on screen is still good, an error page would only hide it
            if (_shelves.value.isEmpty()) _error.value = e
        } finally {
            _loading.value = false
        }
    }

    private suspend fun fetchLibraries(): List<ABSLibrary> =
        (getJson("/api/libraries") as? JsonObject)?.get("libraries").lossy(ABSLibrary.serializer())

    private suspend fun ensureLibraries() {
        if (_libraries.value.isEmpty()) runCatching { fetchLibraries() }.getOrNull()?.let { _libraries.value = it }
    }

    /** The ids of this server's libraries – the same server shows the same ones, under whatever address. */
    suspend fun libraryIds(): List<String> {
        ensureLibraries()
        return _libraries.value.map { it.id }
    }

    /** The libraries of one kind (podcasts or audiobooks), what the overview pages go through. */
    suspend fun libraries(podcasts: Boolean): List<ABSLibrary> {
        ensureLibraries()
        return _libraries.value.filter { it.isPodcasts == podcasts }
    }

    /**
     * One page of a library (0-based [page]). [sort] is a server field such as `media.metadata.title`,
     * `addedAt` or `media.metadata.authorName`. [filter] selects a group, like the books of a narrator.
     */
    suspend fun items(
        library: String, page: Int = 0, pageSize: Int = 60, sort: String = "media.metadata.title",
        descending: Boolean = false, filter: ABSFilter? = null,
    ): ABSPage {
        var path = "/api/libraries/$library/items?limit=$pageSize&page=$page&sort=${enc(sort)}&desc=${if (descending) 1 else 0}&minified=1"
        if (filter != null) {
            val value = java.util.Base64.getEncoder().encodeToString(filter.value.toByteArray())
            path += "&filter=${filter.group}.${enc(value)}"
        }
        val answer = getJson(path) as? JsonObject ?: throw AudiobookError.Unexpected()
        return ABSPage(answer["results"].lossy(ABSItem.serializer()), (answer["total"] as? JsonPrimitive)?.content?.toIntOrNull() ?: 0)
    }

    /** One item with everything the server knows (chapters, tracks, episodes). */
    suspend fun item(id: String): ABSItem = get(ABSItem.serializer(), "/api/items/$id?expanded=1")

    /** All books of a series or narrator (all pages), in all audiobook libraries unless [library] says which. */
    suspend fun filtered(group: String, value: String, library: String?, sort: String = "media.metadata.title"): List<ABSItem> {
        val ids = if (library != null) listOf(library) else libraries(podcasts = false).map { it.id }
        val out = mutableListOf<ABSItem>()
        for (id in ids) {
            var page = 0
            while (true) {
                val answer = items(id, page, 200, sort, filter = ABSFilter(group, value))
                out += answer.items
                page++
                if (answer.items.isEmpty() || page * 200 >= answer.total) break
            }
        }
        return out
    }

    /** An author with their books and series. */
    suspend fun author(id: String): ABSAuthorPage {
        val a = getJson("/api/authors/$id?include=items,series") as? JsonObject ?: throw AudiobookError.Unexpected()
        val series = (a["series"] as? JsonArray).orEmpty().mapNotNull { e ->
            val s = e as? JsonObject ?: return@mapNotNull null
            val sid = s["id"].text() ?: return@mapNotNull null
            val books = s["items"].lossy(ABSItem.serializer())
            ABSSeriesEntry(sid, s["name"].text() ?: "", books.firstOrNull()?.libraryId ?: "", books.firstOrNull()?.id, books.size)
        }
        val author = ABSAuthor(a["id"].text() ?: id, a["name"].text() ?: "", a["description"].text())
        return ABSAuthorPage(author, a["libraryItems"].lossy(ABSItem.serializer()), series.sortedWith(compareBy(collator) { it.name }))
    }

    /** Every author of the audiobook libraries, sorted by name. */
    suspend fun allAuthors(): List<ABSAuthor> {
        val out = mutableListOf<ABSAuthor>()
        for (lib in libraries(podcasts = false)) {
            out += (getJson("/api/libraries/${lib.id}/authors") as? JsonObject)?.get("authors").lossy(ABSAuthor.serializer())
        }
        return out.sortedWith(compareBy(collator) { it.name })
    }

    /** Every series of the audiobook libraries (the cover is the first book's). */
    suspend fun allSeries(): List<ABSSeriesEntry> {
        val out = mutableListOf<ABSSeriesEntry>()
        for (lib in libraries(podcasts = false)) {
            val answer = getJson("/api/libraries/${lib.id}/series?limit=500&page=0&sort=name&minified=1") as? JsonObject
            for (e in (answer?.get("results") as? JsonArray).orEmpty()) {
                val s = e as? JsonObject ?: continue
                val id = s["id"].text() ?: continue
                val books = s["books"].lossy(ABSItem.serializer())
                out += ABSSeriesEntry(id, s["name"].text() ?: "", lib.id, books.firstOrNull()?.id, books.size)
            }
        }
        return out
    }

    /** Asks all libraries at once; a library that fails is left out. Empty when not connected. */
    suspend fun search(query: String): ABSSearchResults {
        if (stored == null || query.isBlank()) return ABSSearchResults()
        ensureLibraries()
        val q = enc(query)
        val answers = coroutineScope {
            _libraries.value.map { lib ->
                async { runCatching { getJson("/api/libraries/${lib.id}/search?q=$q&limit=8") as? JsonObject }.getOrNull() }
            }.awaitAll()
        }
        val items = mutableListOf<ABSItem>()
        val authors = mutableListOf<ABSAuthor>()
        val series = mutableListOf<ABSSeriesRef>()
        val narrators = mutableListOf<String>()
        for (a in answers.filterNotNull()) {
            for (key in listOf("book", "podcast")) {
                for (e in (a[key] as? JsonArray).orEmpty()) {
                    (e as? JsonObject)?.get("libraryItem").lossy1(ABSItem.serializer())?.let { items += it }
                }
            }
            authors += a["authors"].lossy(ABSAuthor.serializer())
            for (e in (a["series"] as? JsonArray).orEmpty()) (e as? JsonObject)?.get("series").lossy1(ABSSeriesRef.serializer())?.let { series += it }
            for (e in (a["narrators"] as? JsonArray).orEmpty()) (e as? JsonObject)?.get("name").text()?.let { narrators += it }
        }
        return ABSSearchResults(items, authors, series, narrators)
    }

    /** Marks a book or episode as listened to (or not) on the server, then reloads the progress. */
    suspend fun setFinished(item: ABSItem, episode: ABSEpisode?, finished: Boolean) {
        val path = "/api/me/progress/${item.id}" + (episode?.let { "/${it.id}" } ?: "")
        send(path, "PATCH", buildJsonObject { put("isFinished", finished) })
        load(force = true)
    }

    // endregion

    // region Listening sessions

    /**
     * Opens a listening session for a book or an episode (direct play, no transcoding). Play the tracks from
     * [trackURL] (streams, through `app.mediaHttp`), start at [ABSSession.currentTime], report with [syncSession].
     */
    suspend fun startSession(item: String, episode: String?): ABSSession {
        val s = server ?: throw AudiobookError.NotConnected()
        val body = buildJsonObject {
            put("forceDirectPlay", true)
            put("forceTranscode", false)
            put("mediaPlayer", "tonalo")
            put("supportedMimeTypes", buildJsonArray {
                for (m in listOf("audio/mpeg", "audio/mp4", "audio/aac", "audio/flac", "audio/x-aiff", "audio/ogg")) add(m)
            })
            put("deviceInfo", buildJsonObject { put("clientName", "Tonalo Android"); put("deviceId", s.deviceId) })
        }
        val data = send("/api/items/$item/play" + (episode?.let { "/$it" } ?: ""), "POST", body)
        return withContext(Dispatchers.Default) {
            try { Network.json.decodeFromString(ABSSession.serializer(), data.decodeToString()) } catch (e: IllegalArgumentException) { throw AudiobookError.Unexpected() }
        }
    }

    /**
     * Tells the server the position and how many seconds were really listened to since the last report (every ~30 s
     * and on pause). With [close] the session ends – do it when playback stops for good.
     */
    suspend fun syncSession(id: String, currentTime: Double, timeListened: Double, duration: Double, close: Boolean = false) {
        val body = buildJsonObject { put("currentTime", currentTime); put("timeListened", timeListened); put("duration", duration) }
        send("/api/session/$id/${if (close) "close" else "sync"}", "POST", body, 10)
    }

    // endregion

    companion object {
        private val JSON = "application/json".toMediaType()
        private val collator: Collator = Collator.getInstance()

        private fun enc(s: String): String = URLEncoder.encode(s, "UTF-8").replace("+", "%20")

        private fun JsonElement?.text(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content

        /** The entries of an array that decode; entries of an unknown shape are skipped, the others stay. */
        private fun <T> JsonElement?.lossy(serializer: KSerializer<T>): List<T> =
            (this as? JsonArray).orEmpty().mapNotNull { decodeOrNull(it, serializer) }

        private fun <T> JsonElement?.lossy1(serializer: KSerializer<T>): T? = decodeOrNull(this, serializer)

        private fun <T> decodeOrNull(e: JsonElement?, serializer: KSerializer<T>): T? =
            if (e == null) null else try { Network.json.decodeFromJsonElement(serializer, e) } catch (x: IllegalArgumentException) { null }

        private fun client(timeoutSeconds: Long, retry: Boolean): OkHttpClient =
            (if (retry) Network.http else Network.httpNoRetry).newBuilder().callTimeout(timeoutSeconds, TimeUnit.SECONDS).build()

        private suspend fun exchange(request: Request, client: OkHttpClient): Pair<Int, ByteArray> {
            val response = client.newCall(request).await()
            return withContext(Dispatchers.IO) { response.use { it.code to (it.body?.bytes() ?: ByteArray(0)) } }
        }

        private fun request(server: AudiobookServer, path: String, method: String, body: String?, authorized: Boolean = true): Request {
            val url = (server.url + path).toHttpUrlOrNull() ?: throw AudiobookError.Unexpected()
            val builder = Request.Builder().url(url)
            (if (authorized) server.authorized else server.httpHeaders).forEach { (k, v) -> builder.header(k, v) }
            val requestBody = when {
                body != null -> body.toRequestBody(JSON)
                method == "GET" -> null
                else -> ByteArray(0).toRequestBody()
            }
            return builder.method(method, requestBody).build()
        }

        private suspend fun login(url: String, username: String, password: String, headers: List<HeaderField>): AudiobookServer {
            val new = AudiobookServer(url = url, username = username, accessToken = "", headers = headers)
            val body = buildJsonObject { put("username", username); put("password", password) }.toString()
            // Without x-return-tokens the server keeps the refresh token in a cookie, for browsers
            val target = "$url/login".toHttpUrlOrNull() ?: throw AudiobookError.Unexpected()
            val request = Request.Builder().url(target).apply {
                new.httpHeaders.forEach { (k, v) -> header(k, v) }
                header("x-return-tokens", "true")
            }.post(body.toRequestBody(JSON)).build()
            val (status, data) = exchange(request, client(20, retry = false))
            if (status == 401) throw AudiobookError.Login()
            val user = (if (status == 200) parse(data) as? JsonObject else null)?.get("user") as? JsonObject
            val token = user?.get("accessToken").text() ?: user?.get("token").text() ?: throw AudiobookError.Unexpected()
            return new.copy(accessToken = token, refreshToken = user?.get("refreshToken").text())
        }

        private fun parse(data: ByteArray): JsonElement? =
            try { Network.json.parseToJsonElement(data.decodeToString()) } catch (e: IllegalArgumentException) { null }

        /** Whether this address and these headers get through to the server the login is from. A login that ran out is renewed. */
        private suspend fun checked(server: AudiobookServer): AudiobookServer {
            suspend fun status(s: AudiobookServer): Int {
                val (code, data) = exchange(request(s, "/api/me", "GET", null), client(15, retry = true))
                // A proxy's login page can answer 200 too
                if (code == 200 && ((parse(data) as? JsonObject)?.get("id")).text() == null) throw AudiobookError.Unexpected()
                return code
            }
            var s = server
            var code = status(s)
            if (code == 401) {
                renewed(s)?.let { s = it; code = status(s) }
            }
            if (code == 401) throw AudiobookError.Refused()
            if (code != 200) throw AudiobookError.Unexpected()
            return s
        }

        /** Trades the refresh token for a new access token (and a new refresh token). Null when that doesn't work. */
        private suspend fun renewed(s: AudiobookServer): AudiobookServer? {
            val refresh = s.refreshToken ?: return null
            return try {
                val url = "${s.url}/auth/refresh".toHttpUrlOrNull() ?: return null
                val request = Request.Builder().url(url).apply {
                    s.httpHeaders.forEach { (k, v) -> header(k, v) }
                    header("x-refresh-token", refresh)
                    // Every renewal replaces the refresh token, and without this the server only hands the new one to a cookie
                    header("x-return-tokens", "true")
                }.post(ByteArray(0).toRequestBody()).build()
                val (status, data) = exchange(request, client(20, retry = false))
                if (status != 200) return null
                val user = (parse(data) as? JsonObject)?.get("user") as? JsonObject
                val token = user?.get("accessToken").text() ?: return null
                s.copy(accessToken = token, refreshToken = user?.get("refreshToken").text() ?: refresh)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                null
            }
        }

        /**
         * Which server answers at this address (`"audiobookshelf|2.17.0"`), asked without the login. In someone else's
         * network the same private IP may belong to anything, so the login is only sent once the answer matches the
         * server outside. [attempts] > 1 tries again after a slow Wi-Fi moment. Null if nothing answers like Audiobookshelf.
         */
        suspend fun identity(server: AudiobookServer, attempts: Int = 1): String? {
            for (i in 0 until attempts) {
                if (i > 0) delay(800)
                currentCoroutineContext().ensureActive()
                identityOnce(server)?.let { return it }
            }
            return null
        }

        private suspend fun identityOnce(server: AudiobookServer): String? {
            return try {
                val url = "${server.url}/status".toHttpUrlOrNull() ?: return null
                val request = Request.Builder().url(url).apply { server.httpHeaders.forEach { (k, v) -> header(k, v) } }.build()
                val (status, data) = exchange(request, client(3, retry = true))
                if (status != 200) return null
                val answer = parse(data) as? JsonObject ?: return null
                val version = answer["serverVersion"].text() ?: return null
                "${answer["app"].text() ?: ""}|$version"
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                null
            }
        }
    }
}
