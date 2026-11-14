package app.tonalo.android.data

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonObject
import java.util.UUID

// Audiobookshelf (audiobooks and podcasts) data: the connection kept in the Account, and what the server sends.
// Pure Kotlin on purpose (no Android classes), so it can be unit-tested on the JVM. All of it is decoded with
// [Network.json] (ignoreUnknownKeys, coerceInputValues, explicitNulls = false): whatever the server may leave out is
// nullable or has a default, so a missing field never costs a whole book.

// region Connection

/**
 * The connection to an Audiobookshelf server, kept inside the [Account] (which is stored encrypted, see [AccountStore]).
 * The password is never stored, only the tokens.
 */
@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class AudiobookServer(
    /** Address of the server as typed outside, without a trailing slash, e.g. `https://books.example.com`. */
    val url: String,
    /** The Audiobookshelf user name. */
    val username: String,
    /** Short-lived bearer token (about an hour), renewed with [refreshToken]. */
    val accessToken: String,
    /** Renews the access token; every renewal hands out a new one. Null on servers that don't issue one. */
    val refreshToken: String? = null,
    /** Extra HTTP headers for a proxy in front of the server (e.g. Cloudflare Access). */
    val headers: List<HeaderField> = emptyList(),
    /** Optional address inside the home network, used on Wi-Fi when the same server answers there. */
    val localURL: String? = null,
    /** Random, only so the server can tell its listening sessions apart. Says nothing about the device. */
    @EncodeDefault val deviceId: String = UUID.randomUUID().toString(),
) {
    /** Only headers with a name and a value OkHttp accepts, trimmed (see [headerValid]). */
    val httpHeaders: Map<String, String>
        get() = headers.mapNotNull { h ->
            val name = h.name.trim()
            val value = h.value.trim()
            if (name.isEmpty() || !headerValid(name, value)) null else name to value
        }.toMap()

    /** [httpHeaders] plus `Authorization: Bearer <accessToken>`: what every request to the API carries. */
    val authorized: Map<String, String> get() = httpHeaders + ("Authorization" to "Bearer $accessToken")

    /** The host name of [url], for matching requests to this server. */
    val host: String get() = hostOf(url) ?: url

    /** The host name of [localURL], if there is one. */
    val localHost: String? get() = localURL?.let { hostOf(it) }

    /**
     * What to talk to right now. Custom headers are for the proxy outside, so they don't go to the home address.
     * The tokens stay: the home address is only used after it was verified to be the same server.
     */
    fun route(atHome: Boolean): AudiobookServer {
        val home = localURL
        if (!atHome || home == null) return this
        return copy(url = home, headers = emptyList())
    }

    private fun hostOf(address: String): String? = runCatching { java.net.URI(address).host }.getOrNull()
}

/** Why a request to the server failed, in a form the UI can map to text (see `Throwable.bookErrorText`). */
sealed class AudiobookError(message: String) : Exception(message) {
    /** Wrong user name or password (or a login that can no longer be renewed). */
    class Login : AudiobookError("Wrong user name or password.")

    /** The account has no Audiobookshelf connection. */
    class NotConnected : AudiobookError("Audiobookshelf isn't connected.")

    /** The address doesn't answer like Audiobookshelf (a proxy login page, another service). */
    class Unexpected : AudiobookError(
        "That doesn't look like an Audiobookshelf server. If it's behind a proxy such as Cloudflare Access, check the custom headers."
    )

    /** The server rejected the saved login while an address was being changed: probably another server. */
    class Refused : AudiobookError("The server didn't accept your login. Is this really the same Audiobookshelf server?")

    /** The server answered with this error status. */
    class Http(val status: Int) : AudiobookError("The server answered with error $status.")

    /** The account could not be saved (encrypted storage failed). */
    class SaveFailed : AudiobookError("The login could not be saved.")
}

// endregion

// region Data from the server

/**
 * A library on the server: audiobooks or podcasts.
 * @property id the server's id, used in the library endpoints
 * @property name the name the admin gave it
 */
@Serializable
data class ABSLibrary(
    val id: String,
    val name: String = "",
    /** `book` or `podcast`. */
    val mediaType: String? = null,
) {
    /** Whether this library holds podcasts rather than audiobooks. */
    val isPodcasts: Boolean get() = mediaType == "podcast"
}

/**
 * A chapter of a book.
 * @property start seconds from the start of the whole book
 * @property end seconds from the start of the whole book
 * @property title the chapter's name, if it has one
 */
@Serializable
data class ABSChapter(
    val start: Double = 0.0,
    val end: Double = 0.0,
    val title: String? = null,
) {
    /** Chapters start at different times, so the start identifies one in lists. */
    val id: Double get() = start
}

/**
 * One audio file of a book or episode, as the expanded item lists it.
 * @property ino the file's id on the server
 * @property index 1-based position among the files
 * @property startOffset seconds into the whole book at which this file starts
 * @property duration seconds
 * @property title the track title, if listed
 * @property mimeType e.g. `audio/mpeg`
 * @property metadata extension and size in bytes
 */
