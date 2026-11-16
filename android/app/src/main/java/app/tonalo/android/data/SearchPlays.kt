package app.tonalo.android.data

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer

/**
 * What was found by searching and then opened: a song that was played, or an artist whose page was opened. Newest
 * first (at most [MAX]), per account. They are shown when the search field is empty, and the songs rank higher in the
 * results. Only kept on this device, in the app's own storage, and removed together with the account. Nothing here is
 * a login detail.
 */
object SearchPlays {
    private const val MAX = 12

    /** One entry: exactly one of the two is set. */
    @Serializable
    data class Recent(val song: Song? = null, val artist: Artist? = null) {
        val key: String get() = song?.let { "s" + it.id } ?: artist?.let { "r" + it.id } ?: ""
    }

    private val serializer = ListSerializer(Recent.serializer())
    private val legacy = ListSerializer(Song.serializer())

    private fun prefs(context: Context) = context.getSharedPreferences("searchplays", Context.MODE_PRIVATE)

    fun load(context: Context, account: String?): List<Recent> {
        val text = account?.let { prefs(context).getString(it, null) } ?: return emptyList()
        // Songs only, as it was kept before artists were added
        return runCatching { Network.json.decodeFromString(serializer, text) }.getOrNull()
            ?: runCatching { Network.json.decodeFromString(legacy, text).map { Recent(song = it) } }.getOrNull().orEmpty()
    }

    private fun save(context: Context, account: String?, list: List<Recent>): List<Recent> {
        if (account != null) prefs(context).edit().putString(account, Network.json.encodeToString(serializer, list)).apply()
        return list
    }

    private fun top(context: Context, account: String?, entry: Recent): List<Recent> =
        save(context, account, (listOf(entry) + load(context, account).filter { it.key != entry.key }).take(MAX))

    /** A song that was played from the search goes to the top. */
    fun remember(context: Context, account: String?, song: Song): List<Recent> = top(context, account, Recent(song = song))

    /** An artist whose page was opened from the search goes to the top. */
    fun remember(context: Context, account: String?, artist: Artist): List<Recent> = top(context, account, Recent(artist = artist))

    fun clear(context: Context, account: String?): List<Recent> = save(context, account, emptyList())

    fun deleteAccount(context: Context, id: String) { prefs(context).edit().remove(id).apply() }
}
