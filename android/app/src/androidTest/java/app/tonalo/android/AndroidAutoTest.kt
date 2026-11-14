package app.tonalo.android

import android.content.ComponentName
import android.media.MediaMetadata
import android.media.browse.MediaBrowser
import android.media.session.MediaController
import android.media.session.PlaybackState
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit

/**
 * Talks to the playback service the way Android Auto does: the platform MediaBrowser (Auto's MediaBrowserCompat
 * sits on top of it) and the platform MediaController for playing, search and the custom buttons.
 * Needs a signed-in account (the demo server on the computer, 10.0.2.2:4599).
 */
@RunWith(AndroidJUnit4::class)
class AndroidAutoTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val thread = HandlerThread("car").apply { start() }
    private val handler = Handler(thread.looper)
    private lateinit var browser: MediaBrowser

    private fun log(text: String) = Log.i("AutoTest", text)

    @Before
    fun connect() {
        val connected = CompletableFuture<Unit>()
        handler.post {
            // The hints Android Auto sends with its connection
            val hints = Bundle().apply { putBoolean("android.service.media.extra.SUGGESTED", false) }
            browser = MediaBrowser(context, ComponentName(context, "app.tonalo.android.playback.PlaybackService"), object : MediaBrowser.ConnectionCallback() {
                override fun onConnected() { connected.complete(Unit) }
                override fun onConnectionFailed() { connected.completeExceptionally(IllegalStateException("connection failed")) }
            }, hints)
            browser.connect()
        }
        connected.get(20, TimeUnit.SECONDS)
    }

    @After
    fun disconnect() { handler.post { browser.disconnect() }; thread.quitSafely() }

    private fun children(id: String): List<MediaBrowser.MediaItem> {
        val f = CompletableFuture<List<MediaBrowser.MediaItem>>()
        handler.post {
            browser.subscribe(id, object : MediaBrowser.SubscriptionCallback() {
                override fun onChildrenLoaded(parentId: String, children: MutableList<MediaBrowser.MediaItem>) {
                    browser.unsubscribe(id); f.complete(children)
                }
                override fun onError(parentId: String) { f.completeExceptionally(IllegalStateException("error $parentId")) }
            })
        }
        return f.get(30, TimeUnit.SECONDS).also { list ->
            log("$id → ${list.size}: " + list.take(6).joinToString { "${it.mediaId} '${it.description.title}' ${if (it.isBrowsable) "B" else ""}${if (it.isPlayable) "P" else ""}" })
        }
    }

    @Test
    fun rootHasTabsSearchAndStyles() {
        val extras = browser.extras
        log("root ${browser.root} extras=${extras?.keySet()?.joinToString()}")
        assertEquals(true, extras?.getBoolean("android.media.browse.SEARCH_SUPPORTED"))
        assertEquals(2, extras?.getInt("android.media.browse.CONTENT_STYLE_BROWSABLE_HINT"))
        val tabs = children(browser.root)
        assertEquals(listOf("tab|home", "tab|playlists", "tab|library", "tab|radio"), tabs.map { it.mediaId })
        assertTrue(tabs.all { it.isBrowsable })
    }

    @Test
    fun everyTabHasContentAndCoversOpen() {
        val home = children("tab|home")
        assertTrue("home has mixes", home.any { it.mediaId == "mix|shuffle" && it.isPlayable })
        val album = home.first { it.mediaId.orEmpty().startsWith("album|") }
        log("group hint: " + album.description.extras?.getString("android.media.browse.CONTENT_STYLE_GROUP_TITLE_HINT"))
        val cover = album.description.iconUri
        log("cover $cover")
        assertEquals("content", cover?.scheme)
        val bytes = context.contentResolver.openInputStream(cover!!)!!.use { it.readBytes() }
        log("cover bytes ${bytes.size}")
        assertTrue(bytes.size > 100)

        val songs = children(album.mediaId!!)
        assertTrue(songs.isNotEmpty() && songs.all { it.isPlayable && it.mediaId.orEmpty().startsWith("play|album|") })

        val playlists = children("tab|playlists")
        assertTrue(playlists.first().mediaId == "favorites")
        val library = children("tab|library")
        assertEquals(listOf("artists", "albums", "favorites", "downloads"), library.map { it.mediaId })
        val artists = children("artists")
        assertTrue(artists.isNotEmpty())
        assertTrue(children(artists.first().mediaId!!).isNotEmpty())
        assertTrue(children("albums").isNotEmpty())
        children("favorites")
        children("downloads")
        val radio = children("tab|radio")
        assertTrue(radio.first().mediaId == "radio|me")
    }

    /** Search goes through Media3's browser here – the platform browser has no search; Auto uses the compat one. */
    @Test
    fun search() {
        val token = androidx.media3.session.SessionToken(context, ComponentName(context, "app.tonalo.android.playback.PlaybackService"))
        val main = android.os.Handler(android.os.Looper.getMainLooper())
        val f = CompletableFuture<List<androidx.media3.common.MediaItem>>()
        main.post {
            val future = androidx.media3.session.MediaBrowser.Builder(context, token).setListener(object : androidx.media3.session.MediaBrowser.Listener {
                override fun onSearchResultChanged(b: androidx.media3.session.MediaBrowser, query: String, itemCount: Int, params: androidx.media3.session.MediaLibraryService.LibraryParams?) {
                    val r = b.getSearchResult(query, 0, 100, null)
                    r.addListener({ f.complete(r.get().value.orEmpty()); b.release() }, { main.post(it) })
                }
            }).buildAsync()
            future.addListener({ future.get().search("silver", null) }, { main.post(it) })
        }
        val items = f.get(30, TimeUnit.SECONDS)
        log("search silver → ${items.size}: " + items.take(8).joinToString { "${it.mediaId} '${it.mediaMetadata.title}'" })
        assertTrue(items.isNotEmpty())
    }

    private fun controller() = MediaController(context, browser.sessionToken)

    private fun waitFor(c: MediaController, what: String, check: () -> Boolean) {
        val until = System.currentTimeMillis() + 20_000
        while (System.currentTimeMillis() < until) { if (check()) return; Thread.sleep(250) }
        throw AssertionError("timed out: $what (state ${c.playbackState?.state}, title ${c.metadata?.getString(MediaMetadata.METADATA_KEY_TITLE)})")
    }

    @Test
    fun playFromCarAndVoiceAndButtons() {
        val c = controller()
        val album = children("tab|home").first { it.mediaId.orEmpty().startsWith("album|") }
        val song = children(album.mediaId!!)[1]

        // Tapping a song in the car
        c.transportControls.playFromMediaId(song.mediaId!!, null)
        waitFor(c, "song from car") { c.metadata?.getString(MediaMetadata.METADATA_KEY_TITLE) == song.description.title.toString() }
        log("playing '${c.metadata?.getString(MediaMetadata.METADATA_KEY_TITLE)}' state ${c.playbackState?.state} queue ${c.queue?.size}")
        log("art uri ${c.metadata?.getString(MediaMetadata.METADATA_KEY_ART_URI)} bitmap ${c.metadata?.getBitmap(MediaMetadata.METADATA_KEY_ART) != null}")
        waitFor(c, "art bitmap") { c.metadata?.getBitmap(MediaMetadata.METADATA_KEY_ART) != null || c.metadata?.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART) != null }

        // The custom buttons: heart, shuffle, radio
        waitFor(c, "custom actions") { c.playbackState?.customActions?.size == 3 }
        val actions = c.playbackState!!.customActions
        log("custom actions: " + actions.joinToString { "${it.action} '${it.name}'" })
        val heart = actions.first { it.action == "tonalo.favorite" }
        val before = heart.name.toString()
        c.transportControls.sendCustomAction(heart, null)
        waitFor(c, "heart changed") { c.playbackState?.customActions?.firstOrNull { it.action == "tonalo.favorite" }?.name?.toString() != before }
        log("heart now '${c.playbackState?.customActions?.first { it.action == "tonalo.favorite" }?.name}'")
        c.transportControls.sendCustomAction(c.playbackState!!.customActions.first { it.action == "tonalo.favorite" }, null) // back as it was

        // Playing a whole album from its play button
        c.transportControls.playFromMediaId(album.mediaId!!, null)
        waitFor(c, "album from car") { c.queue?.size == children(album.mediaId!!).size && c.metadata?.getString(MediaMetadata.METADATA_KEY_TITLE) == children(album.mediaId!!)[0].description.title.toString() }

        // A mix and an endless radio
        c.transportControls.playFromMediaId("mix|shuffle", null)
        waitFor(c, "shuffle mix") { (c.queue?.size ?: 0) > 20 }
        log("shuffle mix queue ${c.queue?.size}")
        val mixFirst = c.queue?.firstOrNull()?.description?.mediaId
        c.transportControls.playFromMediaId("radio|me", null)
        waitFor(c, "your radio") { (c.queue?.size ?: 0) in 5..60 && c.queue?.firstOrNull()?.description?.mediaId != mixFirst }
        log("radio context " + c.metadata?.getString(MediaMetadata.METADATA_KEY_TITLE))
        log("radio queue ${c.queue?.size}")

        // "Hey Google, play Silver Weather on Tonalo"
        c.transportControls.playFromSearch("Silver Weather", null)
        waitFor(c, "voice") { c.metadata?.getString(MediaMetadata.METADATA_KEY_ALBUM) == "Silver Weather" && c.queue?.size == 10 }
        log("voice → '${c.metadata?.getString(MediaMetadata.METADATA_KEY_TITLE)}' from '${c.metadata?.getString(MediaMetadata.METADATA_KEY_ALBUM)}' queue ${c.queue?.size}")

        // "Play music on Tonalo"
        c.transportControls.playFromSearch("", null)
        waitFor(c, "empty voice") { (c.queue?.size ?: 0) > 20 }
        c.transportControls.pause()
    }
}
