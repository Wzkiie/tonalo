package app.tonalo.android.playback

import android.media.audiofx.Equalizer
import kotlin.math.abs
import kotlin.math.ln

/**
 * The equalizer: five bands at fixed frequencies, a few presets, gains in dB. The phone's own equalizer
 * (android.media.audiofx) may have other bands – each of its bands takes the gain of the nearest of ours
 * (on a log scale, the way ears hear it), clamped to what the phone allows.
 */
object Eq {
    /** Center frequencies of our five bands, in Hz. */
    val frequencies = listOf(60, 230, 910, 3600, 14000)
    const val MAX_DB = 12f

    /** Presets by id, gains in dB for the five bands. */
    val presets: List<Pair<String, List<Float>>> = listOf(
        "flat" to listOf(0f, 0f, 0f, 0f, 0f),
        "bass" to listOf(6f, 4f, 0f, 0f, 0f),
        "treble" to listOf(0f, 0f, 0f, 3f, 6f),
        "vocal" to listOf(-2f, -1f, 3f, 4f, 1f),
        "rock" to listOf(5f, 2f, -2f, 2f, 5f),
        "pop" to listOf(-1f, 2f, 4f, 2f, -1f),
        "jazz" to listOf(3f, 1f, -1f, 2f, 4f),
        "electronic" to listOf(5f, 3f, 0f, 2f, 5f),
        "loudness" to listOf(6f, 2f, -1f, 2f, 5f),
    )

    fun gains(preset: String, custom: List<Float>): List<Float> = presets.firstOrNull { it.first == preset }?.second ?: custom

    fun parse(text: String): List<Float> =
        text.split(",").mapNotNull { it.toFloatOrNull() }.takeIf { it.size == frequencies.size }?.map { it.coerceIn(-MAX_DB, MAX_DB) }
            ?: List(frequencies.size) { 0f }

    fun format(gains: List<Float>) = gains.joinToString(",") { "%.1f".format(java.util.Locale.ROOT, it) }

    /** Sets the phone's equalizer to our gains. */
    fun apply(eq: Equalizer, enabled: Boolean, gains: List<Float>) {
        val (min, max) = eq.bandLevelRange.let { it[0] to it[1] } // millibel
        for (band in 0 until eq.numberOfBands) {
            val center = eq.getCenterFreq(band.toShort()) / 1000.0 // milliHertz → Hz
            val nearest = frequencies.indices.minBy { abs(ln(frequencies[it].toDouble()) - ln(center.coerceAtLeast(1.0))) }
            val level = (gains[nearest] * 100).toInt().coerceIn(min.toInt(), max.toInt())
            eq.setBandLevel(band.toShort(), level.toShort())
        }
        eq.enabled = enabled
    }
}
