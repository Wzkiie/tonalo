package app.tonalo.android.data

import android.content.Context

/**
 * When an album, artist or playlist was last played on this phone, per account – for sorting the library by
 * "Recently played", like the iPhone's PlayHistory. Ids carry their kind: "a…" album, "r…" artist, "p…" playlist.
 */
class PlayHistory(context: Context) {
    private val prefs = context.getSharedPreferences("history", Context.MODE_PRIVATE)

    fun note(account: String, vararg ids: String?) {
        val now = System.currentTimeMillis() / 1000
        prefs.edit().apply { ids.filterNotNull().forEach { putLong("$account|$it", now) } }.apply()
    }

    fun dates(account: String?): Map<String, Long> {
        if (account == null) return emptyMap()
        val prefix = "$account|"
        return prefs.all.mapNotNull { (k, v) -> if (k.startsWith(prefix) && v is Long) k.removePrefix(prefix) to v else null }.toMap()
    }

    fun delete(account: String) {
        prefs.edit().apply { prefs.all.keys.filter { it.startsWith("$account|") }.forEach { remove(it) } }.apply()
    }
}
