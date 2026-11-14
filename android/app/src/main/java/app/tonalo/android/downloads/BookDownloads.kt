package app.tonalo.android.downloads

import android.content.Context
import app.tonalo.android.R
import app.tonalo.android.TonaloApplication
import app.tonalo.android.data.ABSChapter
import app.tonalo.android.data.ABSEpisode
import app.tonalo.android.data.ABSFile
import app.tonalo.android.data.ABSItem
import app.tonalo.android.data.ABSProgress
import app.tonalo.android.data.ABSSession
import app.tonalo.android.data.AudiobookError
import app.tonalo.android.data.AudiobookFiles
import app.tonalo.android.data.Network
import app.tonalo.android.playback.BookPlayer
import app.tonalo.android.tonalo
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChangedBy
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import okhttp3.Request
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.UUID

/**
 * An audiobook or a podcast with at least one finished download.
 * @property item the item as it was when downloaded (full: chapters, episodes, description), so the pages and the
 * player work without a connection
 * @property episodeIds the downloaded episodes of a podcast; empty for a book
 * @property bytes what the finished files take on this phone
 * @property dateMs when the last of them finished (milliseconds since 1970)
 */
data class DownloadedBook(val item: ABSItem, val episodeIds: List<String>, val bytes: Long, val dateMs: Long)

/** Where the download of one book or episode stands (see [BookDownloads.states]). */
sealed class BookDownloadState {
    /** Nothing was requested. */
    object None : BookDownloadState()

    /** Waits for its turn (downloads run one after the other). */
    object Queued : BookDownloadState()

    /** @property progress 0..1 */
    data class Downloading(val progress: Float) : BookDownloadState()

    /** @property bytes the size on this phone */
    data class Done(val bytes: Long) : BookDownloadState()

    /** Stopped; [BookDownloads.download] again goes on where it stopped. */
    data class Failed(val message: String) : BookDownloadState()
}

/** One audio file of a download. `index` is the file's number in the book; `name` its name in the book's folder. */
@Serializable
internal data class BookFileRec(
    val index: Int,
    val startOffset: Double,
    val duration: Double,
    val ino: String,
    val name: String,
    val size: Long = 0,
    val done: Boolean = false,
)

/** What is saved of one download (a book, or one episode): the item as it was, and its files. */
@Serializable
internal data class BookRec(
    val key: String,
    val item: ABSItem,
    val episode: ABSEpisode? = null,
    val duration: Double = 0.0,
    val chapters: List<ABSChapter> = emptyList(),
    val files: List<BookFileRec> = emptyList(),
    val dateMs: Long = 0,
) {
    val complete: Boolean get() = files.isNotEmpty() && files.all { it.done }
    val bytes: Long get() = files.sumOf { if (it.done) it.size else 0L }
}

@Serializable
internal data class BookIndex(val books: List<BookRec> = emptyList())

/**
 * Audiobooks and podcast episodes saved on the phone (port of ios/Tonalo/BookDownloads.swift).
 *
 * Files live in `AudiobookFiles.folder(account)/books/<item>[_<episode>]/<n>.<ext>`, the index in
 * `.../downloads.json` (the item with its chapters, the files and where each stands), the cover in
 * `.../covers/<item>.jpg`. All of it survives restarts; a download that was cut off goes on where it stopped
 * (the file arrives as `.part` and is asked for again with a `Range`). The books are fetched one after the other, with
 * the app's `mediaHttp` (login and custom headers are added there – the addresses carry no credentials), while
 * [BookDownloadService] keeps the process alive and shows the progress notification.
 *
 * Everything here is called from the main thread (files are written on the IO dispatcher).
 */
object BookDownloads {
    private val _books = MutableStateFlow<List<DownloadedBook>>(emptyList())
    /** Books and podcasts with finished downloads, by title. Only the current account's. */
    val books: StateFlow<List<DownloadedBook>> = _books.asStateFlow()

    private val _states = MutableStateFlow<Map<String, BookDownloadState>>(emptyMap())
    /** By `itemId`, or `itemId/episodeId` for an episode. Absent = [BookDownloadState.None]. */
    val states: StateFlow<Map<String, BookDownloadState>> = _states.asStateFlow()

    private val _batch = MutableStateFlow<Float?>(null)
    /** How far everything started in this run is (0..1), null when nothing is downloading. */
    val batchProgress: StateFlow<Float?> = _batch.asStateFlow()

    /** What the notification of [BookDownloadService] shows: progress, finished and total of this run. */
    internal data class Activity(val progress: Float, val done: Int, val total: Int)

