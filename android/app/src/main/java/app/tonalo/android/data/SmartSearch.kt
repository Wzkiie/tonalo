package app.tonalo.android.data

import java.text.Normalizer
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope

/**
 * Text matching that forgives typos: "silvr wether" finds "Silver Weather", "Beyonse" finds "Beyoncé".
 * Everything is compared in a plain form (lower case, no accents, no punctuation).
 */
object Fuzzy {
    fun norm(s: String): String =
        Normalizer.normalize(s, Normalizer.Form.NFD).replace(Regex("\\p{M}+"), "")
            .lowercase().replace(Regex("[^\\p{L}\\p{N}]+"), " ").trim()

    fun tokens(normalized: String): List<String> = normalized.split(' ').filter { it.isNotEmpty() }

    /** Edit distance with swapped neighbours counting as one change ("teh" -> "the"). */
    fun distance(a: String, b: String): Int {
        if (a == b) return 0
        if (a.isEmpty()) return b.length
        if (b.isEmpty()) return a.length
        var prev2 = IntArray(b.length + 1)
        var prev = IntArray(b.length + 1) { it }
        var cur = IntArray(b.length + 1)
        for (i in 1..a.length) {
            cur[0] = i
            for (j in 1..b.length) {
                val cost = if (a[i - 1] == b[j - 1]) 0 else 1
                var v = min(min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost)
                if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) v = min(v, prev2[j - 2] + 1)
                cur[j] = v
            }
            val t = prev2; prev2 = prev; prev = cur; cur = t
        }
        return prev[b.length]
    }

    /** How many typos a word of this length may have: none in short words, one in medium, two in long ones. */
    private fun allowed(len: Int) = when { len <= 3 -> 0; len <= 6 -> 1; else -> 2 }

    /** 0 (no match) to 1 (same) for one typed word against one word of the text; also against its beginning, for words still being typed. */
    private fun wordSimilarity(q: String, t: String): Double {
        if (q == t) return 1.0
        val tol = allowed(q.length)
        var best = 0.0
        val d = distance(q, t)
        if (d <= tol || (tol == 0 && d <= 0)) best = 1.0 - d.toDouble() / max(q.length, t.length)
        if (t.length > q.length) {
            if (t.startsWith(q)) best = max(best, 0.95)
            else {
                val dp = distance(q, t.substring(0, q.length))
                if (dp <= tol) best = max(best, 0.9 * (1.0 - dp.toDouble() / q.length))
            }
        }
        return best
    }

    /** 0 to 100: how well [text] fits what was typed ([query] already in plain form). */
    fun score(query: String, text: String): Double {
        val nt = norm(text)
        if (query.isEmpty() || nt.isEmpty()) return 0.0
        if (nt == query) return 100.0
        if (nt.startsWith(query)) return 92.0
        if (" $nt".contains(" $query")) return 85.0
        if (nt.contains(query)) return 72.0
        val qt = tokens(query)
        val tt = tokens(nt)
        if (qt.isEmpty() || tt.isEmpty()) return 0.0
        var sum = 0.0
        for (q in qt) sum += tt.maxOf { wordSimilarity(q, it) }
        return 70.0 * sum / qt.size
    }
}

/** What the phone knows about the person's taste, to put the songs they like and know further up. */
class SearchSignals(
    /** When albums, artists and playlists were last played on this phone ("a…", "r…", "p…" ids, see PlayHistory). */
    val played: Map<String, Long> = emptyMap(),
    /** Songs that were searched for and then played, newest first. */
    val searchPlays: List<Song> = emptyList(),
)

class SmartResult(val body: SearchBody, val similarOnly: Boolean)

/** Artists and favorites of an account, kept for a few minutes: they are the pool that typo-tolerant matching looks through. */
internal object SearchPool {
    private class Entry(val at: Long, val artists: List<Artist>, val starred: SearchBody)
    private val entries = HashMap<String, Entry>()
    private const val TTL = 10 * 60 * 1000L

    suspend fun get(client: SubsonicClient): Pair<List<Artist>, SearchBody> {
        val id = client.account.id
        synchronized(entries) { entries[id]?.takeIf { System.currentTimeMillis() - it.at < TTL } }?.let { return it.artists to it.starred }
        // The calls fall back to the saved answers by themselves when there is no connection
        val artists = runCatching { client.artists() }.getOrElse { if (it is CancellationException) throw it else emptyList() }
        val starred = runCatching { client.starred() }.getOrElse { if (it is CancellationException) throw it else SearchBody() }
        if (artists.isNotEmpty() || starred.song.orEmpty().isNotEmpty()) synchronized(entries) { entries[id] = Entry(System.currentTimeMillis(), artists, starred) }
        return artists to starred
    }

    fun forget(account: String) { synchronized(entries) { entries.remove(account) } }
}

private const val MIN_SCORE = 40.0
/** What is shown when nothing reaches [MIN_SCORE]: the closest few, so a search is never empty. */
private const val CLOSEST = 8

/**
 * Searches the server, and also finds what is spelled a little differently:
 * - the server's own matches are kept,
 * - shorter forms of the words are asked as well ("silvr" asks for "silv"), and everything is ranked by how close it is,
 * - the artists, the favorites and the songs played from the search are matched on the phone,
 * - songs that are favorites or that were heard before move up, so do the albums and artists played lately.
 */
