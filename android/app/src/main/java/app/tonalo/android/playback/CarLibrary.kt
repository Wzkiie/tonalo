package app.tonalo.android.playback

import android.os.Bundle
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import app.tonalo.android.R
import app.tonalo.android.TonaloApplication
import app.tonalo.android.data.Album
import app.tonalo.android.data.Song
import app.tonalo.android.data.SubsonicClient
import app.tonalo.android.downloads.Downloads

/**
 * What Android Auto shows: four tabs (Home, Playlists, Library, Radio), search, and what to play for an item the car
 * picked or a voice request ("Hey Google, play Silver Weather on Tonalo").
 *
 * Ids: `tab|home`, `album|<id>`, `playlist|<id>`, `artist|<id>`, `artists`, `albums`, `favorites`, `downloads` are folders;
 * `play|<list>|<id>|<index>` plays a list from a song, `mix|…`, `radio|…`, `station|<id>` start a mix, an endless radio
 * or a station. Albums, playlists and the favorites are folders that can also be played as a whole.
 */
class CarLibrary(private val app: TonaloApplication) {

    /** Search results by query: the car asks for them right after the search. */
    private val searches = LinkedHashMap<String, List<MediaItem>>()

    private fun str(id: Int, vararg args: Any) = app.getString(id, *args)
    private val accountId get() = app.current.value?.id

    // region Items

    private fun hints(browsableGrid: Boolean = true, playableGrid: Boolean = false, group: String? = null) = Bundle().apply {
        putInt(CONTENT_STYLE_BROWSABLE, if (browsableGrid) STYLE_GRID else STYLE_LIST)
        putInt(CONTENT_STYLE_PLAYABLE, if (playableGrid) STYLE_GRID else STYLE_LIST)
        group?.let { putString(CONTENT_STYLE_GROUP, it) }
    }

    fun folder(
        id: String, title: String, type: Int = MediaMetadata.MEDIA_TYPE_FOLDER_MIXED, cover: String? = null,
        subtitle: String? = null, playable: Boolean = false, extras: Bundle? = null,
    ): MediaItem = MediaItem.Builder().setMediaId(id).setMediaMetadata(
        MediaMetadata.Builder().setTitle(title).setSubtitle(subtitle).setArtist(subtitle)
            .setIsBrowsable(true).setIsPlayable(playable).setMediaType(type)
            .setArtworkUri(Covers.uri(accountId, cover))
            .setExtras(extras)
            .build()
    ).build()

    private fun action(id: String, title: String, subtitle: String?, type: Int = MediaMetadata.MEDIA_TYPE_PLAYLIST, group: String? = null): MediaItem =
        MediaItem.Builder().setMediaId(id).setMediaMetadata(
            MediaMetadata.Builder().setTitle(title).setSubtitle(subtitle).setArtist(subtitle)
                .setIsBrowsable(false).setIsPlayable(true).setMediaType(type)
                .setExtras(group?.let { Bundle().apply { putString(CONTENT_STYLE_GROUP, it) } })
                .build()
        ).build()

    /** A song as the car shows it, by its own id (for asking about it later). */
    fun songItem(song: Song): MediaItem = songItem(song.id, song)

    /** `play|<list>|<key>|<index>#<songId>`: the song's id lets the pick find it again if the list changed. */
    private fun playId(list: String, key: String, index: Int, song: Song) = "play|$list|$key|$index#${song.id}"

    private fun songItem(id: String, song: Song): MediaItem = MediaItem.Builder().setMediaId(id).setMediaMetadata(
        MediaMetadata.Builder().setTitle(song.title).setArtist(song.artist).setAlbumTitle(song.album)
            .setIsBrowsable(false).setIsPlayable(true).setMediaType(MediaMetadata.MEDIA_TYPE_MUSIC)
            .setArtworkUri(Covers.uri(accountId, song.coverArt))
            .setExtras(Bundle().apply { if (Downloads.isDownloaded(app, song.id)) putLong(DOWNLOAD_STATUS, STATUS_DOWNLOADED) })
            .apply { song.duration?.let { setDurationMs(it * 1000L) } }
            .build()
    ).build()

    private fun albumItem(a: Album, group: String? = null) = folder(
        "album|${a.id}", a.name, MediaMetadata.MEDIA_TYPE_ALBUM, a.coverArt, subtitle = a.artist, playable = true,
        extras = hints(browsableGrid = false).apply { group?.let { putString(CONTENT_STYLE_GROUP, it) } },
    )

    // endregion

    // region Browsing

    fun root(): MediaItem = folder("root", str(R.string.app_name))

