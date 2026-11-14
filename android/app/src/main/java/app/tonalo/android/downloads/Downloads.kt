package app.tonalo.android.downloads

import android.app.Notification
import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.cache.NoOpCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.offline.Download
import androidx.media3.exoplayer.offline.DownloadManager
import androidx.media3.exoplayer.offline.DownloadNotificationHelper
import androidx.media3.exoplayer.offline.DownloadRequest
import androidx.media3.exoplayer.offline.DownloadService
import androidx.media3.exoplayer.scheduler.Scheduler
import android.net.Uri
import app.tonalo.android.R
import app.tonalo.android.data.Network
import app.tonalo.android.data.Song
import app.tonalo.android.data.SubsonicClient
import app.tonalo.android.tonalo
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File
import java.util.concurrent.Executors

/** A song on its way to the phone, or already there. */
data class DownloadInfo(val song: Song, val done: Boolean, val progress: Float, val failed: Boolean)

/**
 * Offline downloads, kept in Media3's download cache. Each song is stored under "account:songId",
 * so playback finds it whatever quality or address the stream would have today.
 */
@OptIn(UnstableApi::class)
object Downloads {
    private var manager: DownloadManager? = null
    private var cache: SimpleCache? = null

    private val _all = MutableStateFlow<Map<String, DownloadInfo>>(emptyMap())
    /** All downloads of all accounts, by key ("account:songId"). */
    val all: StateFlow<Map<String, DownloadInfo>> = _all.asStateFlow()

    fun key(account: String, songId: String) = "$account:$songId"

    @Synchronized
    fun cache(context: Context): SimpleCache = cache ?: SimpleCache(
        File(context.filesDir, "downloads"), NoOpCacheEvictor(), StandaloneDatabaseProvider(context),
    ).also { cache = it }

    @Synchronized
    fun manager(context: Context): DownloadManager {
        manager?.let { return it }
        val app = context.tonalo
        val m = DownloadManager(
            app, StandaloneDatabaseProvider(app), cache(app),
            OkHttpDataSource.Factory(app.mediaHttp), Executors.newFixedThreadPool(2),
        )
        m.maxParallelDownloads = 2
        m.addListener(object : DownloadManager.Listener {
            override fun onDownloadChanged(manager: DownloadManager, download: Download, finalException: Exception?) = update(download)
            override fun onDownloadRemoved(manager: DownloadManager, download: Download) {
                _all.value = _all.value - download.request.id
            }
        })
        // What was downloaded before
        val map = mutableMapOf<String, DownloadInfo>()
        m.downloadIndex.getDownloads().use { c -> while (c.moveToNext()) info(c.download)?.let { map[c.download.request.id] = it } }
        _all.value = map
        manager = m
        return m
    }

    private fun info(d: Download): DownloadInfo? {
        val song = runCatching { Network.json.decodeFromString(Song.serializer(), d.request.data.decodeToString()) }.getOrNull() ?: return null
        return DownloadInfo(
            song, done = d.state == Download.STATE_COMPLETED,
            progress = (d.percentDownloaded.takeIf { it >= 0 } ?: 0f) / 100f,
            failed = d.state == Download.STATE_FAILED,
        )
    }

    private fun update(d: Download) {
        val i = info(d) ?: return
        _all.value = _all.value + (d.request.id to i)
    }

    /** Refreshes the progress of running downloads (the manager only reports state changes). */
    fun poll(context: Context) {
        manager(context).currentDownloads.forEach(::update)
    }

    fun isDownloaded(context: Context, songId: String): Boolean {
        // After a cold start nothing has opened the manager yet (the service may start alone, from a headphone button or the car)
        if (manager == null) manager(context)
        val account = context.tonalo.current.value?.id ?: return false
        return _all.value[key(account, songId)]?.done == true
    }

    fun download(context: Context, songs: List<Song>) {
        val app = context.tonalo
        val account = app.current.value ?: return
        // Always the outside address: a download that continues after leaving home still works
        val client = SubsonicClient(account)
        val quality = app.settings.downloadQuality.value
        manager(context)
        for (song in songs) {
            val id = key(account.id, song.id)
            if (_all.value[id]?.done == true) continue
            val url = client.downloadURL(song, quality) ?: continue
            val request = DownloadRequest.Builder(id, Uri.parse(url))
                .setCustomCacheKey(id)
                .setData(Network.json.encodeToString(Song.serializer(), song).toByteArray())
                .build()
            DownloadService.sendAddDownload(context, TonaloDownloadService::class.java, request, false)
        }
    }

    fun remove(context: Context, songIds: List<String>) {
        val account = context.tonalo.current.value?.id ?: return
        manager(context)
        songIds.forEach { DownloadService.sendRemoveDownload(context, TonaloDownloadService::class.java, key(account, it), false) }
    }

    fun removeAccount(context: Context, account: String) {
        manager(context)
        _all.value.keys.filter { it.startsWith("$account:") }.forEach {
            DownloadService.sendRemoveDownload(context, TonaloDownloadService::class.java, it, false)
        }
    }

    /** Downloads of the current account. */
    fun forAccount(map: Map<String, DownloadInfo>, account: String?): List<DownloadInfo> =
        if (account == null) emptyList() else map.filterKeys { it.startsWith("$account:") }.values.toList()
}

/** Keeps downloads going in the background, with a progress notification. */
@OptIn(UnstableApi::class)
class TonaloDownloadService : DownloadService(
    NOTIFICATION_ID, DEFAULT_FOREGROUND_NOTIFICATION_UPDATE_INTERVAL, CHANNEL_ID, R.string.downloads, 0,
) {
    private val helper by lazy { DownloadNotificationHelper(this, CHANNEL_ID) }

    override fun getDownloadManager(): DownloadManager = Downloads.manager(this)

    override fun getScheduler(): Scheduler? = null

    override fun getForegroundNotification(downloads: MutableList<Download>, notMetRequirements: Int): Notification =
        helper.buildProgressNotification(this, R.drawable.ic_notification, null, null, downloads, notMetRequirements)

    companion object {
        private const val NOTIFICATION_ID = 2
        private const val CHANNEL_ID = "downloads"
    }
}
