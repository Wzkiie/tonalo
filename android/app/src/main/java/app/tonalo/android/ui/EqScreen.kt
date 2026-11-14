package app.tonalo.android.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.tonalo.android.R
import app.tonalo.android.playback.Eq
import app.tonalo.android.tonalo
import kotlin.math.roundToInt

/** Name of a preset, for the chips and the settings row. */
@Composable
fun eqPresetName(id: String): String = stringResource(when (id) {
    "flat" -> R.string.eq_flat
    "bass" -> R.string.eq_bass
    "treble" -> R.string.eq_treble
    "vocal" -> R.string.eq_vocal
    "rock" -> R.string.eq_rock
    "pop" -> R.string.eq_pop
    "jazz" -> R.string.eq_jazz
    "electronic" -> R.string.eq_electronic
    "loudness" -> R.string.eq_loudness
    else -> R.string.eq_custom
})

/**
 * The equalizer: on/off, presets as chips, and five sliders. Moving a slider makes it "Custom".
 * Changes are heard at once – the playback service follows the settings.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun EqScreen() {
    val s = LocalContext.current.tonalo.settings
    val on by s.eqEnabled.collectAsState()
    val preset by s.eqPreset.collectAsState()
    val customText by s.eqCustomGains.collectAsState()
    val gains = Eq.gains(preset, Eq.parse(customText))

    GroupedPage(stringResource(R.string.equalizer)) {
        item {
            Group(footer = stringResource(R.string.eq_info)) {
                ToggleRow(stringResource(R.string.equalizer), on) { s.setEqEnabled(it) }
            }
        }
        item {
            Group(stringResource(R.string.eq_presets)) {
                GroupBox {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        (Eq.presets.map { it.first } + "custom").forEach { id ->
                            Chip(eqPresetName(id), id == preset) {
                                if (id == "custom") s.setEqCustom(Eq.format(gains))
                                s.setEqPreset(id)
                                if (!on) s.setEqEnabled(true)
                            }
                        }
                    }
                }
            }
        }
        item {
            Group {
                GroupBox {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                        Eq.frequencies.forEachIndexed { i, hz ->
                            BandSlider(
                                gains[i], hz, active = on,
                                onChange = { db ->
                                    val next = gains.toMutableList().also { it[i] = db }
                                    s.setEqCustom(Eq.format(next))
                                    s.setEqPreset("custom")
                                    if (!on) s.setEqEnabled(true)
                                },
                            )
                        }
                    }
                }
                ActionRow(stringResource(R.string.eq_reset), destructive = true) { s.setEqPreset("flat"); s.setEqCustom(Eq.format(List(5) { 0f })) }
            }
        }
    }
}

/** One band: the gain on top, a vertical track with a round thumb (drag or tap), the frequency below. */
@Composable
private fun BandSlider(db: Float, hz: Int, active: Boolean, onChange: (Float) -> Unit) {
    val current by rememberUpdatedState(db)
    // The gesture blocks below live on – they must call the newest onChange (it knows the newest gains)
    val change by rememberUpdatedState(onChange)
    val color = if (active) Palette.accent else Palette.subtle
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.width(56.dp)) {
        Text((if (db > 0) "+" else "") + db.roundToInt() + " dB", fontSize = 12.sp, color = Palette.secondaryText)
        Box(
            Modifier.padding(vertical = 10.dp).width(44.dp).height(200.dp)
                .pointerInput(Unit) {
                    fun value(y: Float) = ((0.5f - y / size.height) * 2 * Eq.MAX_DB).coerceIn(-Eq.MAX_DB, Eq.MAX_DB).roundToInt().toFloat()
                    detectTapGestures { change(value(it.y)) }
                }
                .pointerInput(Unit) {
                    var y = 0f
                    detectDragGestures(
                        onDragStart = { y = it.y },
                        onDrag = { change, drag ->
                            change.consume()
                            y = (y + drag.y).coerceIn(0f, size.height.toFloat())
                            val v = ((0.5f - y / size.height) * 2 * Eq.MAX_DB).roundToInt().toFloat()
                            if (v != current) change(v)
                        },
                    )
                },
        ) {
            Canvas(Modifier.matchParentSize()) {
                val track = 4.dp.toPx()
                val x = size.width / 2
                val mid = size.height / 2
                val y = mid - (db / Eq.MAX_DB) * mid
                drawRoundRect(Color.White.copy(alpha = 0.12f), Offset(x - track / 2, 0f), Size(track, size.height), CornerRadius(track / 2))
                drawLine(Color.White.copy(alpha = 0.25f), Offset(x - 10.dp.toPx(), mid), Offset(x + 10.dp.toPx(), mid), strokeWidth = 1.dp.toPx())
                drawRoundRect(color, Offset(x - track / 2, minOf(y, mid)), Size(track, kotlin.math.abs(y - mid)), CornerRadius(track / 2))
                drawCircle(Color.White, radius = 10.dp.toPx(), center = Offset(x, y))
            }
        }
        Text(if (hz >= 1000) "${hz / 1000}${if (hz % 1000 >= 100) "." + (hz % 1000) / 100 else ""}k" else "$hz", fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
    }
}