    /** The root's hints: grids for folders, lists for songs, search on. */
    fun rootExtras() = hints(browsableGrid = true).apply { putBoolean(SEARCH_SUPPORTED, true); putBoolean(CONTENT_STYLE_SUPPORTED, true) }

    fun tabs(): List<MediaItem> = listOf(
        folder("tab|home", str(R.string.tab_home), extras = hints(browsableGrid = true)),
        folder("tab|playlists", str(R.string.playlists), MediaMetadata.MEDIA_TYPE_FOLDER_PLAYLISTS, extras = hints(browsableGrid = true)),
        folder("tab|library", str(R.string.tab_library), extras = hints(browsableGrid = false)),
        folder("tab|radio", str(R.string.radio), MediaMetadata.MEDIA_TYPE_FOLDER_RADIO_STATIONS, extras = hints(browsableGrid = true)),
    )

    suspend fun children(parentId: String): List<MediaItem> {
        if (parentId == "root") return tabs()
        val c = app.client() ?: return listOf(action("signin", str(R.string.car_sign_in), str(R.string.car_sign_in_info)).let {
            // Not playable: only a note
            it.buildUpon().setMediaMetadata(it.mediaMetadata.buildUpon().setIsPlayable(false).build()).build()
        })
        val parts = parentId.split("|")
        return when (parts[0]) {
            "tab" -> when (parts.getOrNull(1)) {
                "home" -> home(c)
                "playlists" -> listOf(
                    folder("favorites", str(R.string.favorite_songs), MediaMetadata.MEDIA_TYPE_PLAYLIST, playable = true, extras = hints(false)),
                ) + c.playlists().map {
                    folder("playlist|${it.id}", it.name, MediaMetadata.MEDIA_TYPE_PLAYLIST, it.coverArt,
                        subtitle = it.songCount?.let { n -> app.resources.getQuantityString(R.plurals.song_count, n, n) },
                        playable = true, extras = hints(false))
                }
                "library" -> listOf(
                    folder("artists", str(R.string.artists), MediaMetadata.MEDIA_TYPE_FOLDER_ARTISTS, extras = hints(browsableGrid = false)),
                    folder("albums", str(R.string.albums), MediaMetadata.MEDIA_TYPE_FOLDER_ALBUMS, extras = hints(browsableGrid = true)),
                    folder("favorites", str(R.string.favorite_songs), MediaMetadata.MEDIA_TYPE_PLAYLIST, playable = true, extras = hints(false)),
                    folder("downloads", str(R.string.downloads), MediaMetadata.MEDIA_TYPE_FOLDER_MIXED, playable = true, extras = hints(false)),
                )
                "radio" -> radio(c)
                else -> emptyList()
            }
            "artists" -> c.artists().sortedBy { it.name.lowercase() }.map {
                folder("artist|${it.id}", it.name, MediaMetadata.MEDIA_TYPE_ARTIST, it.coverArt ?: "ar-${it.id}", extras = hints(browsableGrid = true))
            }
            "artist" -> c.artist(parts[1]).album.orEmpty().sortedByDescending { it.year ?: 0 }.map { albumItem(it) }
            "albums" -> c.albumList("alphabeticalByName", size = 300).map { albumItem(it) }
            "album" -> c.album(parts[1]).song.orEmpty().mapIndexed { i, s -> songItem(playId("album", parts[1], i, s), s) }
            "playlist" -> c.playlist(parts[1]).entry.orEmpty().mapIndexed { i, s -> songItem(playId("playlist", parts[1], i, s), s) }
            "favorites" -> c.starred().song.orEmpty().mapIndexed { i, s -> songItem(playId("favorites", "", i, s), s) }
            "downloads" -> downloaded().mapIndexed { i, s -> songItem(playId("downloads", "", i, s), s) }
            else -> emptyList()
        }
    }

    private suspend fun home(c: SubsonicClient): List<MediaItem> {
        val forYou = str(R.string.made_for_you)
        val mixes = listOf(
            action("mix|shuffle", str(R.string.shuffle_mix), str(R.string.shuffle_mix_info), group = forYou),
            action("mix|favorites", str(R.string.favorites_mix), str(R.string.favorites_mix_info), group = forYou),
            action("radio|me", str(R.string.your_radio), str(R.string.your_radio_info), MediaMetadata.MEDIA_TYPE_RADIO_STATION, group = forYou),
        )
        val recent = runCatching { c.albumList("recent", size = 12) }.getOrDefault(emptyList())
        val newest = runCatching { c.albumList("newest", size = 12) }.getOrDefault(emptyList())
        return mixes + recent.map { albumItem(it, str(R.string.recently_played)) } + newest.map { albumItem(it, str(R.string.recently_added)) }
    }

