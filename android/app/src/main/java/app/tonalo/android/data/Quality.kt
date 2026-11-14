package app.tonalo.android.data

import kotlin.math.min
import kotlin.math.max
import kotlin.math.pow

/** Volume leveling with ReplayGain: per song, or per album so quiet and loud tracks of one album keep their difference. */
enum class VolumeLeveling {
    OFF, TRACK, ALBUM;

    /** Volume factor for a song (the player can only turn down, so louder than 1 isn't possible). */
    fun factor(song: Song?): Float {
        val rg = song?.replayGain
        if (this == OFF || rg == null) return 1f
        val gain = if (this == ALBUM) rg.albumGain?.takeIf { it != 0.0 } ?: rg.trackGain else rg.trackGain ?: rg.albumGain
        val peak = if (this == ALBUM) rg.albumPeak ?: rg.trackPeak else rg.trackPeak ?: rg.albumPeak
        if (gain == null || gain == 0.0) return 1f
        var f = 10.0.pow(gain / 20)
        if (peak != null && peak > 0) f = min(f, 1 / peak) // never clip
        return min(max(f, 0.05), 1.0).toFloat()
    }
}

/**
 * Audio quality for streaming. "Original" sends the files as they are (FLAC stays FLAC);
 * everything else is converted by the server. Navidrome converts to AAC, Opus and MP3.
 */
enum class AudioQuality(val codec: Codec, val bitRate: Int) {
    LOSSLESS(Codec.ORIGINAL, 0),
    AAC256(Codec.AAC, 256), AAC192(Codec.AAC, 192), AAC128(Codec.AAC, 128), AAC96(Codec.AAC, 96),
    OPUS192(Codec.OPUS, 192), OPUS128(Codec.OPUS, 128), OPUS96(Codec.OPUS, 96),
    MP3320(Codec.MP3, 320), MP3192(Codec.MP3, 192), MP3128(Codec.MP3, 128);

    enum class Codec(val label: String) { ORIGINAL("Original"), AAC("AAC"), OPUS("Opus"), MP3("MP3") }

    /** Server format, null = original file */
    val format: String? get() = if (codec == Codec.ORIGINAL) null else codec.name.lowercase()

    val title: String get() = if (codec == Codec.ORIGINAL) codec.label else "${codec.label} $bitRate kbit/s"

    /** The quality actually used for a song: lossless only works for files Android plays itself. */
    fun resolved(song: Song): AudioQuality {
        if (this != LOSSLESS) return this
        return if ((song.suffix ?: "").lowercase() in playable) LOSSLESS else OPUS192
    }

    /** Short label for the player, e.g. "FLAC" or "AAC 256". */
    fun label(song: Song): String {
        val q = resolved(song)
        if (q.codec != Codec.ORIGINAL) return "${q.codec.label.uppercase()} ${q.bitRate}"
        val suffix = (song.suffix ?: "").uppercase()
        val rate = song.bitRate
        if (rate != null && suffix in setOf("MP3", "M4A", "AAC", "MP4", "OGG", "OPUS")) return "$suffix $rate"
        return suffix.ifEmpty { "Original" }
    }

    companion object {
        /** Formats ExoPlayer plays on every supported Android version; anything else (WMA, APE, DSD …) is converted. */
        val playable = setOf("mp3", "m4a", "m4b", "mp4", "aac", "flac", "ogg", "oga", "opus", "wav")
    }
}
