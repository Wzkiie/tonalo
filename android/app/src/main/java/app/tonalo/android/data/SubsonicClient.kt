package app.tonalo.android.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.Call
import okhttp3.Callback
import okhttp3.FormBody
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resumeWithException

sealed class SubsonicException(message: String) : Exception(message) {
    class BadUrl : SubsonicException("The server address is not valid.")
    class Server(val code: Int, message: String) : SubsonicException(message)
    class NotSubsonic(val status: Int) : SubsonicException(
        "The server answered with something other than Subsonic (HTTP $status). Check the address and your custom headers."
    )
    class Http(val status: Int) : SubsonicException("Server error (HTTP $status).")

    /** The server didn't take the form body, so nothing was changed and the address version is safe to send. */
    val formPostRefused: Boolean
        get() = when (this) {
            is Server -> code == 10
            is Http -> status in setOf(404, 405, 415, 501)
            is NotSubsonic -> status in setOf(404, 405, 415, 501)
            is BadUrl -> false
        }
}

/** True for answers the server gave on purpose (wrong password, not found) – not worth replacing with the cache. */
val Throwable.isServerAnswer: Boolean get() = this is SubsonicException.Server

object Network {
    val json = Json { ignoreUnknownKeys = true; coerceInputValues = true; explicitNulls = false }

    /**
     * One client for everything that talks to the server.
     * - No disk cache: Subsonic puts the login token into every address.
     * - Redirects are followed by hand: only to the same host and never from https down to http,
     *   so custom headers (e.g. a Cloudflare Access secret) and the token only reach the server itself.
     */
    val http: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .followRedirects(false)
        .followSslRedirects(false)
        .addInterceptor(SafeRedirects)
        .build()

    /** For requests that change something: OkHttp must not silently send them again after a broken connection (network switch). */
    val httpNoRetry: OkHttpClient by lazy { http.newBuilder().retryOnConnectionFailure(false).build() }

    private object SafeRedirects : Interceptor {
        override fun intercept(chain: Interceptor.Chain): Response {
            var request = chain.request()
            var response = chain.proceed(request)
            repeat(5) {
                if (!response.isRedirect) return response
                val target = response.header("Location")?.let { request.url.resolve(it) } ?: return response
                if (!allowsRedirect(request.url, target)) return response
                response.close()
                val method = if (response.code in setOf(307, 308)) request.method else "GET"
                val body = if (method == request.method) request.body else null
                request = request.newBuilder().url(target).method(method, body).build()
                response = chain.proceed(request)
            }
            return response
        }
    }

    fun allowsRedirect(from: HttpUrl, to: HttpUrl): Boolean =
        from.host == to.host && !(from.isHttps && !to.isHttps)
}

suspend fun Call.await(): Response = suspendCancellableCoroutine { cont ->
    enqueue(object : Callback {
        override fun onResponse(call: Call, response: Response) {
            // The handler closes the response if the coroutine is cancelled before it gets to run again
            if (cont.isActive) cont.resume(response) { _ -> response.close() } else response.close()
        }
        override fun onFailure(call: Call, e: IOException) { if (!cont.isCancelled) cont.resumeWithException(e) }
    })
    cont.invokeOnCancellation { runCatching { cancel() } }
}

/** Talks to a Subsonic/Navidrome server. Every request carries the account's custom headers. */
class SubsonicClient(val account: Account, private val cache: LibraryCache? = null, atHome: Boolean = false) {

    /** Talking to the home address: faster, and without the custom headers – those belong to the proxy outside. */
    val atHome: Boolean = atHome && account.localURL != null
    val base: String get() = if (atHome) account.localURL ?: account.serverURL else account.serverURL
    val headers: Map<String, String> get() = if (atHome) emptyMap() else account.httpHeaders

