package app.tonalo.android.playback

import android.net.Uri
import android.os.Bundle
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import app.tonalo.android.data.AudioQuality
import app.tonalo.android.data.Network
import app.tonalo.android.data.Song
import app.tonalo.android.data.Station
import app.tonalo.android.data.SubsonicClient

private const val SONG_KEY = "tonalo.song"
private const val STATION_KEY = "tonalo.station"
private const val STATION_URL_KEY = "tonalo.stationUrl"
/** Where the songs come from ("Album · Silver Weather") – shown in the player's header. */
const val CONTEXT_KEY = "tonalo.context"
/** What the songs were started from, by id ("a<album>", "p<playlist>", "r<artist>") – for "Recently played" in the library. */
const val CONTEXT_ID_KEY = "tonalo.contextId"

/**
 * A song as the player knows it. The whole song travels along in the extras, because the playback service
 * gets the items from the screens without their address (Media3 strips it) and builds the stream address itself.
 */
fun Song.toMediaItem(
    client: SubsonicClient? = null,
    quality: AudioQuality? = null,
    cacheKey: String? = null,
    context: String? = null,
    contextId: String? = null,
): MediaItem {
    val extras = Bundle().apply {
        putString(SONG_KEY, Network.json.encodeToString(Song.serializer(), this@toMediaItem))
        context?.let { putString(CONTEXT_KEY, it) }
        contextId?.let { putString(CONTEXT_ID_KEY, it) }
    }
    val meta = MediaMetadata.Builder()
        .setTitle(title)
        .setArtist(artist)
        .setAlbumTitle(album)
        .setAlbumArtist(artist)
        .setTrackNumber(track)
        .setDiscNumber(discNumber)
        .setReleaseYear(year)
        .setGenre(genre)
        .setIsPlayable(true)
        .setIsBrowsable(false)
        .setMediaType(MediaMetadata.MEDIA_TYPE_MUSIC)
        .setExtras(extras)
        .apply {
            duration?.let { setDurationMs(it * 1000L) }
            // A content:// address: the car can open it, and the login in the cover's web address stays inside the app
            Covers.uri(client?.account?.id, coverArt, 600)?.let { setArtworkUri(it) }
        }
        .build()
    return MediaItem.Builder()
        .setMediaId(id)
        .setMediaMetadata(meta)
        .apply {
            if (client != null && quality != null) client.streamURL(this@toMediaItem, quality)?.let { setUri(it) }
            cacheKey?.let { setCustomCacheKey(it) }
        }
        .build()
}

/** A radio station: plays straight from the station, live. `url` is the stream after resolving .m3u/.pls lists. */
fun Station.toMediaItem(url: String? = null): MediaItem {
    val extras = Bundle().apply {
        putString(STATION_KEY, Network.json.encodeToString(Station.serializer(), this@toMediaItem))
        url?.let { putString(STATION_URL_KEY, it) }
    }
    return MediaItem.Builder()
        .setMediaId("station|$id")
        .setMediaMetadata(
            MediaMetadata.Builder()
                .setTitle(name)
                .setStation(name)
                .setIsPlayable(true)
                .setIsBrowsable(false)
                .setMediaType(MediaMetadata.MEDIA_TYPE_RADIO_STATION)
                .setExtras(extras)
                .build()
        )
        .apply { url?.let { setUri(it) } }
        .build()
}

val MediaItem.song: Song?
    get() = mediaMetadata.extras?.getString(SONG_KEY)?.let {
        runCatching { Network.json.decodeFromString(Song.serializer(), it) }.getOrNull()
    }

val MediaItem.station: Station?
    get() = mediaMetadata.extras?.getString(STATION_KEY)?.let {
        runCatching { Network.json.decodeFromString(Station.serializer(), it) }.getOrNull()
    }

val MediaItem.stationUrl: String? get() = mediaMetadata.extras?.getString(STATION_URL_KEY)

private const val BOOK_KEY = "tonalo.book"

/**
 * The audiobook or podcast episode that plays, as the player's one item (see [BookPlayer]): the whole book is a single
 * window, so the notification, the lock screen and the car show the position and length of the book, not of a file.
 * Has no address of its own – the audio is the concatenation set with `setMediaSource`.
 */
fun bookMediaItem(
    mediaId: String,
    title: String?,
    artist: String?,
    album: String?,
    durationSec: Double,
    artwork: ByteArray?,
): MediaItem {
    val meta = MediaMetadata.Builder()
        .setTitle(title)
        .setArtist(artist)
        .setAlbumTitle(album)
        .setAlbumArtist(artist)
        .setIsPlayable(true)
        .setIsBrowsable(false)
        .setMediaType(MediaMetadata.MEDIA_TYPE_AUDIO_BOOK)
        .setExtras(Bundle().apply { putBoolean(BOOK_KEY, true) })
        .apply {
            if (durationSec > 0) setDurationMs((durationSec * 1000).toLong())
            if (artwork != null) setArtworkData(artwork, MediaMetadata.PICTURE_TYPE_FRONT_COVER)
        }
        .build()
    return MediaItem.Builder().setMediaId(mediaId).setMediaMetadata(meta).build()
}

/** Is this the item of an audiobook or podcast episode ([bookMediaItem])? */
val MediaItem.isBook: Boolean get() = mediaMetadata.extras?.getBoolean(BOOK_KEY, false) == true
