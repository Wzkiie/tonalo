package app.tonalo.android.playback

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import app.tonalo.android.data.SubsonicClient
import app.tonalo.android.tonalo
import okhttp3.Request
import java.io.File
import java.io.FileNotFoundException

/**
 * Covers for the car, the notification and the lock screen, as `content://` addresses.
 *
 * Android Auto only shows artwork it can open through a content provider – a web address is ignored. It also keeps
 * the server's login (token and salt in the cover's web address) away from every app that connects to the media
 * session: they only ever see `content://app.tonalo.android.covers/<account>/<size>/<cover id>`.
 * The provider serves nothing but cover images, and only of signed-in accounts.
 */
class Covers : ContentProvider() {

    override fun onCreate() = true

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("Covers are read-only")
        val (accountId, size, id) = uri.pathSegments.takeIf { it.size == 3 }?.let { Triple(it[0], it[1].toIntOrNull(), it[2]) }
            ?: throw FileNotFoundException(uri.toString())
        if (size == null || size !in 32..1200 || id.isBlank()) throw FileNotFoundException(uri.toString())
        val app = context?.tonalo ?: throw FileNotFoundException(uri.toString())
        val account = app.accountList.value.firstOrNull { it.id == accountId } ?: throw FileNotFoundException(uri.toString())

        val dir = File(app.cacheDir, "covers/$accountId").apply { mkdirs() }
        // The id comes from the server; the file name is only its hash, so it can't point anywhere else
        val name = java.security.MessageDigest.getInstance("SHA-1").digest("$id@$size".toByteArray()).joinToString("") { "%02x".format(it) }
        val file = File(dir, "$name.img")
        if (!file.exists() || file.length() == 0L) {
            val atHome = app.current.value?.id == accountId && app.atHome.value
            val url = SubsonicClient(account, atHome = atHome).coverURL(id, size) ?: throw FileNotFoundException(uri.toString())
            // Blocking is fine here: content providers are called on a binder thread, not the main thread
            app.mediaHttp.newCall(Request.Builder().url(url).build()).execute().use { r ->
                val body = r.body
                if (!r.isSuccessful || body == null || r.header("Content-Type")?.startsWith("image") != true) {
                    throw FileNotFoundException(uri.toString())
                }
                val tmp = File.createTempFile(file.name, ".part", dir)
                try {
                    if (r.header("Content-Type")?.contains("svg") == true) {
                        // The car, the lock screen and the notification can't draw SVG: drawn once into a PNG here
                        val png = runCatching { svgToPng(body.byteStream(), size) }.getOrNull() ?: throw FileNotFoundException(uri.toString())
                        tmp.writeBytes(png)
                    } else {
                        tmp.outputStream().use { out -> body.byteStream().copyTo(out) }
                    }
                } catch (e: Exception) {
                    // A broken SVG or a dropped connection: no half file stays behind (trim only removes finished ones)
                    tmp.delete()
                    throw e
                }
                if (!tmp.renameTo(file)) tmp.delete()
            }
            trim(dir)
        }
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    private fun svgToPng(input: java.io.InputStream, size: Int): ByteArray {
        val svg = com.caverock.androidsvg.SVG.getFromInputStream(input)
        svg.documentWidth = size.toFloat()
        svg.documentHeight = size.toFloat()
        val bitmap = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
        svg.renderToCanvas(android.graphics.Canvas(bitmap))
        return java.io.ByteArrayOutputStream().use { out ->
            bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out)
            bitmap.recycle()
            out.toByteArray()
        }
    }

    /** Keeps the newest few hundred covers per account. */
    private fun trim(dir: File) {
        val files = dir.listFiles()?.filter { it.name.endsWith(".img") } ?: return
        if (files.size <= 400) return
        files.sortedBy { it.lastModified() }.take(files.size - 300).forEach { it.delete() }
    }

    override fun getType(uri: Uri): String = "image/*"
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, args: Array<out String>?, sort: String?): Cursor? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, args: Array<out String>?) = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, args: Array<out String>?) = 0

    companion object {
        const val AUTHORITY = "app.tonalo.android.covers"

        fun uri(accountId: String?, coverId: String?, size: Int = 300): Uri? {
            if (accountId.isNullOrEmpty() || coverId.isNullOrEmpty()) return null
            return Uri.Builder().scheme("content").authority(AUTHORITY)
                .appendPath(accountId).appendPath(size.toString()).appendPath(coverId).build()
        }
    }
}