    companion object {
        /** Also how other apps recognize us in the shared play queue ("changedBy"). */
        const val CLIENT_NAME = "Tonalo-Android"
        private const val API_VERSION = "1.16.1"

        fun makeToken(password: String): Pair<String, String> {
            val salt = UUID.randomUUID().toString().replace("-", "").take(12).lowercase()
            val digest = MessageDigest.getInstance("MD5").digest((password + salt).toByteArray())
            return salt to digest.joinToString("") { "%02x".format(it) }
        }

        /**
         * Addresses that only exist in the home network: private IPs, localhost, .local and similar names.
         * Only for those is plain http tried automatically – anywhere else that would send the login unencrypted.
         */
        fun isLocal(address: String): Boolean {
            val withScheme = if ("://" in address) address else "http://$address"
            val host = withScheme.toHttpUrlOrNull()?.host?.lowercase() ?: return false
            if (host == "localhost" || ('.' !in host && ':' !in host)) return true
            if (listOf(".local", ".lan", ".home", ".home.arpa", ".internal", ".fritz.box").any { host.endsWith(it) }) return true
            // Four numbers – not a name that merely starts with some (10.0.0.1.example.com)
            val p = host.split('.').map { it.toIntOrNull()?.takeIf { n -> n in 0..255 } }
            if (p.size == 4 && p.all { it != null }) {
                val p = p.map { it!! }
                return p[0] == 10 || p[0] == 127 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && p[1] in 16..31) ||
                    (p[0] == 169 && p[1] == 254) || (p[0] == 100 && p[1] in 64..127) // last: Tailscale & co.
            }
            val v6 = host.trim('[', ']')
            if (':' !in v6 || !v6.all { it.isLetterOrDigit() || it == ':' || it == '.' || it == '%' }) return false
            return v6.startsWith("fd") || v6.startsWith("fc") || v6.startsWith("fe80") || v6 == "::1"
        }

        /** Home addresses are usually plain http on the local network. */
        fun normalizeLocal(address: String): String? {
            val s = address.trim()
            if (s.isEmpty()) return null
            val lower = s.lowercase()
            return normalize(if (lower.startsWith("http://") || lower.startsWith("https://")) s else "http://$s")
        }