    private val _activity = MutableStateFlow<Activity?>(null)
    internal val activity: StateFlow<Activity?> = _activity.asStateFlow()

    private var app: TonaloApplication? = null
    private var account: String? = null
    private val recs = LinkedHashMap<String, BookRec>()
    /** Queued, running or failed: the others are done (see [recs]). */
    private val status = HashMap<String, BookDownloadState>()
    private val received = HashMap<String, HashMap<Int, Long>>()
    private val queue = ArrayDeque<String>()
    private val batch = LinkedHashSet<String>()
    private var worker: Job? = null
    private var running: Job? = null
    private var runningKey: String? = null
    private var starting = 0

    fun state(itemId: String, episodeId: String? = null): BookDownloadState = _states.value[ABSProgress.key(itemId, episodeId)] ?: BookDownloadState.None

    fun isDownloaded(itemId: String, episodeId: String? = null): Boolean = state(itemId, episodeId) is BookDownloadState.Done

    /** The bytes the finished downloads take. */
    fun storageBytes(): Long = _books.value.sumOf { it.bytes }

    /**
     * The saved cover of a downloaded item (for showing it without a connection), or null.
     * (Not in the original contract: the pages need it to draw covers offline.)
     */
    fun coverFile(itemId: String): File? {
        val account = account ?: return null
        return coverOf(account, itemId).takeIf { it.exists() && it.length() > 0 }
    }

    // region Start and stop

    /** Connects to the app and loads the index of the current account; follows account changes. Safe to call again. */
    internal fun attach(app: TonaloApplication) {
        if (this.app != null) return
        this.app = app
        load(app, app.current.value?.id)
        app.scope.launch {
            app.current.distinctUntilChangedBy { it?.id }.collect { if (it?.id != account) load(app, it?.id) }
        }
    }

    private fun key(item: ABSItem, episode: ABSEpisode?) = ABSProgress.key(item.id, episode?.id)

    fun download(context: Context, item: ABSItem, episode: ABSEpisode? = null) {
        val app = context.tonalo
        attach(app)
        val account = app.current.value?.id ?: return
        val key = key(item, episode)
        when (_states.value[key]) {
            is BookDownloadState.Done, BookDownloadState.Queued, is BookDownloadState.Downloading -> return
            else -> {}
        }
        if (!app.books.canDownload.value) {
            setStatus(key, BookDownloadState.Failed(app.getString(R.string.bp_error_forbidden)))
            return
        }
        AudiobookFiles.reopen(account)
        batch.add(key)
        setStatus(key, BookDownloadState.Queued)
        starting++
        publish()
        BookDownloadService.start(app)
        app.scope.launch {
            try {
                val rec = recs[key] ?: makeRec(app, item, episode)
                if (this@BookDownloads.account != account) return@launch
                recs[key] = rec
                saveIndex()
                queue.add(key)
                pump()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                batch.remove(key)
                setStatus(key, BookDownloadState.Failed(messageFor(app, e)))
            } finally {
                starting--
                publish()
            }
        }
    }

    /** Stops a download that isn't finished and deletes what it had. A finished one stays (see [remove]). */
    fun cancel(context: Context, item: ABSItem, episode: ABSEpisode? = null) {
        attach(context.tonalo)
        val key = key(item, episode)
        if (_states.value[key] is BookDownloadState.Done) return
        removeKey(key)
    }

    /** Deletes the files of a book or episode, finished or not. */
    fun remove(context: Context, item: ABSItem, episode: ABSEpisode? = null) {
        attach(context.tonalo)
        removeKey(key(item, episode))
    }

    fun removeAll(context: Context) {
        attach(context.tonalo)
        for (key in recs.keys.toList() + status.keys.toList()) removeKey(key)
    }

    /** The notification's cancel button. */
    internal fun cancelUnfinished() {
        for (key in recs.values.filter { !it.complete }.map { it.key } + status.keys.toList()) removeKey(key)
    }

    /** Android ended the foreground service (time limit): stops where it is, [download] goes on later. */
    internal fun suspendAll() {
        val app = app ?: return
        running?.cancel()
        worker?.cancel()
        worker = null
        queue.clear()
        for (key in status.keys.toList()) status[key] = BookDownloadState.Failed(app.getString(R.string.bp_error_download))
        batch.clear()
        publish()
    }