@Serializable
data class ABSFile(
    val ino: String? = null,
    val index: Int? = null,
    /** Seconds into the whole book at which this file starts. */
    val startOffset: Double? = null,
    val duration: Double? = null,
    val title: String? = null,
    val mimeType: String? = null,
    val metadata: Info? = null,
) {
    /** File facts the server lists under `metadata`. */
    @Serializable
    data class Info(val ext: String? = null, val size: Double? = null)
}

/**
 * An episode of a podcast.
 * @property id the episode id (needed with the item id for progress and playback)
 * @property duration seconds, if listed on the episode itself (see [length])
 */
@Serializable
data class ABSEpisode(
    val id: String,
    val title: String? = null,
    val subtitle: String? = null,
    val description: String? = null,
    val duration: Double? = null,
    /** Publication date, in milliseconds. */
    val publishedAt: Double? = null,
    /** Newest shelves leave the duration on the audio file. */
    val audioFile: ABSFile? = null,
) {
    /** Duration in seconds, 0 when unknown. */
    val length: Double get() = duration ?: audioFile?.duration ?: 0.0
}

/**
 * An author; the list endpoints add a description and the number of books.
 * @property id the server's author id (for the image and the author page)
 * @property name display name
 */
@Serializable
data class ABSAuthor(
    val id: String,
    val name: String = "",
    val description: String? = null,
    val numBooks: Int? = null,
)

/**
 * A series a book belongs to.
 * @property id the series id (the filter value for `series`)
 * @property sequence the book's number in it, a string such as "1" or "2.5"
 */
@Serializable
data class ABSSeriesRef(
    val id: String,
    val name: String = "",
    val sequence: String? = null,
)

/**
 * The series of a book. The full item lists several, some shelves only the one they're about, as a single object:
 * both decode into [all]; elements of an unknown shape are skipped.
 */
@Serializable(with = ABSSeriesListSerializer::class)
data class ABSSeriesList(val all: List<ABSSeriesRef> = emptyList())

/** Reads a list or a single object of series; writes a list. */
object ABSSeriesListSerializer : KSerializer<ABSSeriesList> {
    private val list = ListSerializer(ABSSeriesRef.serializer())
    override val descriptor: SerialDescriptor get() = list.descriptor

    override fun deserialize(decoder: Decoder): ABSSeriesList {
        val input = decoder as? JsonDecoder ?: throw SerializationException("Series are read from JSON only")
        fun one(e: kotlinx.serialization.json.JsonElement): ABSSeriesRef? =
            try { input.json.decodeFromJsonElement(ABSSeriesRef.serializer(), e) } catch (x: IllegalArgumentException) { null }
        return when (val element = input.decodeJsonElement()) {
            is JsonArray -> ABSSeriesList(element.mapNotNull { one(it) })
            is JsonObject -> ABSSeriesList(listOfNotNull(one(element)))
            else -> ABSSeriesList()
        }
    }

    override fun serialize(encoder: Encoder, value: ABSSeriesList) = list.serialize(encoder, value.all)
}

/**
 * A book or a podcast. Lists (minified) and the expanded item share this shape; the expanded one has more filled in.
 * @property id the library item id: cover, progress and playback use it
 * @property libraryId the library it belongs to
 * @property media chapters, episodes, tracks and the metadata
 */
@Serializable
data class ABSItem(
    val id: String,
    val libraryId: String? = null,
    /** `book` or `podcast`. */
    val mediaType: String? = null,
    val media: Media = Media(),
    /** On the shelves with new episodes: which episode is meant. */
    val recentEpisode: ABSEpisode? = null,
    /** When it came to the server, in milliseconds. */
    val addedAt: Double? = null,
    /** In the list of what's being listened to: when that last happened, in milliseconds. */
    val progressLastUpdate: Double? = null,
) {
    /** The audio part of the item. */
    @Serializable
    data class Media(
        val metadata: Metadata = Metadata(),
        /** Seconds; null on podcasts. */
        val duration: Double? = null,
        val chapters: List<ABSChapter>? = null,
        val episodes: List<ABSEpisode>? = null,
        val numEpisodes: Int? = null,
        val tracks: List<ABSFile>? = null,
    )

    /** Title, people, series and description. */
    @Serializable
    data class Metadata(
        val title: String? = null,
        val subtitle: String? = null,
        val authorName: String? = null,
        /** Podcasts name their author here. */
        val author: String? = null,
        val authors: List<ABSAuthor>? = null,
        val narratorName: String? = null,
        val narrators: List<String>? = null,
        val seriesName: String? = null,
        val series: ABSSeriesList? = null,
        val description: String? = null,
        val publishedYear: String? = null,
    )

    /** Whether this is a podcast (its audio is in [Media.episodes]). */
    val isPodcast: Boolean get() = mediaType == "podcast"

    /** Title, empty when the server sent none. */
    val title: String get() = media.metadata.title ?: ""

    /** Author of a book or of a podcast, empty when unknown. */
    val creator: String get() = media.metadata.authorName ?: media.metadata.author ?: ""

    /** Identifies this entry on a shelf: the same podcast with another new episode is another entry. */
    val shelfKey: String get() = id + "/" + (recentEpisode?.id ?: "")
}

