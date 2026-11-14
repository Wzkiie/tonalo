package app.tonalo.android.playback

import android.content.ComponentName
import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.annotation.OptIn
import androidx.core.content.ContextCompat
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.ConcatenatingMediaSource2
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import app.tonalo.android.R
import app.tonalo.android.TonaloApplication
import app.tonalo.android.data.ABSChapter
import app.tonalo.android.data.ABSEpisode
import app.tonalo.android.data.ABSItem
import app.tonalo.android.data.ABSProgress
import app.tonalo.android.data.ABSSession
import app.tonalo.android.downloads.BookDownloads
import app.tonalo.android.link.JukeboxHost
import app.tonalo.android.tonalo
import com.google.common.util.concurrent.ListenableFuture
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.Request
import java.io.ByteArrayOutputStream

/**
 * What the screens show of the audiobook or podcast episode that plays.
 * Times are seconds on the timeline of the whole book (all files together) or the episode.
 * @property loading a session is opened or the audio is buffering
 * @property sleepEndsAt when the sleep timer pauses (milliseconds since 1970), null when it isn't running
 * @property error why it can't be played (shown until the next try); can be set while [item] is null (the book could not be started)
 */
data class BookState(
    val item: ABSItem? = null,
    val episode: ABSEpisode? = null,
    val playing: Boolean = false,
    val loading: Boolean = false,
    val positionSec: Double = 0.0,
    val durationSec: Double = 0.0,
    val chapters: List<ABSChapter> = emptyList(),
    val chapterIndex: Int = -1,
    val rate: Float = 1f,
    val skipBack: Int = 15,
    val skipForward: Int = 30,
    val sleepEndsAt: Long? = null,
    val sleepAtChapterEnd: Boolean = false,
    val error: String? = null,
    /** Controlling a TV is not part of the Android port: always null. */
    val tvName: String? = null,
) {
    val active get() = item != null
}

/** What [BookPlayer] needs from the playback service; the service implements it (see `PlaybackService.bookHost`). */
@OptIn(UnstableApi::class)
internal interface BookHost {
    val player: ExoPlayer

    /** Makes sources from addresses, `file://` included. */
    val sourceFactory: MediaSource.Factory

    /** The music is put aside (its queue saved, paused) and the player belongs to the book. Idempotent. */
    fun start()

    /** The player belongs to the music again; with [restoreMusic] the saved music queue is loaded back (paused). */
    fun finish(restoreMusic: Boolean)

    /** The buttons of the notification and the car (skip intervals) changed. */
    fun refreshLayout()
}

/**
 * Plays one audiobook or podcast episode from Audiobookshelf (port of ios/Tonalo/BookPlayer.swift).
 *
 * **One player, two owners.** The book uses the same ExoPlayer and MediaSession as the music (in [PlaybackService]), so
 * the notification, the lock screen, the headphone buttons and Android Auto's now-playing show the book for free. When a
 * book starts, the service saves the music queue with the position (`QueueStore`), pauses it and marks the player as the
 * book's; when the book stops or ends, the saved queue is loaded back, paused, so the user can continue it. Starting music
 * (from a screen, the car, a voice request, a radio…) while a book plays makes the service notice a non-book item
 * and the book is closed (final progress sync). A book never touches Navidrome: no scrobbles, no saved play queue.
 * The book is ONE window: a `ConcatenatingMediaSource2` of its files, so positions, seeking and the scrubber work
 * on the timeline of the whole book and file changes are gapless.
 *
 * Progress goes to Audiobookshelf through the listening session (`syncSession` about every 30 s and on pause, stop and
 * close); a downloaded book plays from its files and reports with `saveProgress` (kept and sent when there is a
 * connection) – while online it also opens a session for the server's listening statistics.
 *
 * All functions are called from the main thread.
 */
@OptIn(UnstableApi::class)
object BookPlayer {
    val rates: List<Float> = listOf(0.75f, 1f, 1.25f, 1.5f, 1.75f, 2f, 2.5f)
    val skipChoices = listOf(10, 15, 30, 45, 60)

