package app.tonalo.android.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.util.UUID

// region Accounts

/** Whether OkHttp accepts this header: visible ASCII in the name without spaces, no control or non-ASCII characters in the value. */
fun headerValid(name: String, value: String): Boolean = runCatching { okhttp3.Headers.Builder().add(name.trim(), value.trim()) }.isSuccess

/** Extra HTTP header sent with every request, e.g. for Cloudflare Access. */
@Serializable
data class HeaderField(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val value: String,
)

/** One server login. Stored encrypted (see [AccountStore]), because token and header values are secrets. */
@Serializable
data class Account(
    val id: String = UUID.randomUUID().toString(),
    val serverURL: String,
    val username: String,
    val salt: String,
    val token: String,
    val headers: List<HeaderField> = emptyList(),
    /** Optional address inside the home network (e.g. http://192.168.1.10:4533), used on Wi-Fi when it answers. */
    val localURL: String? = null,
    /** The Audiobookshelf connection of this account, if any. Accounts saved before it existed load without one. */
    val audiobooks: AudiobookServer? = null,
) {
    /**
     * Whether the account has a music (Subsonic) server. An account can be audiobooks only: then [serverURL] is
     * blank, [salt] and [token] are empty and [username] is the Audiobookshelf user.
     */
    val hasMusic: Boolean get() = serverURL.isNotBlank()

    /** The music server's host, or the audiobooks server's when there is no music server. */
    val host: String
        get() = if (hasMusic) runCatching { java.net.URI(serverURL).host }.getOrNull() ?: serverURL else audiobooks?.host ?: ""

    /** Only headers with a name are sent; values are trimmed so pasted secrets don't break. */
    val httpHeaders: Map<String, String>
        get() = headers.mapNotNull { h ->
            val name = h.name.trim()
            // One that OkHttp refuses (a space in the name, a smart quote in the value) would crash every request
            if (name.isEmpty() || !headerValid(name, h.value.trim())) null else name to h.value.trim()
        }.toMap()
}

// endregion

// region Subsonic data

@Serializable
data class Song(
    val id: String,
    val title: String,
    val artist: String? = null,
    val album: String? = null,
    val albumId: String? = null,
    val artistId: String? = null,
    val coverArt: String? = null,
    val duration: Int? = null,
    val track: Int? = null,
    val discNumber: Int? = null,
    val year: Int? = null,
    val starred: String? = null,
    val suffix: String? = null,
    val bitRate: Int? = null,
    val replayGain: ReplayGain? = null,
    val playCount: Int? = null,
    val genre: String? = null,
)

/** Loudness values from the file tags (OpenSubsonic). Navidrome sends 0 dB when a file has none. */
@Serializable
data class ReplayGain(
    val trackGain: Double? = null,
    val albumGain: Double? = null,
    val trackPeak: Double? = null,
    val albumPeak: Double? = null,
)

@Serializable
data class Album(
    val id: String,
    val name: String,
    val artist: String? = null,
    val artistId: String? = null,
    val coverArt: String? = null,
    val year: Int? = null,
    val songCount: Int? = null,
    val duration: Int? = null,
    val starred: String? = null,
    val genre: String? = null,
    val song: List<Song>? = null,
)

@Serializable
data class Artist(
    val id: String,
    val name: String,
    val coverArt: String? = null,
    val albumCount: Int? = null,
    val starred: String? = null,
    val album: List<Album>? = null,
)

@Serializable
data class Playlist(
    val id: String,
    val name: String,
    val songCount: Int? = null,
    val duration: Int? = null,
    val coverArt: String? = null,
    val owner: String? = null,
    val comment: String? = null,
    @SerialName("public") val isPublic: Boolean? = null,
    val changed: String? = null,
    /** Navidrome: the server manages the songs (smart playlist, auto-imported .m3u, someone else's playlist). */
    val readonly: Boolean? = null,
    val entry: List<Song>? = null,
)

/** The queue as the server keeps it for the user – whichever app saved it last. */
@Serializable
data class PlayQueue(
    val entry: List<Song>? = null,
    val current: String? = null,
    /** Milliseconds */
    val position: Long? = null,
    val changed: String? = null,
    val changedBy: String? = null,
)

@Serializable
data class Genre(
    val value: String,
    val albumCount: Int? = null,
    val songCount: Int? = null,
)

/** Similar artists: some servers list ones that aren't in the library, without an id – those are left out later. */
@Serializable
data class ArtistInfo(val biography: String? = null, val similarArtist: List<SimilarArtist>? = null)

@Serializable
data class SimilarArtist(val id: String = "", val name: String = "", val coverArt: String? = null)

@Serializable
data class LyricLine(val start: Long? = null, val value: String)

/** A radio station set up on the server (Navidrome: Radio). It streams from the station itself, not from the server. */
@Serializable
data class Station(val id: String, val name: String, val streamUrl: String, val homePageUrl: String? = null)

data class Lyrics(val synced: Boolean, val lines: List<LyricLine>)

// endregion

// region Response envelope

@Serializable data class SubsonicErrorBody(val code: Int, val message: String? = null)
@Serializable data class AlbumList(val album: List<Album>? = null)
@Serializable data class SongList(val song: List<Song>? = null)
@Serializable data class ArtistIndex(val name: String, val artist: List<Artist>? = null)
@Serializable data class ArtistsBody(val index: List<ArtistIndex>? = null)
@Serializable data class PlaylistsBody(val playlist: List<Playlist>? = null)
@Serializable data class GenresBody(val genre: List<Genre>? = null)
@Serializable data class SearchBody(val artist: List<Artist>? = null, val album: List<Album>? = null, val song: List<Song>? = null)
@Serializable data class StructuredLyrics(val synced: Boolean? = null, val line: List<LyricLine>? = null)
@Serializable data class LyricsListBody(val structuredLyrics: List<StructuredLyrics>? = null)
@Serializable data class StationsBody(val internetRadioStation: List<Station>? = null)

/** Everything a Subsonic call can return – each endpoint fills one of these fields. */
@Serializable
data class Payload(
    val status: String,
    val type: String? = null,
    val serverVersion: String? = null,
    val error: SubsonicErrorBody? = null,
    val albumList2: AlbumList? = null,
    val album: Album? = null,
    val artists: ArtistsBody? = null,
    val artist: Artist? = null,
    val artistInfo2: ArtistInfo? = null,
    val topSongs: SongList? = null,
    val similarSongs2: SongList? = null,
    val randomSongs: SongList? = null,
    val playlists: PlaylistsBody? = null,
    val playlist: Playlist? = null,
    val starred2: SearchBody? = null,
    val searchResult3: SearchBody? = null,
    val lyricsList: LyricsListBody? = null,
    val genres: GenresBody? = null,
    val playQueue: PlayQueue? = null,
    val internetRadioStations: StationsBody? = null,
)

@Serializable
data class Envelope(@SerialName("subsonic-response") val response: Payload)

// endregion

fun formatTime(seconds: Long): String {
    if (seconds <= 0) return "0:00"
    return "%d:%02d".format(seconds / 60, seconds % 60)
}