    private fun removeKey(key: String) {
        val account = account ?: return
        val rec = recs[key]
        queue.remove(key)
        if (runningKey == key) running?.cancel()
        // A book that plays from these files stops first
        rec?.let { BookPlayer.stopIfPlaying(it.item.id, it.episode?.id, local = true) }
        recs.remove(key)
        status.remove(key)
        received.remove(key)
        batch.remove(key)
        saveIndex()
        publish()
        val item = rec?.item?.id
        val stillUsed = item != null && recs.values.any { it.item.id == item }
        app?.scope?.launch(Dispatchers.IO) {
            runCatching { folderOf(account, key).deleteRecursively() }
            if (item != null && !stillUsed) runCatching { coverOf(account, item).delete() }
        }
    }

    // endregion

    // region Playing

    /** What the player needs when all files of a book are here; null otherwise. */
    internal fun localSession(item: ABSItem, episode: ABSEpisode?, position: Double): ABSSession? {
        val rec = recs[key(item, episode)]?.takeIf { it.complete } ?: return null
        return ABSSession(
            id = "local-" + UUID.randomUUID(), libraryItemId = item.id, episodeId = episode?.id,
            displayTitle = episode?.title ?: rec.item.title, displayAuthor = rec.item.creator,
            duration = rec.duration, currentTime = position, chapters = rec.chapters,
            audioTracks = rec.files.sortedBy { it.index }.map { ABSSession.Track(it.index, it.startOffset, it.duration) },
        )
    }

    internal fun localFile(itemId: String, episodeId: String?, index: Int): File? {
        val account = account ?: return null
        val key = ABSProgress.key(itemId, episodeId)
        val name = recs[key]?.files?.firstOrNull { it.index == index }?.name ?: return null
        return File(folderOf(account, key), name).takeIf { it.exists() }
    }

    /** The saved copy of a downloaded item (with chapters and episodes), or null. */
    internal fun savedItem(itemId: String, episodeId: String?): ABSItem? = recs[ABSProgress.key(itemId, episodeId)]?.item

    // endregion

    // region Index and files

    private fun folderOf(account: String, key: String) =
        File(File(AudiobookFiles.folder(account), "books"), key.replace(Regex("[^A-Za-z0-9_-]"), "_"))

    private fun coverOf(account: String, item: String) =
        File(File(AudiobookFiles.folder(account), "covers"), item.replace(Regex("[^A-Za-z0-9_-]"), "_") + ".jpg")

    private fun load(app: TonaloApplication, id: String?) {
        // Another account: its downloads wait where they are
        running?.cancel()
        worker?.cancel()
        worker = null
        queue.clear()
        recs.clear(); status.clear(); received.clear(); batch.clear()
        account = id
        if (id != null) {
            val data = AudiobookFiles.read(id, "downloads.json")
            val index = data?.let { runCatching { Network.json.decodeFromString(BookIndex.serializer(), it.decodeToString()) }.getOrNull() }
            for (rec in index?.books.orEmpty()) {
                // A file that vanished (storage cleared) is not done any more
                val dir = folderOf(id, rec.key)
                recs[rec.key] = rec.copy(files = rec.files.map { if (it.done && !File(dir, it.name).exists()) it.copy(done = false) else it })
            }
            for (rec in recs.values.filter { !it.complete }) {
                status[rec.key] = BookDownloadState.Queued
                batch.add(rec.key)
                queue.add(rec.key)
            }
        }
        publish()
        if (queue.isNotEmpty()) {
            BookDownloadService.start(app)
            pump()
        }
    }

    private fun saveIndex() {
        val account = account ?: return
        val data = Network.json.encodeToString(BookIndex.serializer(), BookIndex(recs.values.toList())).encodeToByteArray()
        // Written in order, off the main thread
        app?.scope?.launch(Dispatchers.IO) { synchronized(this@BookDownloads) { AudiobookFiles.write(account, "downloads.json", data) } }
    }