    private val _state = MutableStateFlow(BookState())
    val state: StateFlow<BookState> = _state.asStateFlow()

    private var app: TonaloApplication? = null
    private var prefs: SharedPreferences? = null
    private var host: BookHost? = null

    /** The player is the book's (set between `host.start()` and `host.finish()`). */
    @Volatile internal var owns = false
        private set

    /** Volume of the sleep timer's fade-out; the service applies it (music has its own factors). */
    @Volatile internal var volumeFactor = 1f
        private set

    private var session: ABSSession? = null
    /** A downloaded book can also have a server session, for the statistics. */
    private var serverSession: String? = null
    private var generation = 0
    private var starting: Job? = null
    private var ticker: Job? = null
    private var sleepJob: Job? = null
    private var lastPos = 0.0
    private var listened = 0.0
    private var sinceRetry = 0.0
    private var lastTickMs = 0L
    private var lastSyncMs = 0L
    private var lastNoteMs = 0L
    private var retried = false
    private var artwork: ByteArray? = null
    private var artworkFor: String? = null
    private var metaChapter = -2

    /** Waits for the service when it isn't running yet; a controller of our own starts it. */
    private var anchor: ListenableFuture<MediaController>? = null
    private val pending = ArrayList<() -> Unit>()

    // region Setup

    /** Reads the saved speed and skip intervals and connects to the library. Safe to call again. */
    internal fun init(app: TonaloApplication) {
        if (this.app != null) return
        this.app = app
        val p = app.getSharedPreferences("bookplayer", Context.MODE_PRIVATE)
        prefs = p
        val rate = p.getFloat("book.rate", 1f).takeIf { it in rates } ?: 1f
        val back = p.getInt("book.skipBack", 15).takeIf { it in skipChoices } ?: 15
        val forward = p.getInt("book.skipForward", 30).takeIf { it in skipChoices } ?: 30
        _state.update { it.copy(rate = rate, skipBack = back, skipForward = forward) }
        app.books.onPlayerClose = { stop() }
        app.books.onAddressChanged = { addressChanged() }
        BookDownloads.attach(app)
    }

    /** The service is up. */
    internal fun attach(host: BookHost) {
        this.host = host
        // After onCreate has finished (the session exists then)
        Handler(Looper.getMainLooper()).post { drain() }
    }

    /** The service goes away (before its player is released): the book is closed with a last report. */
    internal fun detach() {
        if (owns) syncPosition()
        owns = false
        endSession()
        host = null
        releaseAnchor()
    }

    private fun drain() {
        val list = pending.toList()
        pending.clear()
        list.forEach { it() }
    }

    private fun withHost(app: TonaloApplication, block: (BookHost) -> Unit) {
        host?.let { block(it); return }
        pending += { host?.let(block) }
        if (anchor != null) return
        val future = MediaController.Builder(app, SessionToken(app, ComponentName(app, PlaybackService::class.java))).buildAsync()
        anchor = future
        future.addListener({
            if (runCatching { future.get() }.isFailure) {
                if (anchor === future) anchor = null
                pending.clear()
                if (_state.value.loading) fail(app)
            } else drain()
        }, ContextCompat.getMainExecutor(app))
    }

    private fun releaseAnchor() {
        anchor?.let { MediaController.releaseFuture(it) }
        anchor = null
        pending.clear()
    }

    // endregion

    // region Start and stop

    /**
     * Plays the downloaded files if the book (or episode) is downloaded, otherwise streams a listening session; continues
     * at the saved position. Music stops (its queue is kept). The same book again just resumes.
     */
    fun play(context: Context, item: ABSItem, episode: ABSEpisode? = null) {
        val app = context.tonalo
        init(app)
        val ep = episode ?: item.recentEpisode ?: if (item.isPodcast) item.media.episodes?.firstOrNull() else null
        val st = _state.value
        if (st.item?.id == item.id && st.episode?.id == ep?.id && (session != null || st.loading)) {
            if (session != null && !st.playing) toggle()
            return
        }
        if (JukeboxHost.running.value) {
            _state.value = idle().copy(error = app.getString(R.string.bp_jukebox))
            return
        }
        // Another book was playing: it stops (and reports) before this one is asked for
        if (owns) host?.player?.pause()
        if (owns) syncPosition()
        endSession()
        retried = false
        val gen = ++generation
        _state.value = idle().copy(
            item = item, episode = ep, loading = true,
            durationSec = ep?.length?.takeIf { it > 0 } ?: item.media.duration ?: 0.0,
            chapters = item.media.chapters.orEmpty(),
        )
        starting = app.scope.launch { open(app, item, ep, null, gen, autoplay = true) }
    }

