package app.tonalo.android.link

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import app.tonalo.android.TonaloApplication
import app.tonalo.android.data.Network
import app.tonalo.android.data.Song
import app.tonalo.android.data.Station
import app.tonalo.android.data.await
import app.tonalo.android.dj.DJ
import app.tonalo.android.playback.Playback
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.ConnectionPool
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/** What the other side reports – the fields of Link.snapshot() in tv/app/js/link.js and of the iPhone's Jukebox. */
@Serializable
data class LinkState(
    val active: Boolean = false,
    val user: String? = null,
    val server: String? = null,
    val playing: Boolean? = null,
    /** Seconds */
    val position: Double? = null,
    val duration: Double? = null,
    /** When the snapshot was taken (ms, the other side's clock) – the position counts on from there. */
    val at: Double? = null,
    /** When this line was sent, on the same clock as `at`: together they don't depend on both clocks being right. */
    val sent: Double? = null,
    val station: Station? = null,
    val queue: List<Song>? = null,
    val index: Int? = null,
    /** Where `queue` starts in the whole queue (only a window around the current song is sent). */
    val offset: Int? = null,
    val shuffle: Boolean? = null,
    val repeat: String? = null,
    val context: Source? = null,
    /** Guests of a Jukebox, by name. */
    val guests: List<String>? = null,
    /** This phone is only a guest there: someone with another account is signed in. */
    val jukebox: Boolean? = null,
) {
    @Serializable
    data class Source(val kind: String? = null, val id: String? = null, val name: String? = null)
}

/** Tonalo nearby: a TV, a computer, or a phone hosting a Jukebox. */
data class LinkDevice(val id: String, val name: String, val host: String, val port: Int, val kind: String) {
    val isPhone get() = kind == "phone"
    val isPC get() = kind == "pc"
    val base get() = "http://${if (':' in host) "[$host]" else host}:$port"
}

@Serializable
data class Pairing(val tv: String, val name: String, val keyId: String, val key: String, val guest: Boolean? = null)

@Serializable
private data class SavedAddress(val host: String, val port: Int, val kind: String, val name: String)

/** The other side whose music this phone shows right now. `atLocal` is `state.at` moved to this phone's clock. */
data class Remote(val device: LinkDevice, val state: LinkState, val guest: Boolean, val atLocal: Long) {
    /** Seconds, counting on from the last report like a clock. */
    fun position(now: Long = System.currentTimeMillis()): Double {
        val p = (state.position ?: 0.0) + if (state.playing == true) (now - atLocal).coerceAtLeast(0) / 1000.0 else 0.0
        val d = state.duration ?: 0.0
        return if (d > 0) p.coerceAtMost(d) else p
    }
}

enum class PairResult { OK, WRONG_CODE, EXPIRED, FAILED }

/**
 * Tonalo on another device nearby, like the iPhone's TVLink:
 * - Your own TV or computer (same account): while it plays, the player here shows what plays there,
 *   and music picked on the phone plays on it.
 * - A Jukebox (someone else's TV or phone, same server): you see what plays, add songs and skip.
 * Found with mDNS (_tonalo._tcp) in the home network, paired once with a code from the other screen.
 * Nothing goes through the internet.
 */
object TvLink {
    private lateinit var app: TonaloApplication
    private val nsd by lazy { app.getSystemService(NsdManager::class.java) }
    private val prefs by lazy { app.getSharedPreferences("link", Context.MODE_PRIVATE) }
    private val http = OkHttpClient.Builder()
        .connectTimeout(8, TimeUnit.SECONDS)
        .readTimeout(35, TimeUnit.SECONDS)
        .followRedirects(false)
        .retryOnConnectionFailure(false)
        // A fresh connection for every request: the TV closes idle ones after 5 s, and a command sent on such a
        // dead one would be lost (it isn't sent again – it might already have been done)
        .connectionPool(ConnectionPool(0, 1, TimeUnit.SECONDS))
        .build()
    private val jsonType = "application/json".toMediaType()

    private val _devices = MutableStateFlow<List<LinkDevice>>(emptyList())
    /** Devices with Tonalo found nearby (and those known by their last address) – this phone's own Jukebox not among them. */
    val devices: StateFlow<List<LinkDevice>> = _devices.asStateFlow()

