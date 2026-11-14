package app.tonalo.android

import android.app.Application
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network as AndroidNetwork
import android.net.NetworkCapabilities
import app.tonalo.android.data.Account
import app.tonalo.android.data.AccountStore
import app.tonalo.android.data.AudioQuality
import app.tonalo.android.data.AudiobookFiles
import app.tonalo.android.data.AudiobookHost
import app.tonalo.android.data.AudiobookLibrary
import app.tonalo.android.data.AudiobookServer
import app.tonalo.android.data.LibraryCache
import app.tonalo.android.data.Network
import app.tonalo.android.data.QueueStore
import app.tonalo.android.data.ScrobbleQueue
import app.tonalo.android.data.Settings
import app.tonalo.android.data.SubsonicClient
import app.tonalo.android.dj.DJ
import app.tonalo.android.downloads.Downloads
import app.tonalo.android.link.JukeboxHost
import app.tonalo.android.link.TvLink
import coil3.ImageLoader
import coil3.PlatformContext
import coil3.SingletonImageLoader
import coil3.network.okhttp.OkHttpNetworkFetcherFactory
import coil3.request.allowHardware
import coil3.request.crossfade
import coil3.svg.SvgDecoder
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.OkHttpClient

/** Everything the screens and the playback service share: accounts, the current server, settings. */
class TonaloApplication : Application(), SingletonImageLoader.Factory, AudiobookHost {

    lateinit var accounts: AccountStore; private set
    lateinit var cache: LibraryCache; private set
    lateinit var settings: Settings; private set
    lateinit var queues: QueueStore; private set
    lateinit var scrobbles: ScrobbleQueue; private set
    lateinit var history: app.tonalo.android.data.PlayHistory; private set

    /** The Audiobookshelf connection of the current account and everything read from it (audiobooks and podcasts). */
    val books = AudiobookLibrary()

    /** For requests that must finish even when the screen or the service that started them is gone. */
    override val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private val _accountList = MutableStateFlow<List<Account>>(emptyList())
    val accountList: StateFlow<List<Account>> = _accountList.asStateFlow()

    private val _current = MutableStateFlow<Account?>(null)
    /** The account in use; null shows the login. */
    override val current: StateFlow<Account?> = _current.asStateFlow()

    private val _online = MutableStateFlow(true)
    /** There is a network – without one, the pages show what's saved and the downloads play. */
    override val online: StateFlow<Boolean> = _online.asStateFlow()

    private val _atHome = MutableStateFlow(false)
    /** The account's home address answers (Wi-Fi at home): requests go there, faster and without the proxy. */
    val atHome: StateFlow<Boolean> = _atHome.asStateFlow()

    /** The account whose (outside) music server this address belongs to: by host, then by the user name in the address, then the current one. */
    private fun accountFor(url: okhttp3.HttpUrl): Account? {
        val matching = _accountList.value.filter { it.hasMusic && it.serverURL.toHttpUrlOrNull()?.host == url.host }
        if (matching.size <= 1) return matching.firstOrNull()
        val user = url.queryParameter("u")
        return matching.firstOrNull { it.username == user } ?: matching.firstOrNull { it.id == _current.value?.id } ?: matching.first()
    }

    /**
     * The Audiobookshelf server this address belongs to, with whether it is the home address: by the host of an
     * account's outside address (the current account first), or the host of the current account's home address
     * while that is in use.
     */
    private fun bookServerFor(url: okhttp3.HttpUrl): Pair<AudiobookServer, Boolean>? {
        val matching = _accountList.value.filter { it.audiobooks?.url?.toHttpUrlOrNull()?.host == url.host }
        val outside = matching.firstOrNull { it.id == _current.value?.id } ?: matching.firstOrNull()
        outside?.audiobooks?.let { return it to false }
        val server = _current.value?.audiobooks ?: return null
        if (books.atHome.value && server.localURL?.toHttpUrlOrNull()?.host == url.host) return server to true
        return null
    }

