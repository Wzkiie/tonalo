package app.tonalo.android.data

import android.content.Context
import kotlinx.serialization.Serializable

/** The queue saved on the device per account, so it survives the app being closed. */
@Serializable
data class SavedQueue(val songs: List<Song>, val index: Int, val positionMs: Long)

class QueueStore(context: Context) {
    private val prefs = context.getSharedPreferences("queue", Context.MODE_PRIVATE)

    fun load(account: String): SavedQueue? = runCatching {
        prefs.getString(account, null)?.let { Network.json.decodeFromString(SavedQueue.serializer(), it) }
    }.getOrNull()?.takeIf { it.songs.isNotEmpty() }

    fun save(account: String, queue: SavedQueue) {
        prefs.edit().putString(account, Network.json.encodeToString(SavedQueue.serializer(), queue)).apply()
    }

    fun delete(account: String) { prefs.edit().remove(account).apply() }
}
