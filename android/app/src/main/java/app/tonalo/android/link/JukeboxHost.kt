package app.tonalo.android.link

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import app.tonalo.android.TonaloApplication
import app.tonalo.android.data.Network
import app.tonalo.android.data.Song
import app.tonalo.android.playback.Playback
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
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
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.BufferedInputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.abs
import kotlin.math.min
import kotlin.math.pow

/**
 * This phone hosts a Jukebox – for the car or a party without a TV: guests nearby find it, join with a code
 * shown here, see what plays, add songs (20 at most at once) and skip. Speaks the same small protocol as the TV
 * (tv/service/service.js) and the iPhone's Jukebox. Only runs while switched on.
 */
object JukeboxHost {
    @Serializable
    data class Guest(val keyId: String, val key: String, val name: String, val uid: String? = null)

    /** A guest wants to join: the code to show on this phone. */
    data class Request(val name: String, val code: String)

    private lateinit var app: TonaloApplication
    private val prefs by lazy { app.getSharedPreferences("link", Context.MODE_PRIVATE) }
    private val nsd by lazy { app.getSystemService(NsdManager::class.java) }

    /** Stable id of this phone's Jukebox – lets the phone skip itself in the list of devices nearby. */
    val id: String
        get() = prefs.getString("jukeboxId", null) ?: LinkCrypto.random(8).hex.also { prefs.edit().putString("jukeboxId", it).apply() }

    /** What everyone nearby sees before pairing – no user name, that's for those who joined. */
    const val NAME = "Tonalo Jukebox"

    private val _running = MutableStateFlow(false)
    val running: StateFlow<Boolean> = _running.asStateFlow()
    private val _request = MutableStateFlow<Request?>(null)
    val request: StateFlow<Request?> = _request.asStateFlow()
    private val _guests = MutableStateFlow<List<Guest>>(emptyList())
    val guests: StateFlow<List<Guest>> = _guests.asStateFlow()
    private val _present = MutableStateFlow<List<String>>(emptyList())
    /** Guests connected right now, by name. */
    val present: StateFlow<List<String>> = _present.asStateFlow()
    private val _notes = MutableSharedFlow<Note>(extraBufferCapacity = 8)
    val notes: SharedFlow<Note> = _notes.asSharedFlow()

    sealed interface Note {
        data class Joined(val name: String) : Note
        data class Added(val name: String, val title: String?, val count: Int) : Note
        data class Skipped(val name: String) : Note
    }

    private var scope: CoroutineScope? = null
    private var server: ServerSocket? = null
    /** Request handlers block on sockets: they get their own bounded threads instead of the shared IO pool. */
    private var pool: ExecutorService? = null
    private val sockets = java.util.concurrent.ConcurrentHashMap.newKeySet<Socket>()
    private const val MAX_CONNECTIONS = 16
    private const val MAX_STREAMS_PER_GUEST = 3
    private const val REQUEST_DEADLINE_MS = 15_000L
    private var registration: NsdManager.RegistrationListener? = null
    private val streams = CopyOnWriteArrayList<Pair<OutputStream, Guest>>()
    private var pairing: Triple<String, Long, Int>? = null // code, until, tries
    private var failures = 0
    private var lockedUntil = 0L
    private var lockouts = 0
    private var lastStart = 0L
    private val nonces = mutableMapOf<String, Long>()

    fun init(app: TonaloApplication) { this.app = app }

    private val storageKey get() = app.current.value?.id?.let { "jukebox.$it" }

    private fun load() {
        _guests.value = storageKey?.let { app.accounts.loadSecret(it) }?.let {
            runCatching { Network.json.decodeFromString(ListSerializer(Guest.serializer()), it) }.getOrNull()
        }.orEmpty()
    }

    private fun save() {
        storageKey?.let { app.accounts.saveSecret(it, Network.json.encodeToString(ListSerializer(Guest.serializer()), _guests.value)) }
    }

    // region Switching on and off

