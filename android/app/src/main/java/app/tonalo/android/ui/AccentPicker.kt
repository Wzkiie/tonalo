package app.tonalo.android.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import app.tonalo.android.R

/** Hue 0..360, saturation and brightness 0..1 of a "#RRGGBB" colour. */
private fun hsvOf(hex: String): FloatArray {
    val out = FloatArray(3)
    android.graphics.Color.colorToHSV(android.graphics.Color.parseColor(hex), out)
    return out
}

private fun hexOf(h: Float, s: Float, v: Float): String =
    "#%06X".format(0xFFFFFF and android.graphics.Color.HSVToColor(floatArrayOf(h, s, v)))

/** Brightest and darkest the accent may be, so it stays readable on the dark background and on its own text. */
private const val MIN_BRIGHTNESS = 0.45f

/**
 * Free choice of the accent colour: a round rainbow button that opens three sliders (hue, saturation, brightness),
 * like the colour picker of the iPhone app. [current] is the saved colour as "#RRGGBB"; [onPick] gets every new one.
 */
@Composable
fun CustomAccentPicker(current: String, isPreset: Boolean, onPick: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    val hsv = remember(current) { runCatching { hsvOf(current) }.getOrDefault(floatArrayOf(215f, 0.64f, 1f)) }
    val rainbow = remember { Brush.sweepGradient((0..6).map { Color.hsv(it * 60f % 360f, 1f, 1f) }) }
    Column(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.size(52.dp).then(if (!isPreset) Modifier.border(2.dp, Color.White, CircleShape) else Modifier)
                    .padding(4.dp).clip(CircleShape).background(rainbow).plainClickable { open = !open },
                contentAlignment = Alignment.Center,
            ) { if (!isPreset) Box(Modifier.size(22.dp).clip(CircleShape).background(Palette.parse(current) ?: Color.Gray).border(2.dp, Color.White, CircleShape)) }
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.custom_color), style = MaterialTheme.typography.bodyLarge)
                Text(current.uppercase(), style = MaterialTheme.typography.bodySmall, color = Palette.secondaryText)
            }
        }
        AnimatedVisibility(
            open,
            enter = expandVertically() + fadeIn(),
            exit = shrinkVertically() + fadeOut(),
        ) {
            Column(Modifier.padding(top = 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                val h = hsv[0]; val s = hsv[1]; val v = hsv[2].coerceAtLeast(MIN_BRIGHTNESS)
                ColorSlider(
                    h / 360f, Brush.horizontalGradient((0..6).map { Color.hsv(it * 60f % 360f, 1f, 1f) }),
                ) { onPick(hexOf(it * 360f, s.coerceAtLeast(0.15f), v)) }
                ColorSlider(
                    s, Brush.horizontalGradient(listOf(Color.hsv(h, 0f, v), Color.hsv(h, 1f, v))),
                ) { onPick(hexOf(h, it.coerceAtLeast(0.15f), v)) }
                ColorSlider(
                    (v - MIN_BRIGHTNESS) / (1f - MIN_BRIGHTNESS), Brush.horizontalGradient(listOf(Color.hsv(h, s, MIN_BRIGHTNESS), Color.hsv(h, s, 1f))),
                ) { onPick(hexOf(h, s, MIN_BRIGHTNESS + it * (1f - MIN_BRIGHTNESS))) }
            }
        }
    }
}

/** A slider whose track shows the colours it runs through. */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
private fun ColorSlider(value: Float, track: Brush, onChange: (Float) -> Unit) {
    Box(Modifier.fillMaxWidth().height(30.dp).clip(CircleShape).background(track), contentAlignment = Alignment.Center) {
        Slider(
            value = value.coerceIn(0f, 1f), onValueChange = onChange,
            colors = SliderDefaults.colors(
                thumbColor = Color.White, activeTrackColor = Color.Transparent, inactiveTrackColor = Color.Transparent,
            ),
            thumb = { Box(Modifier.size(26.dp).clip(CircleShape).background(Color.White).border(2.dp, Color.Black.copy(alpha = 0.25f), CircleShape)) },
            // The coloured bar behind is the track; this one only gives the thumb its width to run along
            track = { Box(Modifier.fillMaxWidth().height(30.dp)) },
            modifier = Modifier.padding(horizontal = 2.dp),
        )
    }
}
