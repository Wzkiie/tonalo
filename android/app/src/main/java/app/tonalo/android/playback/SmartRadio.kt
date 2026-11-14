package app.tonalo.android.playback

import app.tonalo.android.data.Song
import app.tonalo.android.data.SubsonicClient

/**
 * Radio that keeps going: when the queue runs low it adds songs like the ones played to the end or
 * given a heart, and fewer of the artists that get skipped. Without Last.fm on the server it stays in
 * the genre instead. What it learns is kept only while the app runs. Same rules as the iPhone app.
 */
class SmartRadio(private val client: () -> SubsonicClient?, private val queued: () -> List<Song>) {
    /** Songs the radio is based on, newest last. */
    private var seeds = mutableListOf<Song>()
    /** A genre radio stays in its genre. */
    private var genre: String? = null
    /** Skipped songs per artist: one skip plays them later, two leave them out. */
    private val skips = mutableMapOf<String, Int>()
    /** Everything the radio already played or queued – nothing comes twice. */
    private val seen = mutableSetOf<String>()
    /** The server found no similar songs (no Last.fm): don't keep asking. */
    private var noSimilar = false

    /** First songs of a radio from a song or artist (`seedId`), from a few songs, or from a genre. */
    suspend fun start(seedId: String? = null, seeds: List<Song> = emptyList(), genre: String? = null, first: Song? = null): List<Song> {
        val c = client() ?: return emptyList()
        this.seeds = (listOfNotNull(first) + seeds).toMutableList()
        this.genre = genre
        skips.clear()
        seen.clear()
        seen += this.seeds.map { it.id }
        noSimilar = false
        var songs = mutableListOf<Song>()
        if (seedId != null) {
            val similar = c.similarSongs(seedId)
            noSimilar = similar.isEmpty()
            songs += fresh(similar)
        }
        if (songs.size < 10) songs += candidates(25 - songs.size)
        songs = (listOfNotNull(first) + songs.filter { it.id != first?.id }).toMutableList()
        seen += songs.map { it.id }
        return songs
    }

    /** The queue ended: keep playing with songs like the last ones (autoplay). */
    suspend fun continueAfter(queue: List<Song>): List<Song> {
        seeds = queue.takeLast(5).toMutableList()
        genre = null
        noSimilar = false
        seen.clear()
        seen += queue.map { it.id }
        return candidates(15).also { s -> seen += s.map { it.id } }
    }

    suspend fun more(): List<Song> = candidates(15).also { s -> seen += s.map { it.id } }

    fun listened(song: Song) = remember(song)

    /** A heart counts more than just listening: it may be picked as the starting point twice as often. */
    fun liked(song: Song) { remember(song); remember(song, again = true) }

    fun skipped(song: Song) {
        song.artist?.let { skips[it] = (skips[it] ?: 0) + 1 }
        seeds.removeAll { it.id == song.id }
    }

    private fun remember(song: Song, again: Boolean = false) {
        if (!again) seeds.removeAll { it.id == song.id }
        seeds += song
        if (seeds.size > 20) seeds = seeds.takeLast(20).toMutableList()
    }

    /** Similar songs to one of the recent favorites, or – without Last.fm, and for a genre radio – songs of the same genre. */
    private suspend fun candidates(count: Int): List<Song> {
        val c = client() ?: return emptyList()
        val seed = seeds.takeLast(5).randomOrNull()
        val pool = mutableListOf<Song>()
        if (genre == null && !noSimilar && seed != null) {
            val similar = c.similarSongs(seed.id)
            noSimilar = similar.isEmpty()
            pool += fresh(similar)
        }
        if (pool.size < count) {
            val g = genre ?: seed?.genre
            pool += fresh(runCatching { c.randomSongs(60, genre = g) }.getOrDefault(emptyList()))
            if (pool.size < count && g != null && genre == null) pool += fresh(runCatching { c.randomSongs(40) }.getOrDefault(emptyList()))
        }
        // Skipped artists to the back (or out), and at most two songs per artist in one go
        val perArtist = mutableMapOf<String, Int>()
        val ids = mutableSetOf<String>()
        val picked = mutableListOf<Song>()
        for (song in pool.shuffled().sortedBy { skipCount(it) }) {
            if (skipCount(song) >= 2 || song.id in ids) continue
            val artist = song.artist ?: ""
            if ((perArtist[artist] ?: 0) >= 2) continue
            perArtist[artist] = (perArtist[artist] ?: 0) + 1
            ids += song.id
            picked += song
            if (picked.size == count) break
        }
        return spreadOut(picked)
    }

    private fun skipCount(song: Song) = song.artist?.let { skips[it] } ?: 0

    private fun fresh(songs: List<Song>): List<Song> {
        val q = queued().map { it.id }.toSet()
        return songs.filter { it.id !in seen && it.id !in q }
    }

    /** Two songs of the same artist shouldn't follow each other. */
    private fun spreadOut(songs: List<Song>): List<Song> {
        val rest = songs.toMutableList()
        val out = mutableListOf<Song>()
        while (rest.isNotEmpty()) {
            val i = rest.indexOfFirst { it.artist != out.lastOrNull()?.artist }.takeIf { it >= 0 } ?: 0
            out += rest.removeAt(i)
        }
        return out
    }
}