    /** Asks the server for the full item (which also renews a login that ran out) and plans the files. */
    private suspend fun makeRec(app: TonaloApplication, item: ABSItem, episode: ABSEpisode?): BookRec {
        val full = app.books.item(item.id)
        val found = episode?.let { e -> full.media.episodes?.firstOrNull { it.id == e.id } }
        if (episode != null && found == null) throw AudiobookError.Unexpected()
        val sources: List<ABSFile> = if (episode != null) listOfNotNull(found?.audioFile) else full.media.tracks.orEmpty()
        var offset = 0.0
        val files = ArrayList<BookFileRec>()
        for ((i, f) in sources.withIndex()) {
            val ino = f.ino ?: continue
            val ext = (f.metadata?.ext ?: ".mp3").trim().trim('.').ifEmpty { "mp3" }
            val start = f.startOffset ?: offset
            files += BookFileRec(i, start, f.duration ?: 0.0, ino, "$i.$ext", (f.metadata?.size ?: 0.0).toLong())
            offset = start + (f.duration ?: 0.0)
        }
        if (files.isEmpty()) throw AudiobookError.Unexpected()
        return BookRec(
            key = key(item, episode), item = full, episode = found,
            duration = found?.length?.takeIf { it > 0 } ?: full.media.duration ?: offset,
            chapters = if (episode != null) emptyList() else full.media.chapters.orEmpty(),
            files = files, dateMs = System.currentTimeMillis(),
        )
    }

    // endregion

    // region The worker

    private fun pump() {
        if (worker?.isActive == true || queue.isEmpty()) return
        val app = app ?: return
        worker = app.scope.launch {
            while (true) {
                val key = queue.removeFirstOrNull() ?: break
                val rec = recs[key] ?: continue
                val job = launch { runBook(app, rec.key) }
                running = job
                runningKey = key
                job.join()
                running = null
                runningKey = null
            }
            publish()
        }
    }

    private suspend fun runBook(app: TonaloApplication, key: String) {
        val account = account ?: return
        setStatus(key, BookDownloadState.Downloading(fraction(recs[key] ?: return)))
        try {
            val item = recs[key]?.item?.id ?: return
            withContext(Dispatchers.IO) { saveCover(app, account, item) }
            for (file in recs[key]?.files.orEmpty().sortedBy { it.index }) {
                if (recs[key]?.files?.firstOrNull { it.index == file.index }?.done != false) continue
                val size = downloadFile(app, account, key, item, file)
                val rec = recs[key] ?: return
                recs[key] = rec.copy(files = rec.files.map { if (it.index == file.index) it.copy(done = true, size = size) else it })
                received[key]?.remove(file.index)
                saveIndex()
                publish()
            }
            val rec = recs[key] ?: return
            recs[key] = rec.copy(dateMs = System.currentTimeMillis())
            status.remove(key)
            saveIndex()
            publish()
        } catch (e: CancellationException) {
            // Removed, or the account changed: whoever did that has cleaned up
            throw e
        } catch (e: Exception) {
            if (e is AudiobookError.Http && e.status == 403) {
                removeKey(key)
                setStatus(key, BookDownloadState.Failed(app.getString(R.string.bp_error_forbidden)))
                return
            }
            setStatus(key, BookDownloadState.Failed(messageFor(app, e)))
        }
    }

    private fun messageFor(app: TonaloApplication, e: Throwable): String =
        if (e is AudiobookError.Http && e.status == 403) app.getString(R.string.bp_error_forbidden) else app.getString(R.string.bp_error_download)

    /** One file, with up to three tries on a lost connection; each one asks for the rest of the `.part` file. */
    private suspend fun downloadFile(app: TonaloApplication, account: String, key: String, item: String, file: BookFileRec): Long {
        var attempt = 0
        while (true) {
            try {
                return withContext(Dispatchers.IO) { fetch(app, account, key, item, file) }
            } catch (e: IOException) {
                currentCoroutineContext().ensureActive()
                if (++attempt >= 3) throw e
                delay(2_000L * attempt)
            }
        }
    }