    /**
     * For covers, streams and downloads: adds the account's custom headers – only for addresses on an
     * account's own (outside) server, so they never reach a radio station or the home address.
     * Requests to its API also get the account's current login (token, salt) here, so addresses saved without
     * one (downloads) – or with an outdated one – keep working after a re-login.
     * The same for Audiobookshelf: requests to the books server get its custom headers and the current
     * `Authorization: Bearer` token (covers via Coil, streams via ExoPlayer, downloads); at the verified home
     * address only the token, never the proxy's headers.
     */
    val mediaHttp: OkHttpClient by lazy {
        Network.http.newBuilder().addInterceptor(Interceptor { chain ->
            val req = chain.request()
            val account = accountFor(req.url)
            val isRest = req.url.encodedPath.contains("/rest/")
            val book = if (account != null && isRest) null else bookServerFor(req.url)
            if (account == null && book == null) return@Interceptor chain.proceed(req)
            val b = req.newBuilder()
            if (account != null) {
                account.httpHeaders.forEach { (k, v) -> b.header(k, v) }
                if (isRest) b.url(SubsonicClient(account).withAuth(req.url))
            }
            if (book != null) {
                val (server, home) = book
                if (!home) server.httpHeaders.forEach { (k, v) -> b.header(k, v) }
                b.header("Authorization", "Bearer " + server.accessToken)
            }
            var response = chain.proceed(b.build())
            // The access token lasts about an hour: renew it once and ask again (covers, downloads running in the background)
            val current = _current.value?.audiobooks
            if (book != null && response.code == 401 && current != null && current.url == book.first.url && current.username == book.first.username &&
                runBlocking { books.renewLogin() }) {
                response.close()
                val token = bookServerFor(req.url)?.first?.accessToken ?: book.first.accessToken
                response = chain.proceed(b.header("Authorization", "Bearer $token").build())
            }
            response
        }).build()
    }

    override fun onCreate() {
        super.onCreate()
        accounts = AccountStore(this)
        cache = LibraryCache(this)
        settings = Settings(this)
        queues = QueueStore(this)
        scrobbles = ScrobbleQueue(this)
        history = app.tonalo.android.data.PlayHistory(this)
        AudiobookFiles.init(this)
        val list = mergeAudiobookAccounts(accounts.load())
        _accountList.value = list
        _current.value = list.firstOrNull { it.id == accounts.selectedId } ?: list.firstOrNull()
        books.attach(this)
        watchNetwork()
        checkRoute()
        flushScrobbles() // what was played offline goes out at launch, not only once playback starts
        scope.launch { books.flushUnsent() } // the same for audiobook positions saved offline
        // Which songs are downloaded: known right away, not only after the Downloads page was opened
        Thread { runCatching { app.tonalo.android.downloads.Downloads.manager(this) } }.start()
        TvLink.init(this)
        JukeboxHost.init(this)
        DJ.init(this)
    }

    /** The client of the current account's music server; null when nobody is signed in or the account has audiobooks only. */
    fun client(): SubsonicClient? = _current.value?.takeIf { it.hasMusic }?.let { SubsonicClient(it, cache, _atHome.value) }

    /**
     * Adds or replaces an account (same id) and switches to it. The same login saved again stays one account and keeps
     * what only it has (a music login saved without audiobooks keeps the Audiobookshelf connection).
     */
    override fun save(account: Account): Boolean {
        val existing = _accountList.value
        fun same(a: Account) = if (account.hasMusic) a.serverURL == account.serverURL && a.username == account.username
        else !a.hasMusic && a.audiobooks?.url == account.audiobooks?.url && a.username == account.username
        val old = existing.firstOrNull { it.id == account.id } ?: existing.firstOrNull(::same)
        var saved = if (old != null && old.id != account.id) account.copy(id = old.id) else account
        if (saved.audiobooks == null && old?.audiobooks != null) saved = saved.copy(audiobooks = old.audiobooks)
        val list = existing.filterNot { it.id == saved.id } + saved
        if (!accounts.save(list)) return false
        // Another server or user under the same id: nothing of the old one's music data applies
        if (old != null && old.hasMusic && (old.serverURL != saved.serverURL || old.username != saved.username)) purgeData(saved.id)
        cache.reopen(saved.id)
        _accountList.value = list
        select(saved.id)
        return true
    }

