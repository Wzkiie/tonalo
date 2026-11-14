package app.tonalo.android.playback

import android.content.ComponentName
import android.content.Context
import androidx.core.content.ContextCompat
import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import app.tonalo.android.data.Song
import app.tonalo.android.data.Station
import app.tonalo.android.link.Remote
import app.tonalo.android.link.TvLink
import app.tonalo.android.tonalo
import com.google.common.util.concurrent.ListenableFuture
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.StateFlow

/** What the screens show of the player. The position is asked separately ([PlayerConnection.position]), it changes all the time. */
data class PlayerState(
    val queue: List<Song> = emptyList(),
    val index: Int = -1,
    /** Indexes of the songs still to come, in the order they will play (shuffle included). */
    val upNext: List<Int> = emptyList(),
    val isPlaying: Boolean = false,
    val buffering: Boolean = false,
    val shuffle: Boolean = false,
    val repeatMode: Int = Player.REPEAT_MODE_OFF,
    val durationMs: Long = 0,
    val error: String? = null,
    /** A radio station playing live (then `queue` is empty). */
    val station: Station? = null,
    /** What the station says it's playing right now ("Artist - Title"). */
    val liveTitle: String? = null,
    /** Where the songs come from, e.g. the album's name. */
    val context: String? = null,
    /** …and by id ("a<album>", "p<playlist>", "r<artist>"), to show a pause button on that page. */
    val contextId: String? = null,
    /** Playing on this TV or computer (or this Jukebox) – the player here is its remote control. */
    val tvName: String? = null,
    /** Only a guest there: may add songs and skip, nothing more. */
    val tvGuest: Boolean = false,
) {
    val current: Song? get() = queue.getOrNull(index)
    val hasMedia: Boolean get() = current != null || station != null
}

/** The screens' side of the player: a MediaController connected to [PlaybackService]. */
class PlayerConnection(private val context: Context) {
    private var future: ListenableFuture<MediaController>? = null
    private var controller: MediaController? = null

    private val _state = MutableStateFlow(PlayerState())
    private val scope = MainScope()
    /** What this phone plays – or, while the own TV plays or a Jukebox is joined, what plays there. */
    val state: StateFlow<PlayerState> = combine(_state, TvLink.remote) { local, remote -> remote?.toPlayerState() ?: local }
        .stateIn(scope, SharingStarted.Eagerly, PlayerState())

    private val remote get() = TvLink.remote.value

    init {
        // The audiobook player reads its saved speed and skip intervals, and the downloads their index
        BookPlayer.init(context.tonalo)
    }

    private fun Remote.toPlayerState(): PlayerState {
        val s = state
        val queue = s.queue.orEmpty()
        val index = if (queue.isEmpty()) -1 else (s.index ?: 0).coerceIn(0, queue.lastIndex)
        return PlayerState(
            queue = queue, index = index,
            upNext = if (index < 0) emptyList() else ((index + 1) until queue.size).toList(),
            isPlaying = s.playing == true,
            shuffle = s.shuffle == true,
            repeatMode = when (s.repeat) { "all" -> Player.REPEAT_MODE_ALL; "one" -> Player.REPEAT_MODE_ONE; else -> Player.REPEAT_MODE_OFF },
            durationMs = ((s.duration ?: 0.0) * 1000).toLong().takeIf { it > 0 } ?: ((queue.getOrNull(index)?.duration ?: 0) * 1000L),
            station = s.station, context = s.context?.name,
            tvName = device.name, tvGuest = guest,
        )
    }

    /** "Only the host can do that" – a guest of a Jukebox may add songs and skip. */
    private val _hostOnly = kotlinx.coroutines.flow.MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val hostOnly: kotlinx.coroutines.flow.SharedFlow<Unit> = _hostOnly

    private fun guestBlocked(): Boolean {
        if (remote?.guest == true) { _hostOnly.tryEmit(Unit); return true }
        return false
    }

    fun connect() {
        if (future != null) return
        val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
        val f = MediaController.Builder(context, token).buildAsync()
        future = f
        f.addListener({
            val c = runCatching { f.get() }.getOrNull()
            if (c == null) {
                // Failed (or released meanwhile): the next connect() may try again
                if (future === f) future = null
                return@addListener
            }
            if (future !== f) { c.release(); return@addListener }
            controller = c
            queueCache = null
            c.addListener(listener)
            restoreIfEmpty(c)
            refresh()
        }, ContextCompat.getMainExecutor(context))
    }