    private suspend fun open(app: TonaloApplication, item: ABSItem, ep: ABSEpisode?, at: Double?, gen: Int, autoplay: Boolean) {
        val books = app.books
        val saved = books.progressOf(item, ep)?.currentTime ?: 0.0
        val local = BookDownloads.localSession(item, ep, saved)
        val s: ABSSession = local ?: try {
            books.startSession(item.id, ep?.id)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (gen == generation) fail(app)
            return
        }
        if (gen != generation) {
            if (local == null) closeOrphan(app, s)
            return
        }
        withHost(app) { host ->
            if (gen != generation) {
                if (local == null) closeOrphan(app, s)
                return@withHost
            }
            begin(app, host, item, ep, s, at, autoplay)
            if (local != null && app.online.value) attachServerSession(app, item, ep, local.id, gen)
        }
    }

    /** A session nobody plays any more (another book was picked meanwhile). */
    private fun closeOrphan(app: TonaloApplication, s: ABSSession) {
        app.scope.launch {
            try { app.books.syncSession(s.id, s.currentTime, 0.0, s.duration, close = true) }
            catch (e: CancellationException) { throw e } catch (e: Exception) { }
        }
    }

    private fun attachServerSession(app: TonaloApplication, item: ABSItem, ep: ABSEpisode?, localId: String, gen: Int) {
        app.scope.launch {
            val new = try { app.books.startSession(item.id, ep?.id) } catch (e: CancellationException) { throw e } catch (e: Exception) { return@launch }
            if (session?.id == localId && gen == generation) serverSession = new.id else closeOrphan(app, new)
        }
    }

    private fun begin(app: TonaloApplication, host: BookHost, item: ABSItem, ep: ABSEpisode?, s: ABSSession, at: Double?, autoplay: Boolean) {
        val st = _state.value
        val duration = s.duration.takeIf { it > 0 } ?: ep?.length?.takeIf { it > 0 } ?: item.media.duration ?: st.durationSec
        var start = (at ?: s.currentTime).coerceAtLeast(0.0)
        // Finished earlier: starting it again means from the beginning
        if (duration > 0 && start >= duration - 5) start = 0.0
        val chapters = s.chapters?.takeIf { it.isNotEmpty() } ?: item.media.chapters.orEmpty()
        session = s
        lastPos = start
        lastSyncMs = SystemClock.elapsedRealtime()
        lastNoteMs = lastSyncMs
        metaChapter = chapterIndexAt(start, chapters)
        _state.value = st.copy(
            loading = true, error = null, positionSec = start, durationSec = duration,
            chapters = chapters, chapterIndex = metaChapter,
        )
        host.start()
        owns = true
        loadArtwork(app, item)
        if (!load(host, s, start, autoplay)) {
            fail(app)
            return
        }
        app.books.noteListening(item, ep, start, duration) // shows up in "continue listening" at once
        host.refreshLayout()
        publish()
    }

