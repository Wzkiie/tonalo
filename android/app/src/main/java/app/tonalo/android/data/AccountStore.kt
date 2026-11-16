package app.tonalo.android.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import kotlinx.serialization.builtins.ListSerializer
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Accounts are kept as one JSON list, encrypted with AES-GCM under a key in the Android Keystore –
 * token and header values are secrets. The key never leaves the device's secure hardware,
 * and backups are switched off in the manifest, so the file is useless anywhere else.
 */
class AccountStore(context: Context) {
    private val prefs = context.getSharedPreferences("accounts", Context.MODE_PRIVATE)
    private val serializer = ListSerializer(Account.serializer())

    companion object {
        private const val KEY_ALIAS = "tonalo.accounts"
        private const val DATA = "data"
        private const val BACKUP = "data.unreadable"
        private const val SELECTED = "selected"
    }

    /** Synchronized: two threads generating the key at once would leave data sealed with a key that was replaced. */
    @Synchronized
    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    fun load(): List<Account> {
        val stored = prefs.getString(DATA, null) ?: return emptyList()
        val decoded = loadSecret(DATA)?.let { runCatching { Network.json.decodeFromString(serializer, it) }.getOrNull() }
        if (decoded != null) return decoded
        // Data exists but can't be read (keystore key lost, damaged file): keep the old blob before a new login overwrites it
        android.util.Log.e("AccountStore", "Saved accounts could not be decrypted or decoded; keeping the old data as $BACKUP")
        if (!prefs.contains(BACKUP)) prefs.edit().putString(BACKUP, stored).commit()
        return emptyList()
    }

    fun save(accounts: List<Account>): Boolean = saveSecret(DATA, Network.json.encodeToString(serializer, accounts))

    /** Any other secret (pairing keys of TVs and Jukebox guests), encrypted the same way. */
    fun loadSecret(name: String): String? {
        val stored = prefs.getString(name, null) ?: return null
        return runCatching {
            val bytes = Base64.decode(stored, Base64.NO_WRAP)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
            cipher.doFinal(bytes, 12, bytes.size - 12).decodeToString()
        }.getOrNull()
    }

    fun saveSecret(name: String, value: String?): Boolean = runCatching {
        if (value == null) return@runCatching prefs.edit().remove(name).commit()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val sealed = cipher.iv + cipher.doFinal(value.toByteArray())
        prefs.edit().putString(name, Base64.encodeToString(sealed, Base64.NO_WRAP)).commit()
    }.getOrDefault(false)

    var selectedId: String?
        get() = prefs.getString(SELECTED, null)
        set(value) { prefs.edit().putString(SELECTED, value).apply() }
}