    private suspend fun radio(c: SubsonicClient): List<MediaItem> {
        val endless = str(R.string.endless_radio)
        val genres = runCatching { c.genres() }.getOrDefault(emptyList())
            .filter { (it.songCount ?: 0) > 0 }.sortedByDescending { it.songCount ?: 0 }.take(8)
        val stations = runCatching { c.stations() }.getOrDefault(emptyList())
        return listOf(action("radio|me", str(R.string.your_radio), str(R.string.your_radio_info), MediaMetadata.MEDIA_TYPE_RADIO_STATION, group = endless)) +
            genres.map { action("radio|genre|${it.value}", it.value, str(R.string.genre_radio), MediaMetadata.MEDIA_TYPE_RADIO_STATION, group = endless) } +
            stations.map { st ->
                val item = st.toMediaItem()
                item.buildUpon().setMediaMetadata(item.mediaMetadata.buildUpon().setSubtitle(str(R.string.live)).setArtist(str(R.string.live))
                    .setExtras(Bundle(item.mediaMetadata.extras ?: Bundle()).apply { putString(CONTENT_STYLE_GROUP, str(R.string.stations)) }).build()).build()
            }
    }

    private fun downloaded(): List<Song> = Downloads.forAccount(Downloads.all.value, accountId).filter { it.done }.map { it.song }.sortedBy { it.title.lowercase() }

    /** A folder the car asks about by id (rarely – mostly after a restart, for the item that played last). */
    fun item(id: String): MediaItem? = when {
        id == "root" -> root()
        id.startsWith("tab|") -> tabs().firstOrNull { it.mediaId == id }
        else -> null
    }

    /** Folders and songs the car asks about by id that [item] doesn't know: albums, playlists and the songs of a list. */
    suspend fun itemFor(id: String): MediaItem? {
        val c = app.client() ?: return null
        val parts = id.split("|")
        return when (parts[0]) {
            "album" -> albumItem(c.album(parts[1]))
            "playlist" -> c.playlist(parts[1]).let {
                folder("playlist|${it.id}", it.name, MediaMetadata.MEDIA_TYPE_PLAYLIST, it.coverArt, playable = true, extras = hints(false))
            }
            "play" -> pick(id) { _, _, _ -> emptyList() }?.let { p -> p.songs.getOrNull(p.start)?.let { songItem(id, it) } }
            else -> null
        }
    }

    // endregion

    // region Search

    suspend fun search(query: String): List<MediaItem> {
        val c = app.client() ?: return emptyList()
        val r = c.search(query)
        val items = r.artist.orEmpty().take(5).map {
            folder("artist|${it.id}", it.name, MediaMetadata.MEDIA_TYPE_ARTIST, it.coverArt ?: "ar-${it.id}",
                extras = hints(true).apply { putString(CONTENT_STYLE_GROUP, str(R.string.artists)) })
        } + r.album.orEmpty().take(10).map { albumItem(it, str(R.string.albums)) } +
            r.song.orEmpty().mapIndexed { i, s ->
                val item = songItem(playId("search", query, i, s), s)
                item.buildUpon().setMediaMetadata(item.mediaMetadata.buildUpon()
                    .setExtras(Bundle(item.mediaMetadata.extras ?: Bundle()).apply { putString(CONTENT_STYLE_GROUP, str(R.string.songs)) }).build()).build()
            }
        synchronized(searches) {
            searches[query] = items
            while (searches.size > 5) searches.remove(searches.keys.first())
        }
        return items
    }

    fun searchResult(query: String): List<MediaItem>? = synchronized(searches) { searches[query] }

    // endregion

    // region What to play

    /** What a picked id plays: the songs (with a start) or a station; `radio` is true for an endless radio. */
    class Pick(val songs: List<Song> = emptyList(), val start: Int = 0, val context: String? = null, val station: app.tonalo.android.data.Station? = null, val radio: Boolean = false)