    fun release() {
        controller?.removeListener(listener)
        future?.let { MediaController.releaseFuture(it) }
        future = null
        controller = null
        queueCache = null
    }

    /** The queue from last time, ready to continue – without starting to play. */
    private fun restoreIfEmpty(c: MediaController) {
        if (c.mediaItemCount > 0) return
        val account = context.tonalo.current.value ?: return
        val saved = context.tonalo.queues.load(account.id)?.takeIf { it.songs.isNotEmpty() } ?: return
        c.setMediaItems(saved.songs.map { it.toMediaItem() }, saved.index.coerceIn(0, saved.songs.lastIndex), saved.positionMs)
        c.prepare()
    }

    private val listener = object : Player.Listener {
        override fun onEvents(player: Player, events: Player.Events) {
            // Songs and their hearts live in the timeline: only then is the queue decoded again
            if (events.contains(Player.EVENT_TIMELINE_CHANGED)) queueCache = null
            refresh()
        }
    }

    /** The queue as songs, decoded once per timeline change. */
    private var queueCache: List<Song>? = null

    private fun refresh() {
        val c = controller ?: return
        // An audiobook has the player: the music side shows nothing (its queue is saved and comes back afterwards)
        if (c.currentMediaItem?.isBook == true) {
            _state.value = PlayerState()
            return
        }
        val station = c.currentMediaItem?.station
        val cached = queueCache?.takeIf { it.size == c.mediaItemCount }
            ?: (0 until c.mediaItemCount).map { c.getMediaItemAt(it).song ?: Song(it.toString(), "?") }.also { queueCache = it }
        val queue = if (station != null) emptyList() else cached
        val upNext = buildList {
            val t = c.currentTimeline
            if (t.isEmpty) return@buildList
            var i = c.currentMediaItemIndex
            while (size < queue.size) {
                i = t.getNextWindowIndex(i, Player.REPEAT_MODE_OFF, c.shuffleModeEnabled)
                if (i == C.INDEX_UNSET) break
                add(i)
            }
        }
        _state.value = PlayerState(
            queue = queue,
            index = if (queue.isEmpty()) -1 else c.currentMediaItemIndex,
            upNext = upNext,
            isPlaying = c.isPlaying,
            buffering = c.playbackState == Player.STATE_BUFFERING,
            shuffle = c.shuffleModeEnabled,
            repeatMode = c.repeatMode,
            durationMs = c.duration.takeIf { it != C.TIME_UNSET && it > 0 } ?: ((queue.getOrNull(c.currentMediaItemIndex)?.duration ?: 0) * 1000L),
            error = c.playerError?.message,
            station = station,
            liveTitle = c.mediaMetadata.title?.toString()?.takeIf { station != null && it != station.name },
            context = c.currentMediaItem?.mediaMetadata?.extras?.getString(CONTEXT_KEY),
            contextId = c.currentMediaItem?.mediaMetadata?.extras?.getString(CONTEXT_ID_KEY),
        )
    }

    fun position(): Long = remote?.let { (it.position() * 1000).toLong() } ?: controller?.currentPosition ?: 0
    fun buffered(): Long = controller?.bufferedPosition ?: 0

    // region Commands

    fun play(songs: List<Song>, start: Int = 0, shuffled: Boolean = false, positionMs: Long = 0, context: String? = null, contextId: String? = null) {
        if (songs.isEmpty()) return
        remote?.let { r ->
            // A guest's pick goes into the Jukebox's queue; the own TV plays it
            if (r.guest) TvLink.add(songs.drop(start).take(20), next = false)
            else TvLink.play(songs, start, shuffled, context, positionMs / 1000.0)
            return
        }
        val c = controller ?: return
        val list = if (shuffled) songs.shuffled() else songs
        c.shuffleModeEnabled = false
        c.setMediaItems(list.map { it.toMediaItem(context = context, contextId = contextId) }, if (shuffled) 0 else start.coerceIn(0, list.lastIndex), positionMs)
        c.prepare()
        c.play()
    }

    fun playNext(songs: List<Song>) {
        if (remote != null) return TvLink.add(songs, next = true)
        val c = controller ?: return
        if (c.mediaItemCount == 0 || c.currentMediaItem?.isBook == true) return play(songs)
        c.addMediaItems(c.currentMediaItemIndex + 1, songs.map { it.toMediaItem() })
    }

