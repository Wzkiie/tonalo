package app.tonalo.android.data

import android.content.Context
import java.io.File
import java.security.MessageDigest

/**
 * Library answers saved on the device per account: pages show the last known state at once,
 * and a bad or missing connection shows that instead of an error. Only music metadata is stored –
 * never the request addresses, which carry the login token.
 */
class LibraryCache(context: Context) {
    private val root = File(context.filesDir, "LibraryCache").apply { mkdirs() }

    companion object {
        /** Endpoints worth keeping. Searches, random picks and anything that changes something are left out. */
        private val methods = setOf(
            "getAlbumList2", "getAlbum", "getArtists", "getArtist", "getArtistInfo2",
            "getTopSongs", "getPlaylists", "getPlaylist", "getGenres", "getStarred2", "getInternetRadioStations",
        )

        fun key(method: String, params: List<Pair<String, String>>): String? {
            if (method !in methods) return null
            return (listOf(method) + params.sortedBy { it.first }.map { "${it.first}=${it.second}" }).joinToString("&")
        }
    }

    private fun file(account: String, key: String): File {
        val name = MessageDigest.getInstance("SHA-256").digest(key.toByteArray()).joinToString("") { "%02x".format(it) }
        return File(File(root, account), "$name.json")
    }

    fun load(account: String, key: String): Payload? = runCatching {
        val f = file(account, key)
        if (!f.exists()) return null
        Network.json.decodeFromString(Envelope.serializer(), f.readText()).response
    }.getOrNull()

    /** Accounts that were deleted: a call still in flight must not bring their folder back. */
    private val deleted = HashSet<String>()

    fun save(account: String, key: String, raw: String) {
        runCatching {
            val f = file(account, key)
            // A unique temp name: two saves of the same page must not write into one file
            val tmp = File(f.parentFile, f.name + "." + java.util.UUID.randomUUID() + ".tmp")
            synchronized(deleted) {
                if (account in deleted) return
                f.parentFile?.mkdirs()
                tmp.writeText(raw)
                if (!tmp.renameTo(f)) tmp.delete()
            }
        }
    }

    fun deleteAccount(id: String) {
        synchronized(deleted) {
            deleted += id
            File(root, id).deleteRecursively()
        }
    }

    /** The account (id) is in use again, e.g. after a new login: saving works again. */
    fun reopen(id: String) { synchronized(deleted) { deleted -= id } }
}