    suspend fun pick(id: String, startRadio: suspend (name: String, seeds: List<Song>, genre: String?) -> List<Song>): Pick? {
        val c = app.client() ?: return null
        val parts = id.split("|")
        return when (parts[0]) {
            "play" -> {
                val list = parts.getOrNull(1)
                val key = parts.getOrNull(2).orEmpty()
                val (songs, name) = when (list) {
                    "album" -> c.album(key).let { it.song.orEmpty() to it.name }
                    "playlist" -> c.playlist(key).let { it.entry.orEmpty() to it.name }
                    "downloads" -> downloaded() to str(R.string.downloads)
                    // The query may contain "|": everything between the list name and the index
                    "search" -> c.search(parts.drop(2).dropLast(1).joinToString("|")).song.orEmpty() to null
                    else -> c.starred().song.orEmpty() to str(R.string.favorite_songs)
                }
                // `<index>#<songId>`: the song by its id; the index only when the list no longer has it
                val last = parts.last()
                val songId = last.substringAfter('#', "").takeIf { it.isNotEmpty() }
                val index = last.substringBefore('#').toIntOrNull() ?: 0
                Pick(songs, songId?.let { sid -> songs.indexOfFirst { it.id == sid }.takeIf { it >= 0 } } ?: index, name)
            }
            "album" -> c.album(parts[1]).let { Pick(it.song.orEmpty(), 0, it.name) }
            "playlist" -> c.playlist(parts[1]).let { Pick(it.entry.orEmpty(), 0, it.name) }
            "favorites" -> Pick(c.starred().song.orEmpty(), 0, str(R.string.favorite_songs))
            "downloads" -> Pick(downloaded(), 0, str(R.string.downloads))
            "mix" -> when (parts.getOrNull(1)) {
                "favorites" -> Pick(c.starred().song.orEmpty().shuffled(), 0, str(R.string.favorites_mix))
                else -> Pick(c.randomSongs(150), 0, str(R.string.shuffle_mix))
            }
            "radio" -> {
                if (parts.getOrNull(1) == "genre") {
                    val genre = parts.drop(2).joinToString("|")
                    Pick(startRadio(genre, emptyList(), genre), 0, genre, radio = true)
                } else {
                    val name = str(R.string.your_radio)
                    val favs = runCatching { c.starred().song }.getOrNull().orEmpty().shuffled().take(10)
                    Pick(startRadio(name, favs, null), 0, name, radio = true)
                }
            }
            "station" -> c.stations().firstOrNull { it.id == parts.getOrNull(1) }?.let { Pick(station = it) }
            else -> null
        }
    }

    /**
     * A voice request. Empty ("play music on Tonalo"): a shuffle of the library. Otherwise the best match:
     * an artist by that name plays as a radio, an album by that name plays from the start, else the songs found.
     */
    suspend fun voice(query: String, startRadio: suspend (name: String, seeds: List<Song>, genre: String?) -> List<Song>): Pick? {
        val c = app.client() ?: return null
        if (query.isBlank()) return Pick(c.randomSongs(150), 0, str(R.string.shuffle_mix))
        val r = c.search(query)
        val q = query.trim().lowercase()
        r.artist.orEmpty().firstOrNull { it.name.lowercase() == q }?.let { artist ->
            val name = str(R.string.more_like, artist.name)
            val top = runCatching { c.topSongs(artist.name) }.getOrDefault(emptyList())
            val songs = startRadio(name, top.take(5), null)
            if (songs.isNotEmpty()) return Pick(songs, 0, name, radio = true)
        }
        r.album.orEmpty().firstOrNull { it.name.lowercase() == q }?.let { a -> return c.album(a.id).let { Pick(it.song.orEmpty(), 0, it.name) } }
        val songs = r.song.orEmpty()
        if (songs.isNotEmpty()) return Pick(songs, 0, null)
        r.album.orEmpty().firstOrNull()?.let { a -> return c.album(a.id).let { Pick(it.song.orEmpty(), 0, it.name) } }
        return null
    }

    // endregion

    companion object {
        // Keys Android Auto reads (androidx.media.utils.MediaConstants), as plain strings
        const val CONTENT_STYLE_BROWSABLE = "android.media.browse.CONTENT_STYLE_BROWSABLE_HINT"
        const val CONTENT_STYLE_PLAYABLE = "android.media.browse.CONTENT_STYLE_PLAYABLE_HINT"
        const val CONTENT_STYLE_GROUP = "android.media.browse.CONTENT_STYLE_GROUP_TITLE_HINT"
        const val CONTENT_STYLE_SUPPORTED = "android.media.browse.CONTENT_STYLE_SUPPORTED"
        const val SEARCH_SUPPORTED = "android.media.browse.SEARCH_SUPPORTED"
        const val DOWNLOAD_STATUS = "android.media.extra.DOWNLOAD_STATUS"
        const val STATUS_DOWNLOADED = 2L
        const val STYLE_LIST = 1
        const val STYLE_GRID = 2
    }
}
