package app.tonalo.android.data

import android.content.Context
import kotlinx.serialization.builtins.ListSerializer

/**
 * The songs that were found by searching and then played, newest first (at most [MAX]), per account. They are shown
 * when the search field is empty, and rank higher in the results. Only kept on this device, in the app's own storage,
 * and removed together with the account. Nothing here is a login detail.
 */
object SearchPlays {
    private const val MAX = 12
    private val serializer = ListSerializer(Song.serializer())

    private fun prefs(context: Context) = context.getSharedPreferences("searchplays", Context.MODE_PRIVATE)

    fun load(context: Context, account: String?): List<Song> =
        account?.let { prefs(context).getString(it, null) }
            ?.let { runCatching { Network.json.decodeFromString(serializer, it) }.getOrNull() }.orEmpty()

    private fun save(context: Context, account: String?, list: List<Song>): List<Song> {
        if (account != null) prefs(context).edit().putString(account, Network.json.encodeToString(serializer, list)).apply()
        return list
    }

    /** A song that was played from the search goes to the top. */
    fun remember(context: Context, account: String?, song: Song): List<Song> =
        save(context, account, (listOf(song) + load(context, account).filter { it.id != song.id }).take(MAX))

    fun clear(context: Context, account: String?): List<Song> = save(context, account, emptyList())

    fun deleteAccount(context: Context, id: String) { prefs(context).edit().remove(id).apply() }
}