    /** Puts the files of the session into the player, from [startSec] on the whole book's timeline. */
    private fun load(host: BookHost, s: ABSSession, startSec: Double, autoplay: Boolean): Boolean {
        val app = app ?: return false
        val st = _state.value
        val item = st.item ?: return false
        val tracks = s.audioTracks.sortedBy { it.startOffset }
        if (tracks.isEmpty()) return false
        val builder = ConcatenatingMediaSource2.Builder()
            .setMediaSourceFactory(host.sourceFactory)
            .setMediaItem(metaItem(item, st.episode, s, st.duration()))
        for (t in tracks) {
            val uri: Uri = (if (s.isLocal) BookDownloads.localFile(item.id, st.episode?.id, t.index)?.let { Uri.fromFile(it) }
            else app.books.trackURL(s, t)?.let { Uri.parse(it) }) ?: return false
            // The length the server gave stands in until the file itself says how long it is
            val seconds = (t.duration.takeIf { it > 0 } ?: (s.duration / tracks.size)).coerceAtLeast(1.0)
            builder.add(MediaItem.fromUri(uri), (seconds * 1000).toLong())
        }
        val p = host.player
        p.playbackParameters = PlaybackParameters(st.rate, 1f)
        p.setMediaSource(builder.build(), (startSec * 1000).toLong())
        p.prepare()
        p.playWhenReady = autoplay
        return true
    }

    private fun BookState.duration(): Double = durationSec

    /** Stops and reports the final position; the saved music queue comes back (paused). */
    fun stop() {
        if (!_state.value.active && !owns) {
            if (_state.value.error != null) _state.update { it.copy(error = null) }
            return
        }
        if (owns) {
            syncPosition()
            host?.player?.pause()
        }
        endSession()
        release(restore = true)
    }

    /** The service saw something that is not the book in the player: music was started. */
    internal fun onMediaItem() {
        if (!owns) return
        val current = host?.player?.currentMediaItem ?: return
        if (current.isBook) return
        endSession()
        release(restore = false)
    }

    /** A book of these files is going away (download removed). */
    internal fun stopIfPlaying(itemId: String, episodeId: String?, local: Boolean) {
        val st = _state.value
        if (st.item?.id == itemId && st.episode?.id == episodeId && session?.isLocal == local) stop()
    }

    /** Reports the end of the session and forgets it; the player is not touched. */
    private fun endSession() {
        starting?.cancel()
        starting = null
        generation++
        if (session != null) report(close = true)
        ticker?.cancel()
        ticker = null
        sleepJob?.cancel()
        sleepJob = null
        volumeFactor = 1f
        session = null
        serverSession = null
        listened = 0.0
        sinceRetry = 0.0
        retried = false
        artwork = null
        artworkFor = null
        metaChapter = -2
        _state.value = idle()
    }

    private fun release(restore: Boolean) {
        if (owns) {
            owns = false
            host?.finish(restore)
        }
        releaseAnchor()
    }

    /** The book could not be started: no item, an [BookState.error]; the music comes back. */
    private fun fail(app: TonaloApplication) {
        val message = app.getString(R.string.bp_error_play)
        if (owns) host?.player?.pause()
        endSession()
        release(restore = true)
        _state.value = idle().copy(error = message)
    }

    private fun idle(): BookState = _state.value.let { BookState(rate = it.rate, skipBack = it.skipBack, skipForward = it.skipForward) }

    // endregion

    // region Controls

    fun toggle() {
        val st = _state.value
        val h = host
        val s = session
        if (!owns || h == null || s == null || !st.active) return
        val p = h.player
        if (st.error != null || p.playbackState == Player.STATE_IDLE) {
            // Failed before, or the player let go: the files are loaded again
            retried = false
            syncPosition()
            _state.update { it.copy(error = null, loading = true) }
            if (!load(h, s, lastPos, true)) app?.let { fail(it) }
            return
        }
        if (p.playWhenReady) p.pause() else p.play()
    }

    fun pause() {
        if (owns) host?.player?.pause()
    }

    /** Moves to a time on the timeline of the whole book. */
    fun seekTo(seconds: Double) {
        val h = host ?: return
        if (!owns || session == null) return
        val duration = _state.value.durationSec
        val t = seconds.coerceIn(0.0, maxOf(0.0, duration - 1))
        h.player.seekTo((t * 1000).toLong())
        lastPos = t
        _state.update { it.copy(positionSec = t, chapterIndex = chapterIndexAt(t, it.chapters)) }
        metaIfChapterChanged()
    }

    /** Positive forward, negative back. */
    fun skip(seconds: Int) {
        if (!owns) return
        syncPosition()
        seekTo(lastPos + seconds)
    }