    fun select(id: String) {
        val changed = _current.value?.id != id
        accounts.selectedId = id
        _current.value = _accountList.value.firstOrNull { it.id == id }
        _atHome.value = false
        if (changed) books.accountChanged()
        checkRoute()
        TvLink.accountChanged()
        JukeboxHost.accountChanged()
    }

    /**
     * Everything of the music side kept on the device for an account: library cache, queue, scrobbles, history,
     * downloads, covers. The audiobooks have their own files (see [AudiobookFiles]) and survive this.
     */
    private fun purgeData(id: String) {
        routePrefs.edit().remove(id).apply()
        cache.deleteAccount(id)
        queues.delete(id)
        scrobbles.delete(id)
        history.delete(id)
        Downloads.removeAccount(this, id)
        java.io.File(cacheDir, "covers/$id").deleteRecursively()
    }

    /** Deletes an account with everything of it: music data, audiobook files, and the Audiobookshelf login on the server. */
    override fun remove(account: Account) {
        val list = _accountList.value.filterNot { it.id == account.id }
        // If this can't be saved the account would be back after a restart – then keep everything of it
        if (!accounts.save(list)) return
        // The devices still hold what this phone gave them (the DJ setup): take it back before the pairings go
        app.tonalo.android.link.TvLink.revokeDJ(account.id)
        purgeData(account.id)
        account.audiobooks?.let { books.logout(it) }
        AudiobookFiles.deleteAccount(account.id)
        routePrefs.edit().remove("book:" + account.id).apply()
        _accountList.value = list
        if (_current.value?.id == account.id) {
            _current.value = list.firstOrNull()
            accounts.selectedId = _current.value?.id
            _atHome.value = false
            books.accountChanged()
            checkRoute()
            TvLink.accountChanged()
            JukeboxHost.accountChanged()
        }
    }

    /**
     * Music and audiobooks belong in one account: an account that only has audiobooks moves into a music account
     * that has none (its files with it). Runs at launch; what can't be saved stays as it was.
     */
    private fun mergeAudiobookAccounts(input: List<Account>): List<Account> {
        var list = input
        var selected = accounts.selectedId
        val moved = mutableListOf<Pair<String, String>>()
        for (only in input.filter { !it.hasMusic && it.audiobooks != null }) {
            val i = list.indexOfFirst { it.hasMusic && it.audiobooks == null }
            if (i < 0) break
            val target = list[i].copy(audiobooks = only.audiobooks)
            list = list.filterNot { it.id == only.id }.map { if (it.id == target.id) target else it }
            moved += only.id to target.id
            if (selected == only.id) selected = target.id
        }
        if (moved.isEmpty() || !accounts.save(list)) return input
        accounts.selectedId = selected
        for ((from, to) in moved) {
            AudiobookFiles.move(from, to)
            routePrefs.edit().remove("book:$from").apply()
        }
        return list
    }

    /**
     * Takes the music server out of the current account; its audiobooks stay (the user name becomes the
     * Audiobookshelf one). Everything of the music side is deleted from the device.
     */
    fun disconnectMusic() {
        val account = _current.value ?: return
        val server = account.audiobooks ?: return
        val new = account.copy(serverURL = "", localURL = null, headers = emptyList(), salt = "", token = "", username = server.username)
        val list = _accountList.value.map { if (it.id == account.id) new else it }
        if (!accounts.save(list)) return
        // The devices still hold what this phone gave them (the DJ setup): take it back
        TvLink.revokeDJ(account.id)
        purgeData(account.id)
        _accountList.value = list
        _current.value = new
        _atHome.value = false
        TvLink.accountChanged()
        JukeboxHost.accountChanged()
        checkRoute()
    }

    /**
     * Stores the Audiobookshelf connection (new tokens, new address) in the current account, or takes it out with null.
     * False if the account could not be saved; then nothing changed.
     */
    @Synchronized
    override fun setAudiobooks(server: AudiobookServer?): Boolean {
        val account = _current.value ?: return false
        val new = account.copy(audiobooks = server)
        val list = _accountList.value.map { if (it.id == account.id) new else it }
        if (!accounts.save(list)) return false
        _accountList.value = list
        _current.value = new
        return true
    }

