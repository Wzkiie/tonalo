package app.tonalo.android.playback

import android.content.Context
import androidx.media3.common.MediaItem
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheWriter
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.datasource.okhttp.OkHttpDataSource
import java.io.File
import java.util.concurrent.Executors

/**
 * Songs of the queue that are loaded ahead of time, so a weak or patchy connection doesn't stop the music.
 *
 * A small disk cache (audio only, the least recently used songs go first). The songs are stored under their own
 * key (`stream|account|song|quality`, see `toMediaItem`): the request address holds the login token and never
 * becomes part of the cache. The player reads from the same cache, so a song that was loaded ahead plays from it.
 */
object Prefetch {
    /** The most the cache keeps; older songs are removed first. */
    private const val MAX_BYTES = 200L * 1024 * 1024

    @Volatile private var cache: SimpleCache? = null

    @Synchronized
    fun cache(context: Context): SimpleCache = cache ?: SimpleCache(
        File(context.cacheDir, "prefetch"), LeastRecentlyUsedCacheEvictor(MAX_BYTES), StandaloneDatabaseProvider(context),
    ).also { cache = it }

    /** The server's answer to a bad request is a JSON or XML text with status 200: that is no song, and must not be cached. */
    fun isAudio(contentType: String?): Boolean {
        val type = contentType?.lowercase() ?: return true
        return !type.contains("json") && !type.contains("xml")
    }

    /** What the player (and [Prefetcher]) read through: the cache first, the server (with login and custom headers) otherwise. */
    fun dataSourceFactory(context: Context, http: OkHttpDataSource.Factory): CacheDataSource.Factory = CacheDataSource.Factory()
        .setCache(cache(context))
        .setUpstreamDataSourceFactory(http.setContentTypePredicate { isAudio(it) })
        .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
}

/** Loads the given songs into [Prefetch]'s cache, one at a time, so the song that plays keeps most of the bandwidth. */
class Prefetcher(private val factory: CacheDataSource.Factory) {
    private val executor = Executors.newSingleThreadExecutor()
    @Volatile private var generation = 0
    @Volatile private var writer: CacheWriter? = null

    /** What is loaded next: a new list replaces the one before (a running load is stopped, what is cached stays). */
    fun update(items: List<MediaItem>) {
        cancel()
        if (items.isEmpty()) return
        val mine = generation
        executor.execute {
            for (item in items) {
                if (mine != generation) return@execute
                val uri = item.localConfiguration?.uri ?: continue
                val spec = DataSpec.Builder().setUri(uri).setKey(item.localConfiguration?.customCacheKey).build()
                val w = CacheWriter(factory.createDataSource(), spec, null, null)
                writer = w
                try {
                    w.cache()
                } catch (e: Exception) {
                    // No connection, or the song can't be loaded: try again when the next song starts
                    return@execute
                } finally {
                    writer = null
                }
            }
        }
    }

    fun cancel() {
        generation++
        writer?.cancel()
    }

    fun release() {
        cancel()
        executor.shutdownNow()
    }
}