    fun nextChapter() {
        if (!owns) return
        syncPosition()
        val next = _state.value.chapters.firstOrNull { it.start > lastPos + 0.5 } ?: return
        seekTo(next.start)
    }

    /** Back to the start of this chapter; right after its start, to the one before. */
    fun previousChapter() {
        if (!owns) return
        syncPosition()
        val chapters = _state.value.chapters
        val i = chapterIndexAt(lastPos, chapters)
        if (i < 0) return seekTo(0.0)
        seekTo(if (lastPos - chapters[i].start > 5 || i == 0) chapters[i].start else chapters[i - 1].start)
    }

    fun setRate(rate: Float) {
        prefs?.edit()?.putFloat("book.rate", rate)?.apply()
        _state.update { it.copy(rate = rate) }
        if (owns) host?.player?.playbackParameters = PlaybackParameters(rate, 1f)
    }

    fun setSkipBack(s: Int) {
        if (s !in skipChoices) return
        prefs?.edit()?.putInt("book.skipBack", s)?.apply()
        _state.update { it.copy(skipBack = s) }
        if (owns) host?.refreshLayout()
    }

    fun setSkipForward(s: Int) {
        if (s !in skipChoices) return
        prefs?.edit()?.putInt("book.skipForward", s)?.apply()
        _state.update { it.copy(skipForward = s) }
        if (owns) host?.refreshLayout()
    }

    /** Pauses after this many minutes (the last 10 seconds fade out); null switches the timer off. */
    fun setSleepMinutes(minutes: Int?) {
        val app = app ?: return
        if (!_state.value.active) return
        sleepJob?.cancel()
        sleepJob = null
        volumeFactor = 1f
        applyVolume()
        if (minutes == null || minutes <= 0) {
            _state.update { it.copy(sleepEndsAt = null, sleepAtChapterEnd = false) }
            return
        }
        val ends = System.currentTimeMillis() + minutes * 60_000L
        _state.update { it.copy(sleepEndsAt = ends, sleepAtChapterEnd = false) }
        sleepJob = app.scope.launch {
            delay((ends - System.currentTimeMillis() - 10_000L).coerceAtLeast(0))
            for (i in 10 downTo 1) {
                volumeFactor = i / 10f
                applyVolume()
                delay(1000)
            }
            sleepFired()
        }
    }

    /** Pauses at the end of the chapter that plays. */
    fun setSleepAtChapterEnd(on: Boolean) {
        if (!_state.value.active) return
        sleepJob?.cancel()
        sleepJob = null
        volumeFactor = 1f
        applyVolume()
        _state.update { it.copy(sleepAtChapterEnd = on, sleepEndsAt = null) }
    }

    private fun sleepFired() {
        sleepJob = null
        volumeFactor = 1f
        _state.update { it.copy(sleepEndsAt = null, sleepAtChapterEnd = false) }
        if (owns) {
            syncPosition()
            host?.player?.pause()
        }
        applyVolume()
    }

    private fun applyVolume() {
        if (owns) host?.player?.volume = volumeFactor
    }

    // endregion

    // region Events from the service (main thread)

    internal fun onEvents(player: Player, events: Player.Events) {
        if (!owns) return
        if (events.contains(Player.EVENT_IS_PLAYING_CHANGED)) {
            if (player.isPlaying) {
                lastTickMs = SystemClock.elapsedRealtime()
                startTicker()
            } else {
                ticker?.cancel()
                ticker = null
            }
        }
        // A real pause (not just buffering): the position goes to the server
        if (events.contains(Player.EVENT_PLAY_WHEN_READY_CHANGED) && !player.playWhenReady && session != null) {
            syncPosition()
            report(close = false)
        }
        publish()
        if (events.contains(Player.EVENT_PLAYBACK_STATE_CHANGED) && player.playbackState == Player.STATE_ENDED) onEnded()
    }