    fun start() {
        if (_running.value) return
        load()
        val s = runCatching { ServerSocket().apply { reuseAddress = true; bind(InetSocketAddress(0)) } }.getOrNull() ?: return
        server = s
        val sc = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        scope = sc
        val executor = Executors.newFixedThreadPool(MAX_CONNECTIONS)
        pool = executor
        val dispatcher = executor.asCoroutineDispatcher()
        val open = AtomicInteger()
        _running.value = true
        sc.launch {
            while (isActive) {
                val socket = runCatching { s.accept() }.getOrNull() ?: break
                // Only from the home network, like the TV (local() in service.js): the socket listens on every
                // interface, mobile data included
                if (!fromHome(socket)) { runCatching { socket.close() }; continue }
                // Over the limit: turned away at once, so a flood of connections can't starve the others
                if (open.incrementAndGet() > MAX_CONNECTIONS) { open.decrementAndGet(); runCatching { socket.close() }; continue }
                sockets += socket
                val started = runCatching {
                    launch(dispatcher) {
                        try { runCatching { handle(socket) } } finally {
                            sockets.remove(socket); open.decrementAndGet(); runCatching { socket.close() }
                        }
                    }
                }.isSuccess
                if (!started) { sockets.remove(socket); open.decrementAndGet(); runCatching { socket.close() } }
            }
        }
        // Updates for the guests: the state every few seconds, and a ping so they notice when this phone is gone
        sc.launch {
            var n = 0
            while (isActive) {
                delay(2000)
                if (++n % 5 == 0) push() else if (n % 3 == 0) send(": ping\n\n")
            }
        }
        val info = NsdServiceInfo().apply {
            serviceName = NAME
            serviceType = "_tonalo._tcp"
            port = s.localPort
            setAttribute("id", id)
            setAttribute("kind", "phone")
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {}
            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {}
            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {}
        }
        registration = listener
        runCatching { nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener) }
    }

    fun stop() {
        registration?.let { runCatching { nsd.unregisterService(it) } }
        registration = null
        streams.forEach { runCatching { it.first.close() } }
        streams.clear()
        runCatching { server?.close() }
        server = null
        // Sockets still reading a request would otherwise hold their threads until the deadline
        sockets.forEach { runCatching { it.close() } }
        sockets.clear()
        scope?.cancel()
        scope = null
        pool?.shutdownNow()
        pool = null
        _running.value = false
        _request.value = null
        pairing = null
        _present.value = emptyList()
    }

    fun accountChanged() { if (_running.value) { stop(); start() } else load() }

    @Synchronized
    fun remove(guest: Guest) {
        _guests.value = _guests.value - guest
        save()
        streams.filter { it.second.keyId == guest.keyId }.forEach { runCatching { it.first.close() }; streams.remove(it) }
        updatePresent()
    }

    @Synchronized
    fun cancelRequest() { pairing = null; _request.value = null }

    // endregion

    // region Requests

    /** Private IPv4 and IPv6 addresses (also IPv4 mapped into IPv6), loopback and link-local – the same as service.js. */
    private fun fromHome(socket: Socket): Boolean {
        val a = socket.inetAddress?.address?.let { runCatching { java.net.InetAddress.getByAddress(it) }.getOrNull() } ?: return false
        if (a.isLoopbackAddress || a.isLinkLocalAddress || a.isSiteLocalAddress) return true
        // Unique local IPv6 (fc00::/7): Java's isSiteLocalAddress only knows the old fec0::/10
        return a is java.net.Inet6Address && (a.address[0].toInt() and 0xfe) == 0xfc
    }

    private class Req(val method: String, val path: String, val headers: Map<String, String>, val body: ByteArray)

    private fun read(socket: Socket): Req? {
        // One deadline for the whole request: a client sending a byte at a time can't hold the connection
        val deadline = System.currentTimeMillis() + REQUEST_DEADLINE_MS
        fun arm(): Boolean {
            val left = deadline - System.currentTimeMillis()
            if (left <= 0) return false
            socket.soTimeout = left.toInt()
            return true
        }
        val input = BufferedInputStream(socket.getInputStream())
        val head = StringBuilder()
        while (!head.endsWith("\r\n\r\n")) {
            if (!arm()) return null
            val b = input.read()
            if (b < 0 || head.length > 16_000) return null
            head.append(b.toChar())
        }
        val lines = head.toString().split("\r\n")
        val first = lines.first().split(" ")
        if (first.size < 2) return null
        val headers = lines.drop(1).mapNotNull { l -> l.indexOf(':').takeIf { it > 0 }?.let { l.substring(0, it).lowercase() to l.substring(it + 1).trim() } }.toMap()
        val length = (headers["content-length"]?.toIntOrNull() ?: 0).coerceIn(0, 256_000)
        val body = ByteArray(length)
        var got = 0
        while (got < length) { if (!arm()) return null; val n = input.read(body, got, length - got); if (n < 0) break; got += n }
        return Req(first[0], first[1], headers, body)
    }

    private fun reply(out: OutputStream, status: Int, body: JsonObject) {
        val data = body.toString().toByteArray()
        out.write("HTTP/1.0 $status ${if (status == 200) "OK" else "Error"}\r\nContent-Type: application/json\r\nContent-Length: ${data.size}\r\n\r\n".toByteArray())
        out.write(data)
        out.flush()
    }

    private suspend fun handle(socket: Socket) {
        val r = read(socket) ?: return
        val out = socket.getOutputStream()
        val p = runCatching { Network.json.parseToJsonElement(r.body.decodeToString()).jsonObject }.getOrNull() ?: JsonObject(emptyMap())
        fun str(k: String) = (p[k] as? JsonPrimitive)?.content
        when (r.method to r.path) {
            "GET" to "/info" -> return reply(out, 200, buildJsonObject { put("app", "tonalo"); put("id", id); put("name", NAME) })
            "POST" to "/pair/start" -> synchronized(this) {
                val now = System.currentTimeMillis()
                if (now < lockedUntil || now - lastStart < 3000) return reply(out, 429, buildJsonObject { put("error", "too many tries") })
                // A code still valid stays: anyone on the network could otherwise keep replacing it and reset its tries
                val current = pairing
                if (current != null && current.second > now) return reply(out, 200, buildJsonObject { put("ok", true) })
                lastStart = now
                val code = "%06d".format(java.security.SecureRandom().nextInt(1_000_000))
                pairing = Triple(code, now + 120_000, 0)
                _request.value = Request((str("device") ?: "Guest").take(60), code)
                return reply(out, 200, buildJsonObject { put("ok", true) })
            }
            "POST" to "/pair/finish" -> return finishPairing(out, str("pub"), str("proof"), str("device"), str("uid"))
        }
        val guest = authorized(r)
        if (guest == null) {
            val clock = clockOnly(r)
            return reply(out, 401, buildJsonObject { put("error", if (clock) "clock" else "not paired"); if (clock) put("now", System.currentTimeMillis() / 1000) })
        }
        when (r.method to r.path) {
            "GET" to "/events" -> {
                if (streams.count { it.second.keyId == guest.keyId } >= MAX_STREAMS_PER_GUEST) return reply(out, 429, buildJsonObject { put("error", "too many connections") })
                out.write("HTTP/1.0 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\n\r\n".toByteArray())
                out.flush()
                val entry = out to guest
                streams += entry
                // Removed while this was starting
                if (_guests.value.none { it.keyId == guest.keyId }) { streams.remove(entry); return }
                updatePresent()
                push()
                // Waits for the guest to go away
                socket.soTimeout = 0
                runCatching { while (socket.getInputStream().read() >= 0) { /* nothing comes */ } }
                streams.remove(entry)
                updatePresent()
                push()
            }
            "POST" to "/command" -> {
                run(p, guest)
                reply(out, 200, buildJsonObject { put("ok", true) })
            }
            else -> reply(out, 404, buildJsonObject { put("error", "not found") })
        }
    }


    /**
     * Checks the guest's proof of the code. Synchronized: guesses sent at the same moment must each count,
     * or the five tries per code (and the lockout after 15) could be got around with many requests at once.
     */
    @Synchronized
    private fun finishPairing(out: OutputStream, pubHex: String?, proofHex: String?, device: String?, uid: String?) {
        val pr = pairing
        if (pr == null || pr.second < System.currentTimeMillis()) return reply(out, 410, buildJsonObject { put("error", "expired") })
        val pub = pubHex?.unhex()
        val proof = proofHex?.unhex()
        // The code itself never comes over the network – only proof that the guest knows it
        if (pub == null || proof == null || !LinkCrypto.same(proof, LinkCrypto.proof(pr.first, pub))) {
            pairing = pr.copy(third = pr.third + 1)
            // Guessing doesn't pay off: after five wrong tries the code is gone, after 15 pairing closes for a while
            if (++failures >= 15) {
                failures = 0
                lockedUntil = System.currentTimeMillis() + min(600_000.0 * 2.0.pow(lockouts++), 86_400_000.0).toLong()
                cancelRequest()
            }
            if ((pairing?.third ?: 0) >= 5) cancelRequest()
            return reply(out, 403, buildJsonObject { put("error", "wrong code") })
        }
        val mine = LinkCrypto.newKeyPair()
        val key = LinkCrypto.pairingKey(mine, pub, pr.first) ?: return reply(out, 400, buildJsonObject { put("error", "bad key") })
        val guest = Guest(LinkCrypto.random(8).hex, key.hex, (device ?: "Guest").take(60), uid?.take(32))
        // Pairing again replaces the old pairing of the same guest
        _guests.value = _guests.value.filterNot { (it.uid != null && it.uid == guest.uid) || (it.name == guest.name && (it.uid == null || guest.uid == null)) } + guest
        save()
        cancelRequest()
        failures = 0; lockouts = 0
        _notes.tryEmit(Note.Joined(guest.name))
        return reply(out, 200, buildJsonObject {
            put("id", guest.keyId); put("pub", LinkCrypto.publicBytes(mine).hex); put("tv", id); put("name", NAME)
        })
    }

    private fun parts(r: Req): List<String>? =
        r.headers["authorization"]?.removePrefix("Tonalo ")?.split(":")?.takeIf { it.size == 4 && it[2].length >= 16 }

    private fun signed(r: Req): Guest? {
        val p = parts(r) ?: return null
        val guest = _guests.value.firstOrNull { it.keyId == p[0] } ?: return null
        val key = guest.key.unhex() ?: return null
        val want = LinkCrypto.signature(r.method, r.path, p[1], p[2], r.body, key).unhex() ?: return null
        val got = p[3].unhex() ?: return null
        return if (LinkCrypto.same(got, want)) guest else null
    }

    @Synchronized
    private fun authorized(r: Req): Guest? {
        val guest = signed(r) ?: return null
        val p = parts(r)!!
        val time = p[1].toLongOrNull() ?: return null
        val now = System.currentTimeMillis()
        if (abs(now / 1000 - time) > 120) return null
        nonces.entries.removeAll { it.value < now }
        if (nonces.containsKey(p[2])) return null
        nonces[p[2]] = now + 250_000
        return guest
    }

    /** The signature is right, the time isn't – the guest stays paired and learns this phone's time. */
    private fun clockOnly(r: Req): Boolean {
        signed(r) ?: return false
        val time = parts(r)?.get(1)?.toLongOrNull() ?: return false
        return abs(System.currentTimeMillis() / 1000 - time) > 120
    }

    // endregion

    // region What guests may do

    private suspend fun run(c: JsonObject, guest: Guest) {
        // No more than 20 at once, whatever a guest's phone sends; their hearts and play counts aren't this account's
        val songs = (c["songs"] as? JsonArray)?.take(20)?.mapNotNull {
            runCatching { Network.json.decodeFromJsonElement(Song.serializer(), it) }.getOrNull()?.copy(starred = null, playCount = null)
        }.orEmpty()
        val cmd = (c["cmd"] as? JsonPrimitive)?.content
        withContext(Dispatchers.Main) {
            val service = Playback.service
            when {
                (cmd == "enqueue" || cmd == "playNext") && songs.isNotEmpty() -> {
                    service?.addFromGuest(songs, next = cmd == "playNext")
                    _notes.tryEmit(Note.Added(guest.name, songs.singleOrNull()?.title, songs.size))
                }
                cmd == "next" -> { service?.skipFromGuest(); _notes.tryEmit(Note.Skipped(guest.name)) }
            }
        }
        delay(300)
        push()
    }

    // endregion

    // region State for the guests

    private fun updatePresent() {
        _present.value = streams.map { it.second.name }.distinct()
    }

    private fun send(text: String) {
        val data = text.toByteArray()
        var dropped = false
        for (s in streams) runCatching { synchronized(s.first) { s.first.write(data); s.first.flush() } }.onFailure {
            // Closing also ends the handler waiting on this socket
            if (streams.remove(s)) dropped = true
            runCatching { s.first.close() }
        }
        if (dropped) updatePresent()
    }

    /** The same fields as Link.snapshot() on the TV – without the account name, guests don't need it. */
    suspend fun push() {
        if (streams.isEmpty()) return
        val snapshot = withContext(Dispatchers.Main) { Playback.service?.jukeboxSnapshot(_present.value) } ?: buildJsonObject { put("active", false) }
        withContext(Dispatchers.IO) { send("data: $snapshot\n\n") }
    }

    // endregion
}