/** How far a user got in a book or an episode. The key is the item id, plus `/episodeId` for podcast episodes. */
@Serializable
data class ABSProgress(
    val libraryItemId: String,
    val episodeId: String? = null,
    /** 0..1 */
    val progress: Double? = null,
    /** Seconds */
    val currentTime: Double? = null,
    val isFinished: Boolean? = null,
    /** Milliseconds */
    val lastUpdate: Double? = null,
    /** Seconds */
    val duration: Double? = null,
) {
    /** The key in the progress map, see [key]. */
    val key: String get() = key(libraryItemId, episodeId)

    companion object {
        /** `itemId` for a book, `itemId/episodeId` for an episode. */
        fun key(item: String, episode: String?): String = if (episode == null) item else "$item/$episode"
    }
}

/**
 * A listening session the server opened for playback (`POST /api/items/{id}/play`).
 * @property id the session id: stream URLs and sync/close calls use it
 * @property libraryItemId the book or podcast
 * @property episodeId the episode, for podcasts
 * @property audioTracks the audio files in order, to play as one timeline
 */
@Serializable
data class ABSSession(
    val id: String,
    val libraryItemId: String,
    val episodeId: String? = null,
    val displayTitle: String? = null,
    val displayAuthor: String? = null,
    /** Seconds of the whole book or episode. */
    val duration: Double = 0.0,
    /** Where to start, in seconds of the whole book. */
    val currentTime: Double = 0.0,
    val chapters: List<ABSChapter>? = null,
    val audioTracks: List<Track> = emptyList(),
) {
    /** Played from files on this phone rather than through the server (ids made by the app start with `local-`). */
    val isLocal: Boolean get() = id.startsWith("local-")

    /** One audio file of the session; stream it from `AudiobookLibrary.trackURL`. */
    @Serializable
    data class Track(
        val index: Int,
        /** Seconds into the whole book at which this file starts. */
        val startOffset: Double = 0.0,
        val duration: Double = 0.0,
        val title: String? = null,
        val contentUrl: String? = null,
        val mimeType: String? = null,
    )
}

/**
 * What a search finds on the server, besides the books themselves.
 * @property items matching books and podcasts
 * @property authors matching authors
 * @property series matching series
 * @property narrators names of matching narrators (filter group `narrators`)
 */
data class ABSSearchResults(
    val items: List<ABSItem> = emptyList(),
    val authors: List<ABSAuthor> = emptyList(),
    val series: List<ABSSeriesRef> = emptyList(),
    val narrators: List<String> = emptyList(),
)

/** A shelf of the overview ("Continue listening", ...). [id] is the server's, [title] its label (see `ABSShelf.localTitle`). */
data class ABSShelf(val id: String, val title: String, val items: List<ABSItem>) {
    companion object {
        /** The shelf of what was started and not finished. */
        const val CONTINUE_LISTENING = "continue-listening"
    }
}

/**
 * A series in the overview, with the book whose cover stands for it.
 * @property library id of the library it is in
 * @property cover item id of the book whose cover stands for it
 * @property count number of books
 */
data class ABSSeriesEntry(
    val id: String,
    val name: String,
    val library: String,
    val cover: String?,
    val count: Int,
)

/** One page of a library listing. */
data class ABSPage(val items: List<ABSItem>, val total: Int)

/** What the server calls a group and a value: `authors`/`narrators`/`series`/`genres`/`tags` and the name or id. */
data class ABSFilter(val group: String, val value: String)

/** An author's page: the author, their books, and their series. */
data class ABSAuthorPage(val author: ABSAuthor, val items: List<ABSItem>, val series: List<ABSSeriesEntry>)

/** A book with a heart. Audiobookshelf has no favorites of its own, so they stay on this phone, per account. */
@Serializable
data class FavoriteBook(val item: ABSItem, /** Milliseconds since 1970. */ val date: Long)

/** An author with a heart, kept the same way. */
@Serializable
data class FavoriteAuthor(val author: ABSAuthor, /** Milliseconds since 1970. */ val date: Long)

/** What the library needs without a connection, and positions the server hasn't heard about yet. */
@Serializable
internal data class SavedBookState(
    val favorites: Map<String, FavoriteBook> = emptyMap(),
    val inProgress: List<ABSItem> = emptyList(),
    val progress: List<ABSProgress> = emptyList(),
    val unsent: List<ABSProgress> = emptyList(),
    val authors: Map<String, FavoriteAuthor> = emptyMap(),
)

// endregion