suspend fun SubsonicClient.smartSearch(query: String, signals: SearchSignals): SmartResult = coroutineScope {
    val q = Fuzzy.norm(query)
    val exact = async { runCatching { search(query) }.getOrElse { if (it is CancellationException) throw it else SearchBody() } }
    val pool = async { SearchPool.get(this@smartSearch) }
    val serverHits = exact.await()
    val serverTotal = serverHits.artist.orEmpty().size + serverHits.album.orEmpty().size + serverHits.song.orEmpty().size

    // Spelled differently: ask for shorter forms, which the server can match as a part of a word
    val extra = if (serverTotal >= 12 || q.length < 3) SearchBody() else {
        val variants = LinkedHashSet<String>()
        val words = Fuzzy.tokens(q)
        if (q.length > 3) variants += q.dropLast(1)
        for (w in words) {
            if (w.length >= 4) variants += w.dropLast(1)
            if (w.length >= 4) variants += w.take(3)
        }
        variants.remove(q)
        variants.filter { it.length >= 3 }.take(5).map { v ->
            async { runCatching { search3Small(v) }.getOrElse { if (it is CancellationException) throw it else SearchBody() } }
        }.awaitAll().fold(SearchBody()) { acc, b ->
            SearchBody(acc.artist.orEmpty() + b.artist.orEmpty(), acc.album.orEmpty() + b.album.orEmpty(), acc.song.orEmpty() + b.song.orEmpty())
        }
    }
    val (poolArtists, favorites) = pool.await()

    val serverSongIds = serverHits.song.orEmpty().map { it.id }.toHashSet()
    val serverAlbumIds = serverHits.album.orEmpty().map { it.id }.toHashSet()
    val serverArtistIds = serverHits.artist.orEmpty().map { it.id }.toHashSet()

    fun heard(song: Song) = if ((song.playCount ?: 0) > 0) min(15.0, ln(1.0 + (song.playCount ?: 0)) * 5.0) else 0.0
    val searchPlayIds = signals.searchPlays.map { it.id }.toHashSet()
    val favoriteSongIds = favorites.song.orEmpty().map { it.id }.toHashSet()

    // Songs
    val songCandidates = (serverHits.song.orEmpty() + extra.song.orEmpty() + favorites.song.orEmpty() + signals.searchPlays)
        .distinctBy { it.id }
    val songs = songCandidates.mapNotNull { s ->
        var base = max(Fuzzy.score(q, s.title), 0.95 * Fuzzy.score(q, listOfNotNull(s.title, s.artist).joinToString(" ")))
        // The server found it (maybe through the artist or the album): at least a fair match
        if (s.id in serverSongIds) base = max(base, 55.0)
        if (base < MIN_SCORE) return@mapNotNull null
        val boost = (if (s.starred != null || s.id in favoriteSongIds) 12.0 else 0.0) + heard(s) + (if (s.id in searchPlayIds) 10.0 else 0.0)
        s to base + boost
    }.sortedByDescending { it.second }.map { it.first }.take(40)

    // Albums
    val albumCandidates = (serverHits.album.orEmpty() + extra.album.orEmpty() + favorites.album.orEmpty()).distinctBy { it.id }
    val albums = albumCandidates.mapNotNull { a ->
        var base = max(Fuzzy.score(q, a.name), 0.95 * Fuzzy.score(q, listOfNotNull(a.name, a.artist).joinToString(" ")))
        if (a.id in serverAlbumIds) base = max(base, 55.0)
        if (base < MIN_SCORE) return@mapNotNull null
        val boost = (if (a.starred != null) 12.0 else 0.0) + (if (signals.played.containsKey("a" + a.id)) 8.0 else 0.0)
        a to base + boost
    }.sortedByDescending { it.second }.map { it.first }.take(20)

    // Artists: the whole artist list is matched, so a misspelled name still finds the artist
    val artistCandidates = (serverHits.artist.orEmpty() + extra.artist.orEmpty() + poolArtists + favorites.artist.orEmpty()).distinctBy { it.id }
    val artists = artistCandidates.mapNotNull { r ->
        var base = Fuzzy.score(q, r.name)
        if (r.id in serverArtistIds) base = max(base, 55.0)
        if (base < MIN_SCORE) return@mapNotNull null
        val boost = (if (r.starred != null) 12.0 else 0.0) + (if (signals.played.containsKey("r" + r.id)) 8.0 else 0.0)
        r to base + boost
    }.sortedByDescending { it.second }.map { it.first }.take(10)

    if (songs.isNotEmpty() || albums.isNotEmpty() || artists.isNotEmpty()) {
        return@coroutineScope SmartResult(SearchBody(artists, albums, songs), similarOnly = serverTotal == 0)
    }
    // Nothing is close: the nearest few are better than an empty page
    val nearSongs = songCandidates.map { it to max(Fuzzy.score(q, it.title), Fuzzy.score(q, it.artist.orEmpty())) }
    val nearArtists = artistCandidates.map { it to Fuzzy.score(q, it.name) }
    val nearAlbums = albumCandidates.map { it to Fuzzy.score(q, it.name) }
    val best = (nearSongs.map { it.second } + nearArtists.map { it.second } + nearAlbums.map { it.second }).maxOrNull() ?: 0.0
    if (best <= 0.0) return@coroutineScope SmartResult(SearchBody(), similarOnly = false)
    SmartResult(
        SearchBody(
            nearArtists.sortedByDescending { it.second }.filter { it.second > 0 }.take(3).map { it.first },
            nearAlbums.sortedByDescending { it.second }.filter { it.second > 0 }.take(3).map { it.first },
            nearSongs.sortedByDescending { it.second }.filter { it.second > 0 }.take(CLOSEST).map { it.first },
        ),
        similarOnly = true,
    )
}

/** A smaller search for the shortened forms of what was typed. */
private suspend fun SubsonicClient.search3Small(query: String): SearchBody =
    call("search3", "query" to query, "artistCount" to "5", "albumCount" to "10", "songCount" to "20").searchResult3 ?: SearchBody()