    fun enqueue(songs: List<Song>) {
        if (remote != null) return TvLink.add(songs, next = false)
        val c = controller ?: return
        if (c.mediaItemCount == 0 || c.currentMediaItem?.isBook == true) return play(songs)
        c.addMediaItems(songs.map { it.toMediaItem() })
    }

    fun toggle() {
        remote?.let { r -> if (!guestBlocked()) TvLink.command("play-pause", "playing" to (r.state.playing != true)); return }
        val c = controller ?: return
        if (c.playbackState == Player.STATE_IDLE) c.prepare()
        if (c.playbackState == Player.STATE_ENDED) c.seekToDefaultPosition(0)
        if (c.isPlaying) c.pause() else c.play()
    }

    fun next() { if (remote != null) TvLink.command("next") else controller?.run { if (playbackState == Player.STATE_IDLE) prepare(); seekToNext() } }
    fun previous() { if (remote != null) { if (!guestBlocked()) TvLink.command("prev") } else controller?.run { if (playbackState == Player.STATE_IDLE) prepare(); seekToPrevious() } }
    fun seek(ms: Long) { if (remote != null) { if (!guestBlocked()) TvLink.command("seek", "position" to ms / 1000.0) } else controller?.seekTo(ms) }
    fun jump(index: Int) {
        remote?.let { r -> if (!guestBlocked()) TvLink.command("jump", "index" to (r.state.offset ?: 0) + index); return }
        controller?.run { if (playbackState == Player.STATE_IDLE) prepare(); seekTo(index, 0); play() }
    }
    fun remove(index: Int) { if (remote == null) controller?.removeMediaItem(index) }
    fun move(from: Int, to: Int) { if (remote == null) controller?.moveMediaItem(from, to) }

    /** Keeps the song that's playing and drops everything after it. */
    fun clearUpNext() {
        if (remote != null) return
        val c = controller ?: return
        val i = c.currentMediaItemIndex
        if (i + 1 < c.mediaItemCount) c.removeMediaItems(i + 1, c.mediaItemCount)
        if (i > 0) c.removeMediaItems(0, i)
    }

    fun toggleShuffle() {
        remote?.let { r -> if (!guestBlocked()) TvLink.command("shuffle", "on" to (r.state.shuffle != true)); return }
        controller?.let { it.shuffleModeEnabled = !it.shuffleModeEnabled }
    }

    fun cycleRepeat() {
        remote?.let { r ->
            if (!guestBlocked()) TvLink.command("repeat", "mode" to when (r.state.repeat) { "off", null -> "all"; "all" -> "one"; else -> "off" })
            return
        }
        val c = controller ?: return
        c.repeatMode = when (c.repeatMode) {
            Player.REPEAT_MODE_OFF -> Player.REPEAT_MODE_ALL
            Player.REPEAT_MODE_ALL -> Player.REPEAT_MODE_ONE
            else -> Player.REPEAT_MODE_OFF
        }
    }

    /** A song's details changed (a heart): replaces it in the queue without interrupting playback. */
    fun update(song: Song) {
        remote?.let { r -> if (!r.guest) TvLink.command("star", "id" to song.id, "on" to (song.starred != null)) }
        val c = controller ?: return
        for (i in 0 until c.mediaItemCount) {
            val item = c.getMediaItemAt(i)
            if (item.mediaId == song.id) {
                c.replaceMediaItem(i, item.buildUpon().setMediaMetadata(song.toMediaItem(context = item.mediaMetadata.extras?.getString(CONTEXT_KEY)).mediaMetadata).build())
            }
        }
    }

    /** What plays here goes on on the own TV, from the same spot. */
    fun playOnTv() {
        val s = state.value
        if (remote != null || TvLink.ownTv.value == null) return
        s.station?.let { st -> TvLink.playStation(st, listOf(st)); controller?.pause(); return }
        if (s.current == null) return
        TvLink.play(s.queue, s.index, false, s.context, position() / 1000.0)
        controller?.pause()
    }

    /** "Play here": the TV pauses, the music goes on on this phone from the same spot. A guest leaves the Jukebox. */
    fun continueHere() {
        val r = remote ?: return
        if (r.guest) { TvLink.leave(); return }
        TvLink.command("play-pause", "playing" to false)
        val songs = r.state.queue.orEmpty()
        val at = (r.position() * 1000).toLong()
        val index = r.state.index ?: 0
        TvLink.letGo()
        if (songs.isNotEmpty()) Playback.service?.takeOver(songs, index, at, play = true)
    }

    // endregion
}
