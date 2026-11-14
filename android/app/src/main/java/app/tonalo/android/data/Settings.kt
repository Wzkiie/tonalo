package app.tonalo.android.data

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** How light the background is. Cards and tiles keep their distance from it, whatever is chosen. */
enum class Backdrop { GRAY, BLACK }

/** How round tiles and covers are; group cards and buttons stay round anyway. */
enum class CardShape(val scale: Float) { SHARP(0f), STANDARD(1f), ROUND(2.5f) }

/** Size of the covers in the shelves on the home page. */
enum class CoverSize(val scale: Float) { SMALL(0.85f), STANDARD(1f), LARGE(1.2f) }

/** Sort order of the library. */
enum class LibrarySort { RECENT, PLAYED, NAME, CREATOR }

/** Settings that aren't secrets. Each one is a flow, so screens and the player update when it changes. */
class Settings(context: Context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    private inner class Pref<T>(private val key: String, default: T, private val read: (String) -> T?, private val write: (T) -> String) {
        // runCatching: version 0.1 kept some of these as booleans, which getString can't read
        val flow = MutableStateFlow(runCatching { prefs.getString(key, null) }.getOrNull()?.let(read) ?: default)
        fun set(value: T) { flow.value = value; prefs.edit().putString(key, write(value)).apply() }
    }

    private fun <T : Enum<T>> enumPref(key: String, default: T, values: Array<T>) =
        Pref(key, default, { v -> values.firstOrNull { it.name == v } }, { it.name })
    private fun boolPref(key: String, default: Boolean) = Pref(key, default, { it.toBooleanStrictOrNull() }, { it.toString() })
    private fun intPref(key: String, default: Int) = Pref(key, default, { it.toIntOrNull() }, { it.toString() })
    private fun stringPref(key: String, default: String) = Pref(key, default, { it }, { it })

    private val wifi = enumPref("quality.wifi", AudioQuality.LOSSLESS, AudioQuality.entries.toTypedArray())
    private val mobile = enumPref("quality.mobile", AudioQuality.OPUS128, AudioQuality.entries.toTypedArray())
    private val download = enumPref("quality.download", AudioQuality.LOSSLESS, AudioQuality.entries.toTypedArray())
    private val level = enumPref("leveling", VolumeLeveling.OFF, VolumeLeveling.entries.toTypedArray())
    private val scrobbling = boolPref("scrobble", true)
    private val sync = boolPref("syncQueue", true)
    private val fade = intPref("crossfade", 0)
    private val autoplayPref = boolPref("autoplay", true)
    private val accentPref = stringPref("accent", DEFAULT_ACCENT)
    private val backdropPref = enumPref("backdrop", Backdrop.GRAY, Backdrop.entries.toTypedArray())
    private val tint = boolPref("coverTint", true)
    private val shape = enumPref("cardShape", CardShape.STANDARD, CardShape.entries.toTypedArray())
    private val coverSizePref = enumPref("coverSize", CoverSize.STANDARD, CoverSize.entries.toTypedArray())
    private val startTabPref = intPref("startTab", 0)
    private val lyricsFirstPref = boolPref("lyricsFirst", false)
    private val hiddenRows = stringPref("hiddenHomeRows", "")
    private val librarySortPref = enumPref("library.sort", LibrarySort.RECENT, LibrarySort.entries.toTypedArray())
    private val libraryGridPref = boolPref("library.grid", false)
    private val eqOn = boolPref("eq.enabled", false)
    private val eqPresetPref = stringPref("eq.preset", "flat")
    private val eqCustom = stringPref("eq.custom", "0,0,0,0,0")

    val wifiQuality: StateFlow<AudioQuality> = wifi.flow.asStateFlow()
    val mobileQuality: StateFlow<AudioQuality> = mobile.flow.asStateFlow()
    /** Quality of offline downloads. */
    val downloadQuality: StateFlow<AudioQuality> = download.flow.asStateFlow()
    val leveling: StateFlow<VolumeLeveling> = level.flow.asStateFlow()
    val scrobble: StateFlow<Boolean> = scrobbling.flow.asStateFlow()
    /** Keep the queue on the server, so another device (the TV, the iPhone) can continue where this one stopped. */
    val syncQueue: StateFlow<Boolean> = sync.flow.asStateFlow()
    /** Seconds the songs fade out and in at a change, 0 = off. */
    val crossfade: StateFlow<Int> = fade.flow.asStateFlow()
    /** When an album or playlist ends, keep going with similar songs. */
    val autoplay: StateFlow<Boolean> = autoplayPref.flow.asStateFlow()
    val accent: StateFlow<String> = accentPref.flow.asStateFlow()
    val backdrop: StateFlow<Backdrop> = backdropPref.flow.asStateFlow()
    /** Player, album pages and mini player take their color from the cover. */
    val coverTint: StateFlow<Boolean> = tint.flow.asStateFlow()
    val cardShape: StateFlow<CardShape> = shape.flow.asStateFlow()
    val coverSize: StateFlow<CoverSize> = coverSizePref.flow.asStateFlow()
    /** Which tab the app opens on: 0 Home, 1 Search, 2 Library. */
    val startTab: StateFlow<Int> = startTabPref.flow.asStateFlow()
    /** The player opens on the lyrics. */
    val lyricsFirst: StateFlow<Boolean> = lyricsFirstPref.flow.asStateFlow()
    /** Home page rows switched off, by id (recent, newest, frequent, random, starred), comma separated. */
    val hiddenHomeRows: StateFlow<String> = hiddenRows.flow.asStateFlow()
    val librarySort: StateFlow<LibrarySort> = librarySortPref.flow.asStateFlow()
    val libraryGrid: StateFlow<Boolean> = libraryGridPref.flow.asStateFlow()
    /** The equalizer (playback/Eq.kt): on or off, a preset id or "custom", and the own gains in dB. */
    val eqEnabled: StateFlow<Boolean> = eqOn.flow.asStateFlow()
    val eqPreset: StateFlow<String> = eqPresetPref.flow.asStateFlow()
    val eqCustomGains: StateFlow<String> = eqCustom.flow.asStateFlow()

    fun setWifiQuality(q: AudioQuality) = wifi.set(q)
    fun setMobileQuality(q: AudioQuality) = mobile.set(q)
    fun setDownloadQuality(q: AudioQuality) = download.set(q)
    fun setLeveling(l: VolumeLeveling) = level.set(l)
    fun setScrobble(on: Boolean) = scrobbling.set(on)
    fun setSyncQueue(on: Boolean) = sync.set(on)
    fun setCrossfade(seconds: Int) = fade.set(seconds)
    fun setAutoplay(on: Boolean) = autoplayPref.set(on)
    fun setAccent(hex: String) = accentPref.set(hex)
    fun setBackdrop(b: Backdrop) = backdropPref.set(b)
    fun setCoverTint(on: Boolean) = tint.set(on)
    fun setCardShape(c: CardShape) = shape.set(c)
    fun setCoverSize(c: CoverSize) = coverSizePref.set(c)
    fun setStartTab(t: Int) = startTabPref.set(t)
    fun setLyricsFirst(on: Boolean) = lyricsFirstPref.set(on)
    fun setHomeRowShown(id: String, shown: Boolean) {
        val set = hiddenRows.flow.value.split(",").filter { it.isNotEmpty() }.toMutableSet()
        if (shown) set -= id else set += id
        hiddenRows.set(set.sorted().joinToString(","))
    }
    fun setLibrarySort(s: LibrarySort) = librarySortPref.set(s)
    fun setLibraryGrid(on: Boolean) = libraryGridPref.set(on)
    fun setEqEnabled(on: Boolean) = eqOn.set(on)
    fun setEqPreset(id: String) = eqPresetPref.set(id)
    fun setEqCustom(text: String) = eqCustom.set(text)

    companion object {
        const val DEFAULT_ACCENT = "#5B9DFF"
        val accentPresets = listOf("#5B9DFF", "#9B7BFF", "#FF6FB5", "#FF5A5F", "#FF9F43", "#FFD24A", "#3DDC97", "#2EC4C9")
    }
}