    private val _pairings = MutableStateFlow<List<Pairing>>(emptyList())
    val pairings: StateFlow<List<Pairing>> = _pairings.asStateFlow()

    private val _remote = MutableStateFlow<Remote?>(null)
    /** The TV or Jukebox whose music the player shows right now. */
    val remote: StateFlow<Remote?> = _remote.asStateFlow()

    private val _ownTv = MutableStateFlow<LinkDevice?>(null)
    /** The own TV while it's connected and ready – music playing here can move over to it. */
    val ownTv: StateFlow<LinkDevice?> = _ownTv.asStateFlow()

    private val _guestOnly = MutableStateFlow<Set<String>>(emptySet())
    /** Own TVs where someone with another account is signed in: this phone can join their Jukebox. */
    val guestOnly: StateFlow<Set<String>> = _guestOnly.asStateFlow()

    private val _jukebox = MutableStateFlow<String?>(null)
    /** The Jukebox this phone has joined as a guest (its device id). */
    val jukebox: StateFlow<String?> = _jukebox.asStateFlow()

    private val _messages = MutableSharedFlow<String>(extraBufferCapacity = 8)
    /** Short notes for the screen ("TV isn't answering"). */
    val messages: SharedFlow<String> = _messages.asSharedFlow()

    private val found = mutableMapOf<String, LinkDevice>()
    private val listeners = mutableMapOf<String, Job>()
    private val clockOffset = mutableMapOf<String, Long>()
    /** Per device: did the last report say playing, and was it the first after connecting. */
    private val wasPlaying = mutableMapOf<String, Boolean>()
    private val firstReport = mutableSetOf<String>()
    /** Device and server ("id|address") where the server turned out to be this account's under another address. */
    private val sameServer = mutableSetOf<String>()
    private val checking = mutableSetOf<String>()
    /** Own devices that are signed in as this account right now (a TV can have someone else's profile open). */
    private val sameUser = mutableSetOf<String>()
    private var discovery: NsdManager.DiscoveryListener? = null
    private var running = false

    fun init(app: TonaloApplication) {
        this.app = app
        _jukebox.value = prefs.getString("jukebox", null)
        loadPairings()
    }

    private val storageKey get() = app.current.value?.id?.let { "tv.$it" }

    private val deviceName get() = app.current.value?.username ?: Build.MODEL

    /** Stays the same for this installation: a Jukebox tells two guests with the same name apart by it. */
    val installId: String
        get() = prefs.getString("install", null) ?: LinkCrypto.random(8).hex.also { prefs.edit().putString("install", it).apply() }

    // region Finding

    fun start() {
        if (running) return
        running = true
        loadPairings()
        publish()
        startDiscovery()
        connect()
    }

    fun stop() {
        running = false
        discovery?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        discovery = null
        listeners.values.forEach { it.cancel() }
        listeners.clear()
        synchronized(resolveQueue) { resolveQueue.clear() }
        // What was found may be gone by the time the app is back (discovery finds it again on start) –
        // except what is being controlled right now
        val keep = setOfNotNull(_remote.value?.device?.id, _ownTv.value?.id, _jukebox.value)
        found.keys.retainAll(keep)
        _ownTv.value = null
        sameUser.clear()
        if (_remote.value != null) tvGone(keepQueue = false)
        publish()
    }

    fun accountChanged() {
        stop()
        sameServer.clear()
        _guestOnly.value = emptySet()
        _jukebox.value = null
        prefs.edit().remove("jukebox").apply()
        loadPairings()
        start()
    }

    private fun saved(): Map<String, SavedAddress> = runCatching {
        prefs.getString("addresses", null)?.let {
            Network.json.decodeFromString(MapSerializer(String.serializer(), SavedAddress.serializer()), it)
        }
    }.getOrNull().orEmpty()

    private fun remember(d: LinkDevice) {
        val map = saved() + (d.id to SavedAddress(d.host, d.port, d.kind, d.name))
        prefs.edit().putString("addresses", Network.json.encodeToString(MapSerializer(String.serializer(), SavedAddress.serializer()), map)).apply()
    }

