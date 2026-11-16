package app.tonalo.android.data

import android.content.Context

/**
 * The searches of an account, newest first (at most [MAX]). Only kept on this device, in the app's own storage, and
 * removed together with the account. Nothing here is a login detail: just the words that were typed.
 */
object RecentSearches {
    private const val MAX = 10

    private fun prefs(context: Context) = context.getSharedPreferences("recentsearches", Context.MODE_PRIVATE)

    fun load(context: Context, account: String?): List<String> =
        account?.let { prefs(context).getString(it, null) }?.split('\n')?.filter { it.isNotBlank() }.orEmpty()

    private fun save(context: Context, account: String?, list: List<String>): List<String> {
        if (account != null) prefs(context).edit().putString(account, list.joinToString("\n")).apply()
        return list
    }

    /** Saves a search at the top. Typing on from the newest one replaces it, so "nin" and "nine inch" don't both stay. */
    fun remember(context: Context, account: String?, text: String): List<String> {
        val t = text.trim().replace('\n', ' ')
        val list = load(context, account).toMutableList()
        if (t.length < 2) return list
        if (list.firstOrNull()?.let { t.lowercase().startsWith(it.lowercase()) } == true) list.removeAt(0)
        list.removeAll { it.equals(t, ignoreCase = true) }
        list.add(0, t)
        return save(context, account, list.take(MAX))
    }

    /** One search, or all of them with `null`. */
    fun forget(context: Context, account: String?, text: String?): List<String> =
        save(context, account, if (text == null) emptyList() else load(context, account).filter { it != text })

    fun deleteAccount(context: Context, id: String) { prefs(context).edit().remove(id).apply() }
}
