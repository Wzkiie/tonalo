package app.tonalo.android.data

import android.content.Context
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer

@Serializable
data class PendingScrobble(val id: String, val timeMillis: Long)

/**
 * Plays that couldn't be reported (no connection, offline downloads on a plane …), per account.
 * They are sent with their original time once the server answers again.
 */
class ScrobbleQueue(context: Context) {
    private val prefs = context.getSharedPreferences("scrobbles", Context.MODE_PRIVATE)
    private val serializer = ListSerializer(PendingScrobble.serializer())

    @Synchronized
    fun pending(account: String): List<PendingScrobble> = runCatching {
        prefs.getString(account, null)?.let { Network.json.decodeFromString(serializer, it) }
    }.getOrNull().orEmpty()

    @Synchronized
    private fun save(account: String, list: List<PendingScrobble>) {
        prefs.edit().apply { if (list.isEmpty()) remove(account) else putString(account, Network.json.encodeToString(serializer, list.takeLast(500))) }.apply()
    }

    @Synchronized
    fun add(account: String, scrobble: PendingScrobble) = save(account, pending(account) + scrobble)

    /** Sends what's waiting, oldest first; stops at the first failure and keeps the rest. */
    suspend fun flush(client: SubsonicClient) = flushing.withLock {
        val account = client.account.id
        while (true) {
            val s = pending(account).firstOrNull() ?: break
            if (!client.scrobble(s.id, submission = true, timeMillis = s.timeMillis)) break
            sent(account, s)
        }
    }

    /** Two flushes at once would send the same scrobbles twice. */
    private val flushing = kotlinx.coroutines.sync.Mutex()

    @Synchronized
    private fun sent(account: String, s: PendingScrobble) {
        val list = pending(account).toMutableList()
        list.remove(s)
        save(account, list)
    }

    fun delete(account: String) = save(account, emptyList())
}