    /** Found by mDNS, plus paired devices only known by their last address (mDNS is sometimes slow or blocked). */
    private fun publish() {
        val known = saved().filter { (id, _) -> found[id] == null && _pairings.value.any { it.tv == id } }
            .map { (id, s) -> LinkDevice(id, s.name, s.host, s.port, s.kind) }
        _devices.value = (found.values + known).filter { it.id != JukeboxHost.id }.sortedBy { it.name.lowercase() }
        if (revocations().isNotEmpty()) deliverRevocations()
    }

    private fun startDiscovery() {
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) = resolve(info)
            override fun onServiceLost(info: NsdServiceInfo) {
                app.scope.launch {
                    val gone = found.values.filter { it.name == info.serviceName }.map { it.id }
                    gone.forEach { found.remove(it) }
                    publish()
                }
            }
        }
        discovery = listener
        runCatching { nsd.discoverServices("_tonalo._tcp", NsdManager.PROTOCOL_DNS_SD, listener) }
    }

    /** Android resolves one service at a time: the others wait their turn. */
    private val resolveQueue = ArrayDeque<NsdServiceInfo>()
    private var resolving = false

    private fun resolve(info: NsdServiceInfo) {
        synchronized(resolveQueue) {
            resolveQueue.addLast(info)
            if (resolving) return
            resolving = true
        }
        next()
    }

    private fun next() {
        val info = synchronized(resolveQueue) {
            resolveQueue.removeFirstOrNull() ?: run { resolving = false; return }
        }
        @Suppress("DEPRECATION")
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) { next() }
            override fun onServiceResolved(s: NsdServiceInfo) {
                val id = s.attributes["id"]?.decodeToString()
                @Suppress("DEPRECATION")
                val host = s.host?.hostAddress
                if (id != null && host != null) {
                    val d = LinkDevice(id, s.serviceName, host, s.port, s.attributes["kind"]?.decodeToString() ?: "tv")
                    app.scope.launch {
                        found[id] = d
                        publish()
                        connect()
                    }
                }
                next()
            }
        })
    }

    /** For networks where mDNS doesn't get through: the address shown on the TV (or the computer's IP). */
    suspend fun addByAddress(address: String): LinkDevice? {
        val text = address.trim().removePrefix("http://").substringBefore('/')
        val host: String
        val port: Int
        if (text.startsWith("[")) {
            // [IPv6] or [IPv6]:port
            host = text.substring(1).substringBefore(']')
            port = text.substringAfter("]:", "").toIntOrNull() ?: 47913
        } else if (text.count { it == ':' } > 1) {
            // IPv6 without brackets: no port
            host = text
            port = 47913
        } else {
            host = text.substringBefore(':')
            port = text.substringAfter(':', "").toIntOrNull() ?: 47913
        }
        if (host.isEmpty()) return null
        val probe = LinkDevice("", "", host, port, "tv")
        return try {
            val r = http.newCall(Request.Builder().url("${probe.base}/info").build()).await()
            r.use {
                val o = Network.json.parseToJsonElement(withContext(Dispatchers.IO) { it.body?.string() ?: "" }).jsonObject
                if (o["app"]?.jsonPrimitive?.content != "tonalo") return null
                val id = (o["id"] as? JsonPrimitive)?.content?.takeIf { it.isNotEmpty() } ?: return null
                val name = o["name"]?.jsonPrimitive?.content ?: host
                // /info doesn't say what kind it is: a known device keeps its kind, a Jukebox is told by its name
                val kind = found[id]?.kind ?: saved()[id]?.kind ?: if (name == JukeboxHost.NAME) "phone" else "tv"
                val d = LinkDevice(id, name, host, port, kind)
                found[d.id] = d
                remember(d)
                publish()
                d
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            null
        }
    }

    // endregion

    // region Pairing

    fun pairing(deviceId: String) = _pairings.value.firstOrNull { it.tv == deviceId }

    private fun loadPairings() {
        val key = storageKey ?: run { _pairings.value = emptyList(); return }
        _pairings.value = app.accounts.loadSecret(key)?.let {
            runCatching { Network.json.decodeFromString(ListSerializer(Pairing.serializer()), it) }.getOrNull()
        }.orEmpty()
    }

    private fun savePairings() {
        storageKey?.let { app.accounts.saveSecret(it, Network.json.encodeToString(ListSerializer(Pairing.serializer()), _pairings.value)) }
    }

    /** Asks the other side to show a code. 200 shows the code, 503: Tonalo there isn't ready yet, 409: another profile is open there, 0: no answer. */
    suspend fun startPairing(device: LinkDevice, guest: Boolean): Int {
        // Own device: the other side checks that it is the same profile (409 if not)
        val body = buildJsonObject {
            put("guest", guest); put("device", deviceName)
            if (!guest) app.current.value?.username?.let { put("user", it) }
        }.toString().toByteArray()
        return runCatching { post(device, "/pair/start", body, null).first }.getOrDefault(0)
    }

    suspend fun finishPairing(device: LinkDevice, code: String, guest: Boolean): PairResult {
        val mine = LinkCrypto.newKeyPair()
        val pub = LinkCrypto.publicBytes(mine)
        val body = buildJsonObject {
            put("device", deviceName); put("uid", installId); put("guest", guest)
            put("pub", pub.hex); put("proof", LinkCrypto.proof(code, pub).hex)
        }.toString().toByteArray()
        val (status, answer) = runCatching { post(device, "/pair/finish", body, null) }.getOrNull() ?: return PairResult.FAILED
        return when (status) {
            200 -> {
                val o = runCatching { Network.json.parseToJsonElement(answer).jsonObject }.getOrNull() ?: return PairResult.FAILED
                val other = o["pub"]?.jsonPrimitive?.content?.unhex() ?: return PairResult.FAILED
                val key = LinkCrypto.pairingKey(mine, other, code) ?: return PairResult.FAILED
                val tv = o["tv"]?.jsonPrimitive?.content ?: device.id
                val keyId = (o["id"] as? JsonPrimitive)?.content?.takeIf { it.isNotEmpty() } ?: return PairResult.FAILED
                val p = Pairing(tv, o["name"]?.jsonPrimitive?.content ?: device.name, keyId, key.hex, guest)
                _pairings.value = _pairings.value.filterNot { it.tv == tv } + p
                savePairings()
                remember(device)
                if (guest) join(device) else connect()
                PairResult.OK
            }
            403 -> PairResult.WRONG_CODE
            410, 429 -> PairResult.EXPIRED
            else -> PairResult.FAILED
        }
    }

    fun unpair(tv: String) {
        // The device loses the DJ with the pairing – asked while the key that proves who asks still exists
        // (if it can't be reached now, the request is kept until it can)
        _pairings.value.firstOrNull { it.tv == tv }?.takeIf { it.guest != true }?.let { revokeDJ(it) }
        _pairings.value = _pairings.value.filterNot { it.tv == tv }
        savePairings()
        if (_jukebox.value == tv) setJukebox(null)
        listeners.remove(tv)?.cancel()
        if (_remote.value?.device?.id == tv) tvGone(keepQueue = false)
        if (_ownTv.value?.id == tv) _ownTv.value = null
        sameUser.remove(tv)
    }

    // endregion

    // region Jukebox as a guest

    private fun setJukebox(id: String?) {
        _jukebox.value = id
        prefs.edit().apply { if (id == null) remove("jukebox") else putString("jukebox", id) }.apply()
    }

    /** Joins a Jukebox this phone is paired with: from now on the player here shows it. */
    fun join(device: LinkDevice) {
        listeners.values.forEach { it.cancel() }
        listeners.clear()
        if (_remote.value != null) tvGone(keepQueue = false)
        setJukebox(device.id)
        connect()
    }

    fun leave() {
        listeners.values.forEach { it.cancel() }
        listeners.clear()
        setJukebox(null)
        if (_remote.value != null) tvGone(keepQueue = false)
        connect()
    }

    // endregion

    // region Live

    /** Follows the joined Jukebox, or else all own devices nearby at once: the one that plays is shown. */
    private fun connect() {
        if (!running || app.current.value == null) return
        val targets = _jukebox.value?.let { j -> _devices.value.filter { it.id == j } }
            ?: _devices.value.filter { d -> pairing(d.id)?.let { it.guest != true } == true }
        for (d in targets) if (listeners[d.id]?.isActive != true) {
            val p = pairing(d.id) ?: continue
            listeners[d.id] = app.scope.launch { followLoop(d, p) }
        }
    }

    private suspend fun followLoop(device: LinkDevice, pairing: Pairing) {
        var misses = 0
        while (running && misses < 3) {
            val d = _devices.value.firstOrNull { it.id == device.id } ?: device
            val got = try { follow(d, pairing) } catch (e: CancellationException) { throw e } catch (e: Exception) { false }
            misses = if (got) 0 else misses + 1
            release(device.id)
            delay(2000)
        }
        listeners.remove(device.id)
        // Dropped out (switched off, the host's phone locked for a moment): looked for again later
        delay(20_000)
        if (running) connect()
    }

    /** True when anything came from the other side before the connection ended. */
    private suspend fun follow(device: LinkDevice, pairing: Pairing): Boolean {
        val key = pairing.key.unhex() ?: return false
        val auth = LinkCrypto.authorization("GET", "/events", ByteArray(0), pairing.keyId, key, clockOffset[pairing.tv] ?: 0)
        val req = Request.Builder().url("${device.base}/events").header("Authorization", auth).build()
        val response = http.newCall(req).await()
        var received = false
        firstReport += device.id
        wasPlaying[device.id] = false
        response.use { r ->
            if (r.code == 401) {
                val body = withContext(Dispatchers.IO) { r.body?.string() ?: "" }
                // Only the paired device itself may take the pairing away: after an address change another device
                // can answer on the saved address
                if (!learnClock(body, pairing.tv) && infoId(device) == pairing.tv) unpair(pairing.tv)
                return false
            }
            if (r.code != 200) return false
            remember(device)
            syncDJ()
            val source = r.body?.source() ?: return false
            while (true) {
                val line = withContext(Dispatchers.IO) { source.readUtf8Line() } ?: break
                if (!line.startsWith("data: ")) continue
                val s = runCatching { Network.json.decodeFromString(LinkState.serializer(), line.removePrefix("data: ")) }.getOrNull() ?: continue
                received = true
                apply(device, pairing, s)
            }
        }
        return received
    }

    /** The id the device at this address reports (GET /info), or null if it doesn't answer. */
    private suspend fun infoId(device: LinkDevice): String? = try {
        val r = http.newCall(Request.Builder().url("${device.base}/info").build()).await()
        r.use {
            val o = Network.json.parseToJsonElement(withContext(Dispatchers.IO) { it.body?.string() ?: "" }).jsonObject
            (o["id"] as? JsonPrimitive)?.content
        }
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        null
    }

    /** The device stops being followed: if its music was shown, the player lets go of it. */
    private fun release(id: String) {
        sameUser.remove(id)
        if (_ownTv.value?.id == id) _ownTv.value = null
        if (_remote.value?.device?.id == id) tvGone(keepQueue = true)
    }

    private fun apply(device: LinkDevice, pairing: Pairing, s: LinkState) {
        val guest = pairing.guest == true || _jukebox.value == device.id
        val now = System.currentTimeMillis()
        // From here on `at` is on this phone's clock: the other side's clock may be off
        val atLocal = if (s.at != null && s.sent != null) now - (s.sent - s.at).toLong().coerceAtLeast(0) else now
        val first = firstReport.remove(device.id)

        if (pairing.guest != true) {
            _guestOnly.value = if (s.jukebox == true) _guestOnly.value + device.id else _guestOnly.value - device.id
            // Joined as a guest, and now the TV is back on this account: it's the own TV again
            if (guest && s.jukebox != true) { leave(); return }
        }
        if (guest) {
            // A guest follows the Jukebox all the time, also before anything plays there
            if (!s.active || matches(s, guest = true, device.id)) _remote.value = Remote(device, s, guest = true, atLocal = atLocal)
            return
        }
        // Someone else is signed in on the TV: nothing of theirs shows here until this phone joins
        if (s.jukebox == true) {
            if (_ownTv.value?.id == device.id) _ownTv.value = null
            if (_remote.value?.device?.id == device.id) tvGone(keepQueue = false)
            return
        }
        // The DJ goes only to a device signed in as this account: the setup lives per account there,
        // and another person's slot must never receive this phone's key
        val mine = s.user?.equals(app.current.value?.username ?: "", ignoreCase = true) == true
        val wasMine = device.id in sameUser
        if (mine) sameUser += device.id else sameUser -= device.id
        if (mine && !wasMine) syncDJ() // the TV is on this account (again)
        _ownTv.value = device
        val playing = s.active && s.playing == true
        val same = s.active && matches(s, guest = false, device.id)
        if (s.active && !same) checkServer(s, device, pairing)
        val shown = _remote.value?.device?.id == device.id
        when {
            same && shown -> _remote.value = Remote(device, s, guest = false, atLocal = atLocal)
            same -> {
                // The TV takes over when it starts playing – or, right after connecting, when it plays and this phone
                // doesn't: music playing here isn't cut off just because the app came back to the front
                val localPlaying = Playback.service?.isPlayingLocally() == true
                val started = playing && (if (first) !localPlaying else wasPlaying[device.id] != true)
                val other = _remote.value
                if (started && (other == null || other.state.playing != true)) {
                    Playback.service?.pauseForTv()
                    _remote.value = Remote(device, s, guest = false, atLocal = atLocal)
                }
            }
            shown -> tvGone(keepQueue = true)
        }
        wasPlaying[device.id] = playing
    }

    /** The own TV: same account on the same server. A Jukebox: the same server, so the songs added are there too. */
    private fun matches(s: LinkState, guest: Boolean, device: String): Boolean {
        val acc = app.current.value ?: return false
        val server = s.server ?: return false
        if (!guest && s.user?.equals(acc.username, ignoreCase = true) != true) return false
        if ("$device|$server" in sameServer) return true
        fun norm(url: String?): String? {
            val u = url?.trim()?.toHttpUrlOrNull() ?: return null
            return u.host.lowercase() + ":" + u.port
        }
        val other = norm(server)
        return other != null && (other == norm(acc.serverURL) || other == norm(acc.localURL))
    }

    /** The address differs (the TV knows the server by its home IP, the phone by its domain): asks for a song playing there. */
    private fun checkServer(s: LinkState, device: LinkDevice, pairing: Pairing) {
        val server = s.server ?: return
        val key = "${device.id}|$server"
        val songs = s.queue.orEmpty()
        val song = songs.getOrNull(s.index ?: -1) ?: songs.firstOrNull() ?: return
        if (key in sameServer || !checking.add(key)) return
        app.scope.launch {
            val client = app.client()
            if (client != null && runCatching { client.call("getSong", "id" to song.id) }.isSuccess) {
                sameServer += key
                firstReport += device.id
                apply(device, pairing, s)
            } else {
                delay(30_000)
                checking.remove(key)
            }
        }
    }

    /** The music moves to this phone ("play here"): the player stops showing the TV right away. */
    fun letGo() {
        val id = _remote.value?.device?.id ?: return
        _remote.value = null
        wasPlaying[id] = false
    }

    /** The TV stopped or went away. Its music stays here, paused, to go on with – a guest goes back to its own. */
    private fun tvGone(keepQueue: Boolean) {
        val r = _remote.value ?: return
        _remote.value = null
        val s = r.state
        if (keepQueue && !r.guest && s.station == null && !s.queue.isNullOrEmpty()) {
            Playback.service?.takeOver(s.queue, s.index ?: 0, (r.position() * 1000).toLong(), play = false)
        }
    }

    // endregion

    // region DJ on paired devices

    private var djSync: Job? = null

    /**
     * Brings the own devices that are connected right now up to date: they get the DJ setup, or lose it.
     * Only devices paired with this account as its own – never a Jukebox, and not while someone else is signed in there.
     */
    fun syncDJ() {
        if (!::app.isInitialized) return
        djSync?.cancel()
        djSync = app.scope.launch {
            delay(1500) // a model name being typed isn't sent letter by letter
            val setup = DJ.shared
            for (id in listeners.keys.toList()) {
                val device = _devices.value.firstOrNull { it.id == id } ?: continue
                val p = pairing(id) ?: continue
                if (device.isPhone || p.guest == true || id in _guestOnly.value || id !in sameUser) continue
                val mark = setup?.let { fingerprint(it, p) } ?: "off"
                if (prefs.getString("dj.shared.$id", null) == mark) continue
                if (sendDJ(setup, device, p)) {
                    prefs.edit().putString("dj.shared.$id", mark).apply()
                    forgetRevocation(id) // it has a setup again – an old request to remove one must not undo that
                }
            }
        }
    }

    /**
     * A request to take the DJ setup away from a device whose pairing is gone (unpaired, account removed). It's kept –
     * with the key that proves who asks, encrypted like the pairings – until the device can be reached, so a TV that
     * was off at that moment doesn't keep a provider key for good.
     */
    @Serializable
    private data class Revocation(val tv: String, val keyId: String, val key: String)

    private fun revocations(): List<Revocation> = runCatching {
        app.accounts.loadSecret("dj.revoke")?.let { Network.json.decodeFromString(ListSerializer(Revocation.serializer()), it) }
    }.getOrNull().orEmpty()

    private fun saveRevocations(list: List<Revocation>) {
        app.accounts.saveSecret("dj.revoke", if (list.isEmpty()) null else Network.json.encodeToString(ListSerializer(Revocation.serializer()), list))
    }

    private fun forgetRevocation(tv: String) {
        val list = revocations()
        if (list.any { it.tv == tv }) saveRevocations(list.filter { it.tv != tv })
    }

    private var delivering = false

    private fun revokeDJ(p: Pairing) {
        if (prefs.getString("dj.shared.${p.tv}", null) == null) return
        prefs.edit().remove("dj.shared.${p.tv}").apply()
        saveRevocations(revocations().filter { it.tv != p.tv } + Revocation(p.tv, p.keyId, p.key))
        deliverRevocations()
    }

    /** For an account that goes away: its pairings are deleted, the devices still lose what this phone gave them. */
    fun revokeDJ(forAccount: String) {
        val list = app.accounts.loadSecret("tv.$forAccount")?.let {
            runCatching { Network.json.decodeFromString(ListSerializer(Pairing.serializer()), it) }.getOrNull()
        }.orEmpty()
        list.filter { it.guest != true }.forEach { revokeDJ(it) }
    }

    private fun deliverRevocations() {
        if (!::app.isInitialized || delivering) return
        delivering = true
        app.scope.launch {
            try {
                for (r in revocations()) {
                    val device = _devices.value.firstOrNull { it.id == r.tv } ?: continue // not reachable now: later
                    if (sendDJ(null, device, Pairing(r.tv, "", r.keyId, r.key))) forgetRevocation(r.tv)
                }
            } finally { delivering = false }
        }
    }

    private fun fingerprint(setup: Map<String, String>, p: Pairing): String {
        val text = setup.toSortedMap().entries.joinToString("\n") { it.key + "=" + it.value } + "\n" + p.keyId
        return java.security.MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).hex
    }

    /**
     * One setup for one device, or null to take it away. The link itself is only signed, so the content is sealed
     * (AES-GCM) with a key derived from the pairing's – a key for a provider must not be readable in the Wi-Fi.
     */
    private suspend fun sendDJ(setup: Map<String, String>?, device: LinkDevice, p: Pairing): Boolean {
        val key = p.key.unhex() ?: return false
        val plain = (setup?.let { m -> buildJsonObject { m.forEach { (k, v) -> put(k, v) } } } ?: buildJsonObject { put("off", true) }).toString().toByteArray()
        val sealKey = LinkCrypto.hmac(key, "tonalo-dj".toByteArray())
        val iv = LinkCrypto.random(12)
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(javax.crypto.Cipher.ENCRYPT_MODE, javax.crypto.spec.SecretKeySpec(sealKey, "AES"), javax.crypto.spec.GCMParameterSpec(128, iv))
        cipher.updateAAD(p.keyId.toByteArray())
        val box = iv + cipher.doFinal(plain) // nonce · content · tag, like CryptoKit's combined form
        val body = buildJsonObject { put("box", box.hex) }.toString().toByteArray()
        repeat(2) {
            val auth = LinkCrypto.authorization("POST", "/dj", body, p.keyId, key, clockOffset[p.tv] ?: 0)
            val (code, answer) = runCatching { post(device, "/dj", body, auth) }.getOrDefault(0 to "")
            if (code == 200) return true
            if (code != 401 || !learnClock(answer, p.tv)) return false
        }
        return false
    }

    // endregion

    // region Commands

    private fun songJson(s: Song): JsonElement = Network.json.encodeToJsonElement(Song.serializer(), s)

    /** Plays songs over there. Very long lists go as a window around the start. `at`: seconds into the first song. */
    fun play(songs: List<Song>, start: Int, shuffled: Boolean, context: String?, at: Double = 0.0, kind: String = "mix") {
        val from = maxOf(0, minOf(start - 100, songs.size - 500))
        val window = songs.subList(from, minOf(songs.size, from + 500))
        command(buildJsonObject {
            put("cmd", "play"); put("songs", JsonArray(window.map(::songJson))); put("index", start - from)
            put("shuffle", shuffled); put("position", at)
            if (context != null) put("context", buildJsonObject { put("kind", kind); put("name", context) })
        })
    }

    fun playStation(station: Station, list: List<Station>) = command(buildJsonObject {
        put("cmd", "station"); put("station", Network.json.encodeToJsonElement(Station.serializer(), station))
        put("list", JsonArray(list.map { Network.json.encodeToJsonElement(Station.serializer(), it) }))
    })

    fun add(songs: List<Song>, next: Boolean) {
        val max = if (_remote.value?.guest == true) 20 else 200
        command(buildJsonObject { put("cmd", if (next) "playNext" else "enqueue"); put("songs", JsonArray(songs.take(max).map(::songJson))) })
    }

    /** The DJ's new set: everything after the song playing there makes way for it. */
    fun replaceUpNext(songs: List<Song>, dj: Boolean) = command(buildJsonObject {
        put("cmd", "upNext"); put("songs", JsonArray(songs.take(200).map(::songJson)))
        if (dj) put("context", buildJsonObject { put("kind", "dj"); put("name", "DJ") })
    })

    fun command(name: String, vararg extra: Pair<String, Any?>) = command(buildJsonObject {
        put("cmd", name)
        extra.forEach { (k, v) ->
            when (v) {
                is Boolean -> put(k, v)
                is Number -> put(k, v)
                is String -> put(k, v)
                null -> {}
                else -> put(k, v.toString())
            }
        }
    })

    private fun command(cmd: JsonObject) {
        val target = _remote.value?.device ?: _ownTv.value ?: return
        val pairing = pairing(target.id) ?: return
        val key = pairing.key.unhex() ?: return
        val body = cmd.toString().toByteArray()
        app.scope.launch {
            var status = 0
            for (attempt in 0..1) {
                val auth = LinkCrypto.authorization("POST", "/command", body, pairing.keyId, key, clockOffset[pairing.tv] ?: 0)
                val (code, answer) = runCatching { post(target, "/command", body, auth) }.getOrDefault(0 to "")
                status = code
                // Twice at most: the second time with the other side's clock, if only that was off
                if (code != 401 || !learnClock(answer, pairing.tv)) break
            }
            if (status != 200) _messages.tryEmit(target.name)
        }
    }

    private suspend fun post(device: LinkDevice, path: String, body: ByteArray, auth: String?): Pair<Int, String> {
        val req = Request.Builder().url(device.base + path).post(body.toRequestBody(jsonType))
            .apply { auth?.let { header("Authorization", it) } }.build()
        return http.newCall(req).await().use { r -> r.code to withContext(Dispatchers.IO) { r.body?.string() ?: "" } }
    }

    /** True when the other side only turned the request down for the time; from now on its time is used. */
    private fun learnClock(body: String, tv: String): Boolean {
        val o = runCatching { Network.json.parseToJsonElement(body).jsonObject }.getOrNull() ?: return false
        if ((o["error"] as? JsonPrimitive)?.content != "clock") return false
        (o["now"] as? JsonPrimitive)?.content?.toDoubleOrNull()?.let { clockOffset[tv] = it.toLong() - System.currentTimeMillis() / 1000 }
        return true
    }

    // endregion
}