    /** The server forgets a session after a while (long pause, restart): once, a new one is asked for and playback continues. */
    internal fun onPlayerError(error: PlaybackException) {
        val app = app ?: return
        val s = session ?: return
        val item = _state.value.item ?: return
        if (!owns) return
        syncPosition()
        if (!s.isLocal && !retried) {
            retried = true
            sinceRetry = 0.0
            val at = lastPos
            val episode = _state.value.episode
            report(close = false)
            session = null
            val gen = ++generation
            _state.update { it.copy(loading = true, error = null) }
            starting = app.scope.launch { open(app, item, episode, at, gen, autoplay = true) }
            return
        }
        host?.player?.pause()
        report(close = false)
        _state.update { it.copy(playing = false, loading = false, error = error.localizedMessage ?: app.getString(R.string.bp_error_play)) }
    }

    private fun onEnded() {
        val app = app ?: return
        val s = session ?: return
        val st = _state.value
        val item = st.item ?: return
        lastPos = s.duration
        app.scope.launch {
            try { app.books.setFinished(item, st.episode, true) } catch (e: CancellationException) { throw e } catch (e: Exception) { }
        }
        endSession()
        release(restore = true)
    }

    /** The address in use changed (left home, other address saved): a streaming book goes on from the new one. */
    private fun addressChanged() {
        val s = session?.takeIf { !it.isLocal } ?: return
        val h = host ?: return
        if (!owns) return
        syncPosition()
        load(h, s, lastPos, h.player.playWhenReady)
    }

    // endregion

    // region Clock and reports

    private fun startTicker() {
        val app = app ?: return
        ticker?.cancel()
        ticker = app.scope.launch {
            while (isActive) {
                delay(250)
                tick()
            }
        }
    }

    private fun tick() {
        val h = host ?: return
        if (!owns || session == null) return
        val p = h.player
        val now = SystemClock.elapsedRealtime()
        if (p.isPlaying) {
            val dt = ((now - lastTickMs) / 1000.0).coerceIn(0.0, 2.0)
            listened += dt
            sinceRetry += dt
        }
        lastTickMs = now
        publish()
        val st = _state.value
        if (st.sleepAtChapterEnd && p.isPlaying) {
            val chapter = st.chapters.lastOrNull { it.start <= lastPos }
            if (chapter != null && lastPos >= chapter.end - 0.6) sleepFired()
        }
        if (p.isPlaying) {
            val item = st.item
            if (item != null && now - lastNoteMs >= 5_000) {
                lastNoteMs = now
                app?.books?.noteListening(item, st.episode, lastPos, st.durationSec)
            }
            if (now - lastSyncMs >= 30_000) report(close = false)
        }
        if (retried && sinceRetry > 20) retried = false
    }

    /** What the player shows now goes into [state]. */
    private fun publish() {
        val s = session ?: return
        val h = host ?: return
        if (!owns) return
        val p = h.player
        val st = _state.value
        val duration = s.duration.takeIf { it > 0 } ?: st.durationSec.takeIf { it > 0 }
            ?: (p.duration.takeIf { it != C.TIME_UNSET && it > 0 }?.div(1000.0) ?: 0.0)
        val position = (p.currentPosition.coerceAtLeast(0L) / 1000.0).let { if (duration > 0) minOf(it, duration) else it }
        lastPos = position
        val index = chapterIndexAt(position, st.chapters)
        val playbackState = p.playbackState
        _state.value = st.copy(
            playing = p.playWhenReady && playbackState != Player.STATE_IDLE && playbackState != Player.STATE_ENDED && st.error == null,
            loading = playbackState == Player.STATE_BUFFERING || (playbackState == Player.STATE_IDLE && st.error == null),
            positionSec = position,
            durationSec = duration,
            chapterIndex = index,
            error = if (p.isPlaying) null else st.error,
        )
        metaIfChapterChanged()
    }

    private fun syncPosition() {
        val p = host?.player ?: return
        if (!owns || p.currentMediaItem?.isBook != true) return
        val duration = _state.value.durationSec
        val t = p.currentPosition.coerceAtLeast(0L) / 1000.0
        lastPos = if (duration > 0) minOf(t, duration) else t
    }

    private fun chapterIndexAt(position: Double, chapters: List<ABSChapter>): Int = chapters.indexOfLast { it.start <= position + 0.5 }