    // region Network

    private fun capabilities(): NetworkCapabilities? {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return null
        return cm.getNetworkCapabilities(cm.activeNetwork)
    }

    /** Mobile data (or any metered network) gets the data-saving quality. */
    fun streamQuality(): AudioQuality {
        val metered = capabilities()?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) != true
        return if (metered) settings.mobileQuality.value else settings.wifiQuality.value
    }

    private fun watchNetwork() {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        _online.value = cm.activeNetwork != null
        cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: AndroidNetwork) { _online.value = true; checkRoute(); flushScrobbles(); scope.launch { books.flushUnsent() } }
            override fun onLost(network: AndroidNetwork) { _atHome.value = false; scope.launch { books.setAtHome(false) }; _online.value = cm.activeNetwork != null }
        })
    }

    @Volatile private var routeJob: Job? = null

    private val routePrefs by lazy { getSharedPreferences("route", Context.MODE_PRIVATE) }

    /**
     * On Wi-Fi or Ethernet, tries the home address. It's only used when the same server software answers there
     * as outside – a private IP in someone else's network may belong to anything, and the login must not go there.
     */
    fun flushScrobbles() { scope.launch { client()?.let { scrobbles.flush(it) } } }

    /** Checks again whether the home addresses (music and Audiobookshelf) answer; call it when the network or an address changed. */
    override fun checkRoute() {
        // Called from the network callback's thread too: all state is handled on the main thread
        scope.launch { checkRouteOnMain(); checkBookRouteOnMain() }
    }

    private fun onLocalNetwork(): Boolean {
        val caps = capabilities()
        return caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true || caps?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true
    }

    private fun checkRouteOnMain() {
        val account = _current.value
        routeJob?.cancel()
        if (account?.hasMusic != true || account.localURL == null) { _atHome.value = false; return }
        if (!onLocalNetwork()) { _atHome.value = false; return }
        routeJob = scope.launch {
            val home = // A slow Wi-Fi moment (waking up, joining) must not leave the phone on the outside address for good
            SubsonicClient(account, atHome = true).identity(attempts = 3)
            val outsideNow = if (home == null) null else SubsonicClient(account, atHome = false).identity()
            // If the outside address doesn't answer right now, compare with the last answer it gave
            val outside = if (outsideNow != null) {
                routePrefs.edit().putString(account.id, outsideNow).apply()
                outsideNow
            } else routePrefs.getString(account.id, null)
            _atHome.value = home != null && home == outside && _current.value?.id == account.id
        }
    }

    @Volatile private var bookRouteJob: Job? = null

    /** The same for Audiobookshelf, which has its own addresses: the home address is only used when the same server answers there. */
    private fun checkBookRouteOnMain() {
        bookRouteJob?.cancel()
        val account = _current.value
        val server = account?.audiobooks
        val local = server?.localURL
        if (account == null || server == null || local == null || !SubsonicClient.isLocal(local) || !onLocalNetwork()) {
            books.setAtHome(false)
            return
        }
        bookRouteJob = scope.launch {
            val home = AudiobookLibrary.identity(server.route(atHome = true), attempts = 3)
            val outsideNow = if (home == null) null else AudiobookLibrary.identity(server)
            val key = "book:" + account.id
            val outside = if (outsideNow != null) {
                routePrefs.edit().putString(key, outsideNow).apply()
                outsideNow
            } else routePrefs.getString(key, null)
            books.setAtHome(home != null && home == outside && _current.value?.id == account.id)
        }
    }

    // endregion

    override fun newImageLoader(context: PlatformContext): ImageLoader =
        ImageLoader.Builder(context)
            .components {
                add(OkHttpNetworkFetcherFactory(callFactory = { mediaHttp }))
                add(SvgDecoder.Factory())
            }
            // Software bitmaps, so the cover's color can be read for the backgrounds
            .allowHardware(false)
            .crossfade(true)
            .build()
}

val Context.tonalo: TonaloApplication get() = applicationContext as TonaloApplication