    private suspend fun fetch(app: TonaloApplication, account: String, key: String, item: String, file: BookFileRec): Long {
        // The account is gone (removed while the download ran): nothing may bring its folder back
        if (app.accountList.value.none { it.id == account }) throw CancellationException("account removed")
        val server = app.books.server ?: throw AudiobookError.NotConnected()
        val dir = folderOf(account, key).apply { mkdirs() }
        val dest = File(dir, file.name)
        val part = File(dir, file.name + ".part")
        val have = if (part.exists()) part.length() else 0L
        val builder = Request.Builder().url("${server.url}/api/items/$item/file/${file.ino}/download")
        if (have > 0) builder.header("Range", "bytes=$have-")
        val call = app.mediaHttp.newCall(builder.build())
        val watch = currentCoroutineContext()[Job]?.invokeOnCompletion { if (it != null) call.cancel() }
        try {
            return call.execute().use { r ->
                val append: Boolean
                when {
                    r.code == 206 -> append = true
                    r.code == 200 -> append = false
                    r.code == 416 -> {
                        // Nothing more to ask for: finished, if it has the size it should; otherwise from the start
                        if (have > 0 && (file.size <= 0 || have == file.size)) {
                            dest.delete()
                            if (!part.renameTo(dest)) throw IOException("rename")
                            return@use dest.length()
                        }
                        part.delete()
                        throw IOException("range")
                    }
                    else -> throw AudiobookError.Http(r.code)
                }
                val type = r.header("Content-Type").orEmpty()
                // A page of a proxy (e.g. a Cloudflare login) instead of audio
                if (type.contains("json") || type.contains("html")) throw AudiobookError.Unexpected()
                val body = r.body ?: throw IOException("empty")
                var written = if (append) have else 0L
                var lastTick = 0L
                RandomAccessFile(part, "rw").use { out ->
                    if (append) out.seek(have) else out.setLength(0)
                    val buffer = ByteArray(64 * 1024)
                    body.byteStream().use { input ->
                        while (true) {
                            val n = input.read(buffer)
                            if (n < 0) break
                            currentCoroutineContext().ensureActive()
                            out.write(buffer, 0, n)
                            written += n
                            val now = System.nanoTime()
                            if (now - lastTick > 400_000_000L) {
                                lastTick = now
                                val w = written
                                app.scope.launch { received.getOrPut(key) { HashMap() }[file.index] = w; publish() }
                            }
                        }
                    }
                }
                dest.delete()
                if (!part.renameTo(dest)) throw IOException("rename")
                dest.length()
            }
        } catch (e: IOException) {
            currentCoroutineContext().ensureActive()
            throw e
        } finally {
            watch?.dispose()
        }
    }

    private fun saveCover(app: TonaloApplication, account: String, item: String) {
        val target = coverOf(account, item)
        if (target.exists() && target.length() > 0) return
        val url = app.books.coverURL(item, 800) ?: return
        runCatching {
            app.mediaHttp.newCall(Request.Builder().url(url).build()).execute().use { r ->
                val bytes = if (r.isSuccessful && r.header("Content-Type")?.startsWith("image") == true) r.body?.bytes() else null
                if (bytes != null && bytes.isNotEmpty()) {
                    target.parentFile?.mkdirs()
                    val tmp = File(target.parentFile, target.name + ".part")
                    tmp.writeBytes(bytes)
                    if (!tmp.renameTo(target)) tmp.delete()
                }
            }
        }
    }

    // endregion

    // region State

    private fun setStatus(key: String, state: BookDownloadState) {
        status[key] = state
        publish()
    }

    private fun fraction(rec: BookRec): Float {
        val total = rec.files.sumOf { it.size }
        if (total <= 0) return rec.files.count { it.done }.toFloat() / maxOf(1, rec.files.size)
        val loaded = rec.files.sumOf { if (it.done) it.size else received[rec.key]?.get(it.index) ?: 0L }
        return (loaded.toFloat() / total).coerceIn(0f, 1f)
    }

    private fun isLoading(key: String): Boolean {
        val s = status[key]
        return s is BookDownloadState.Queued || s is BookDownloadState.Downloading
    }

    private fun publish() {
        val states = HashMap<String, BookDownloadState>()
        for (rec in recs.values) {
            val s = status[rec.key]
            states[rec.key] = when {
                rec.complete -> BookDownloadState.Done(rec.bytes)
                s is BookDownloadState.Downloading -> BookDownloadState.Downloading(fraction(rec))
                s != null -> s
                else -> BookDownloadState.Queued
            }
        }
        // Failed or queued before the item is known (the server is asked for it first)
        for ((key, s) in status) if (key !in states) states[key] = s
        _states.value = states

        _books.value = recs.values.filter { it.complete }.groupBy { it.item.id }.values.map { group ->
            DownloadedBook(
                item = group.first().item,
                episodeIds = group.mapNotNull { it.episode?.id },
                bytes = group.sumOf { it.bytes },
                dateMs = group.maxOf { it.dateMs },
            )
        }.sortedBy { it.item.title.lowercase() }

        if (batch.none { isLoading(it) } && starting == 0) batch.clear()
        if (batch.isEmpty()) {
            _batch.value = null
            _activity.value = null
        } else {
            val sum = batch.sumOf { key -> (if (isLoading(key)) recs[key]?.let { fraction(it) } ?: 0f else 1f).toDouble() }
            val progress = (sum / batch.size).toFloat().coerceIn(0f, 1f)
            _batch.value = progress
            _activity.value = Activity(progress, batch.count { !isLoading(it) }, batch.size)
        }
    }

    // endregion
}