    /**
     * Sends the position; what couldn't be sent is added to the next report. Downloaded books without a server session
     * (or when the server can't be reached) are kept with `saveProgress` and sent once there is a connection.
     */
    private fun report(close: Boolean) {
        val app = app ?: return
        val s = session ?: return
        val st = _state.value
        val item = st.item ?: return
        val amount = listened
        val at = lastPos
        listened = 0.0
        lastSyncMs = SystemClock.elapsedRealtime()
        val books = app.books
        books.noteListening(item, st.episode, at, s.duration)
        if (s.isLocal && serverSession == null) {
            books.saveProgress(item.id, st.episode?.id, at, s.duration)
            return
        }
        val id = serverSession ?: s.id
        app.scope.launch {
            try {
                books.syncSession(id, at, amount, s.duration, close)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                books.saveProgress(item.id, st.episode?.id, at, s.duration)
                if (!close) listened += amount
            }
            // "Continue listening" and the progress bars show the new position
            if (close) {
                try { books.load(force = true) } catch (e: CancellationException) { throw e } catch (e: Exception) { }
            }
        }
    }

    // endregion

    // region Notification, lock screen and car

    private fun chapterTitle(st: BookState): String? =
        st.chapters.takeIf { it.size > 1 }?.getOrNull(st.chapterIndex)?.title?.takeIf { it.isNotBlank() }

    /** Title (the chapter, if the book has some), author and cover as the notification, the lock screen and the car show them. */
    private fun metaItem(item: ABSItem, ep: ABSEpisode?, s: ABSSession, duration: Double): MediaItem {
        val st = _state.value
        val title = ep?.title ?: s.displayTitle ?: item.title
        val creator = if (ep != null) item.title else s.displayAuthor?.takeIf { it.isNotBlank() } ?: item.creator
        val chapter = chapterTitle(st)
        return bookMediaItem(
            mediaId = "book|" + ABSProgress.key(item.id, ep?.id),
            title = chapter ?: title,
            artist = if (chapter != null) listOf(title, creator).filter { it.isNotBlank() }.joinToString(" – ") else creator,
            album = title,
            durationSec = duration,
            artwork = artwork,
        )
    }

    private fun metaIfChapterChanged() {
        val index = _state.value.chapterIndex
        if (index == metaChapter) return
        metaChapter = index
        updateMeta()
    }

    /** Replaces the item's metadata without interrupting playback (the source accepts a new MediaItem). */
    private fun updateMeta() {
        val h = host ?: return
        val s = session ?: return
        val st = _state.value
        val item = st.item ?: return
        if (!owns) return
        val p = h.player
        if (p.mediaItemCount != 1 || p.currentMediaItem?.isBook != true) return
        runCatching { p.replaceMediaItem(0, metaItem(item, st.episode, s, st.durationSec)) }
    }

    /** The cover, small enough to travel inside the item: from the downloaded copy, otherwise from the server. */
    private fun loadArtwork(app: TonaloApplication, item: ABSItem) {
        if (artworkFor == item.id) return
        artworkFor = item.id
        artwork = null
        val gen = generation
        app.scope.launch {
            val bytes = withContext(Dispatchers.IO) {
                runCatching {
                    val raw = BookDownloads.coverFile(item.id)?.readBytes() ?: app.books.coverURL(item.id, 600)?.let { url ->
                        app.mediaHttp.newCall(Request.Builder().url(url).build()).execute().use { r ->
                            if (r.isSuccessful && r.header("Content-Type")?.startsWith("image") == true) r.body?.bytes() else null
                        }
                    }
                    raw?.let { shrink(it) }
                }.getOrNull()
            }
            if (gen != generation || bytes == null) return@launch
            artwork = bytes
            updateMeta()
        }
    }

    /** At most 600 px, as a JPEG: a few dozen KB, because the item is handed to every controller. */
    private fun shrink(bytes: ByteArray, max: Int = 600): ByteArray? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= max && bounds.outHeight / (sample * 2) >= max) sample *= 2
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
        return ByteArrayOutputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
            bitmap.recycle()
            out.toByteArray()
        }
    }

    // endregion
}