        fun normalize(address: String): String {
            var s = address.trim()
            if (!s.lowercase().startsWith("http://") && !s.lowercase().startsWith("https://")) s = "https://$s"
            s = s.trimEnd('/')
            if (s.endsWith("/rest")) s = s.dropLast(5)
            return s
        }
    }

    fun url(method: String, params: List<Pair<String, String>> = emptyList()): HttpUrl? {
        val b = "$base/rest/$method".toHttpUrlOrNull()?.newBuilder() ?: return null
        // OkHttp encodes "+" in query values, so "Simon + Garfunkel" keeps its plus
        b.addQueryParameter("u", account.username)
            .addQueryParameter("t", account.token)
            .addQueryParameter("s", account.salt)
            .addQueryParameter("v", API_VERSION)
            .addQueryParameter("c", CLIENT_NAME)
            .addQueryParameter("f", "json")
        params.forEach { (k, v) -> b.addQueryParameter(k, v) }
        return b.build()
    }

    fun url(method: String, vararg params: Pair<String, String>) = url(method, params.toList())

    /** The same address with this account's current login (u, t, s) – replacing any older one – and v/c if missing. */
    fun withAuth(url: HttpUrl): HttpUrl = url.newBuilder()
        .setQueryParameter("u", account.username)
        .setQueryParameter("t", account.token)
        .setQueryParameter("s", account.salt)
        .apply {
            if (url.queryParameter("v") == null) setQueryParameter("v", API_VERSION)
            if (url.queryParameter("c") == null) setQueryParameter("c", CLIENT_NAME)
        }.build()

    private fun request(url: HttpUrl): Request.Builder =
        Request.Builder().url(url).apply { headers.forEach { (k, v) -> header(k, v) } }

    /** `retry = false` for what changes something and isn't safe to do twice (a scrobble, deleting). */
    suspend fun call(method: String, vararg params: Pair<String, String>, retry: Boolean = true): Payload {
        val u = url(method, params.toList()) ?: throw SubsonicException.BadUrl()
        val key = LibraryCache.key(method, params.toList())
        return try {
            val (payload, raw) = send(request(u).build(), retry)
            if (key != null && cache != null) withContext(Dispatchers.IO) { cache.save(account.id, key, raw) }
            payload
        } catch (e: Exception) {
            // No (usable) connection: the last known answer is better than an error.
            if (key != null && cache != null && e !is kotlinx.coroutines.CancellationException && !e.isServerAnswer) {
                withContext(Dispatchers.IO) { cache.load(account.id, key) }?.let { return it }
            }
            throw e
        }
    }

    /** The saved answer of a library request, without asking the server – for showing a page at once. */
    fun cached(method: String, vararg params: Pair<String, String>): Payload? =
        LibraryCache.key(method, params.toList())?.let { cache?.load(account.id, it) }

    /** Long lists (a whole queue or playlist) go in a form body instead of the address, which servers limit in length. */
    /**
     * `retry`: let the network layer ask again after a connection broke. Only for what can safely happen twice –
     * creating a playlist or adding a song can't: the first request may have got through.
     */
    suspend fun post(method: String, params: List<Pair<String, String>>, retry: Boolean = false): Payload {
        val full = url(method, params) ?: throw SubsonicException.BadUrl()
        val endpoint = full.newBuilder().query(null).build()
        val form = FormBody.Builder().apply {
            for (i in 0 until full.querySize) add(full.queryParameterName(i), full.queryParameterValue(i) ?: "")
        }.build()
        return try {
            send(request(endpoint).post(form).build(), retry).first
        } catch (e: SubsonicException) {
            if (!e.formPostRefused) throw e
            send(request(full).build(), retry).first
        }
        // Anything else (a timeout, say) is not asked again: the change may already have been made.
    }

    private suspend fun send(r: Request, retry: Boolean = true): Pair<Payload, String> {
        val response = (if (retry) Network.http else Network.httpNoRetry).newCall(r).await()
        // use outside withContext: a cancellation on entering it must still close the response
        return response.use { resp ->
            withContext(Dispatchers.IO) {
                val status = resp.code
                val type = resp.header("Content-Type") ?: ""
                if ("json" !in type) throw SubsonicException.NotSubsonic(status)
                val raw = resp.body?.string() ?: ""
                val env = runCatching { Network.json.decodeFromString(Envelope.serializer(), raw) }.getOrNull()
                    ?: throw if (status >= 400) SubsonicException.Http(status) else SubsonicException.NotSubsonic(status)
                if (env.response.status != "ok") {
                    throw SubsonicException.Server(env.response.error?.code ?: 0, errorText(env.response.error))
                }
                env.response to raw
            }
        }
    }

    private fun errorText(e: SubsonicErrorBody?): String = when (e?.code) {
        40 -> "Wrong username or password."
        50 -> "Your server doesn’t allow this change."
        else -> e?.message ?: "Unknown error"
    }

    // region Endpoints

    suspend fun ping() { call("ping") }

    /**
     * Which server software answers at this address ("navidrome|0.58.0"), asked without the login.
     * In someone else's network the same private IP may belong to anything, so the token is only sent
     * once the answer matches the server outside. Any Subsonic answer counts, even "parameter missing".
     */
    suspend fun identity(attempts: Int = 1): String? {
        for (i in 0 until attempts) {
            if (i > 0) kotlinx.coroutines.delay(800)
            kotlinx.coroutines.currentCoroutineContext().ensureActive()
            identityOnce()?.let { return it }
        }
        return null
    }

    private suspend fun identityOnce(): String? = runCatching {
        val u = "$base/rest/ping".toHttpUrlOrNull()?.newBuilder()
            ?.addQueryParameter("v", API_VERSION)?.addQueryParameter("c", CLIENT_NAME)?.addQueryParameter("f", "json")
            ?.build() ?: return null
        val quick = Network.http.newBuilder().callTimeout(3, TimeUnit.SECONDS).build()
        val req = Request.Builder().url(u).apply { headers.forEach { (k, v) -> header(k, v) } }.build()
        quick.newCall(req).await().use { resp ->
            if (resp.header("Content-Type")?.contains("json") != true) return null
            val env = Network.json.decodeFromString(Envelope.serializer(), withContext(Dispatchers.IO) { resp.body?.string() ?: "" })
            "${env.response.type ?: ""}|${env.response.serverVersion ?: ""}"
        }
    }.getOrElse { if (it is kotlinx.coroutines.CancellationException) throw it else null }

    suspend fun stations(): List<Station> =
        call("getInternetRadioStations").internetRadioStations?.internetRadioStation.orEmpty()

    suspend fun albumList(type: String, size: Int = 30, offset: Int = 0, genre: String? = null): List<Album> {
        val p = mutableListOf("type" to type, "size" to "$size", "offset" to "$offset")
        if (genre != null) p += "genre" to genre
        return call("getAlbumList2", *p.toTypedArray()).albumList2?.album ?: emptyList()
    }

    suspend fun album(id: String): Album = call("getAlbum", "id" to id).album ?: throw SubsonicException.Http(404)

    suspend fun artists(): List<Artist> =
        call("getArtists").artists?.index.orEmpty().flatMap { it.artist.orEmpty() }

    suspend fun artist(id: String): Artist = call("getArtist", "id" to id).artist ?: throw SubsonicException.Http(404)

    suspend fun artistInfo(id: String): ArtistInfo? =
        runCatching { call("getArtistInfo2", "id" to id, "count" to "10").artistInfo2 }.getOrNull()

    suspend fun topSongs(artistName: String): List<Song> =
        runCatching { call("getTopSongs", "artist" to artistName, "count" to "10").topSongs?.song }.getOrNull().orEmpty()

    suspend fun similarSongs(id: String): List<Song> =
        runCatching { call("getSimilarSongs2", "id" to id, "count" to "50").similarSongs2?.song }.getOrNull().orEmpty()

    suspend fun randomSongs(size: Int = 100, genre: String? = null): List<Song> {
        val p = mutableListOf("size" to "$size")
        if (genre != null) p += "genre" to genre
        return call("getRandomSongs", *p.toTypedArray()).randomSongs?.song.orEmpty()
    }

    suspend fun playlists(): List<Playlist> = call("getPlaylists").playlists?.playlist.orEmpty()

    suspend fun playlist(id: String): Playlist = call("getPlaylist", "id" to id).playlist ?: throw SubsonicException.Http(404)

    suspend fun genres(): List<Genre> = call("getGenres").genres?.genre.orEmpty()

    suspend fun starred(): SearchBody = call("getStarred2").starred2 ?: SearchBody()

    suspend fun search(query: String): SearchBody =
        call("search3", "query" to query, "artistCount" to "10", "albumCount" to "20", "songCount" to "40").searchResult3 ?: SearchBody()

    suspend fun setStar(songId: String? = null, albumId: String? = null, artistId: String? = null, on: Boolean) {
        val p = buildList {
            songId?.let { add("id" to it) }
            albumId?.let { add("albumId" to it) }
            artistId?.let { add("artistId" to it) }
        }
        call(if (on) "star" else "unstar", *p.toTypedArray())
    }

    /**
     * Returns false if the server couldn't be reached (or can't take it right now: login, 5xx, a proxy page),
     * so the scrobble can be sent later. A permanent refusal (song gone, bad request) also returns true:
     * sending it again would never work, so it must not stay in the queue.
     */
    suspend fun scrobble(id: String, submission: Boolean, timeMillis: Long? = null): Boolean {
        val p = mutableListOf("id" to id, "submission" to submission.toString())
        if (timeMillis != null) p += "time" to "$timeMillis"
        return try {
            call("scrobble", *p.toTypedArray(), retry = false)
            true
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: SubsonicException.Server) {
            e.code !in 40..44 // 40-44: login problems – may work again after signing in
        } catch (e: SubsonicException.Http) {
            e.status in 400..499 && e.status !in setOf(401, 403, 407, 408, 429)
        } catch (e: Exception) {
            false
        }
    }

    suspend fun playQueue(): PlayQueue? = runCatching { call("getPlayQueue").playQueue }.getOrNull()

    suspend fun savePlayQueue(ids: List<String>, current: String, positionMillis: Long) {
        val items = ids.map { "id" to it } + listOf("current" to current, "position" to "$positionMillis")
        runCatching { post("savePlayQueue", items, retry = true) }
    }

    suspend fun createPlaylist(name: String, songIds: List<String>): Playlist? =
        post("createPlaylist", listOf("name" to name) + songIds.map { "songId" to it }).playlist

    suspend fun updatePlaylist(id: String, name: String? = null, add: List<String> = emptyList(), removeIndexes: List<Int> = emptyList()) {
        val items = buildList {
            add("playlistId" to id)
            name?.let { add("name" to it) }
            add.forEach { add("songIdToAdd" to it) }
            removeIndexes.forEach { add("songIndexToRemove" to "$it") }
        }
        post("updatePlaylist", items)
    }

    /** Replaces all songs of a playlist – used for reordering, which updatePlaylist can't do. */
    suspend fun replacePlaylistSongs(id: String, songIds: List<String>) {
        post("createPlaylist", listOf("playlistId" to id) + songIds.map { "songId" to it })
    }

    suspend fun deletePlaylist(id: String) {
        call("deletePlaylist", "id" to id, retry = false)
        // The saved answers still list it: gone from the disk too, or it reappears offline and after a restart
        cache?.let { c ->
            withContext(Dispatchers.IO) {
                LibraryCache.key("getPlaylists", emptyList())?.let { c.delete(account.id, it) }
                LibraryCache.key("getPlaylist", listOf("id" to id))?.let { c.delete(account.id, it) }
            }
        }
    }

    suspend fun lyrics(songId: String): Lyrics? {
        val list = runCatching { call("getLyricsBySongId", "id" to songId).lyricsList?.structuredLyrics }.getOrNull()
        if (list.isNullOrEmpty()) return null
        val pick = list.firstOrNull { it.synced == true } ?: list[0]
        val lines = pick.line.orEmpty()
        return if (lines.isEmpty()) null else Lyrics(pick.synced ?: false, lines)
    }

    // endregion

    // region Media URLs

    fun coverURL(id: String?, size: Int = 300): String? =
        if (id.isNullOrEmpty()) null else url("getCoverArt", "id" to id, "size" to "$size")?.toString()

    /**
     * `estimateContentLength` gives converted streams a length, so the player can seek in them
     * (constant bitrate seeking) instead of only playing from the start.
     */
    /** For offline downloads: the original file byte for byte, or the converted version. Carries no token or salt. */
    fun downloadURL(song: Song, quality: AudioQuality): String? {
        val q = quality.resolved(song)
        val full = (if (q.format == null) url("download", "id" to song.id)?.toString() else streamURL(song, q)) ?: return null
        // Without token and salt: this address is stored in the download index. The login is added per request (TonaloApplication.mediaHttp)
        return full.toHttpUrlOrNull()?.newBuilder()?.removeAllQueryParameters("t")?.removeAllQueryParameters("s")?.build()?.toString()
    }

    fun streamURL(song: Song, quality: AudioQuality): String? {
        val q = quality.resolved(song)
        val format = q.format ?: return url("stream", "id" to song.id, "format" to "raw")?.toString()
        return url("stream", "id" to song.id, "format" to format, "maxBitRate" to "${q.bitRate}",
            "estimateContentLength" to "true")?.toString()
    }

    // endregion
}
