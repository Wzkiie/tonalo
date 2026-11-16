package app.tonalo.android.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.unit.dp

/**
 * The player's buttons, drawn like the iPhone's: solid shapes with soft, rounded corners.
 * The outline is drawn in the same color as the fill, which rounds every corner.
 */
object TonaloIcons {
    private fun icon(name: String, build: androidx.compose.ui.graphics.vector.PathBuilder.() -> Unit): ImageVector =
        ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f).path(
            fill = SolidColor(Color.Black), stroke = SolidColor(Color.Black), strokeLineWidth = 2.4f,
            strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round, pathBuilder = build,
        ).build()

    val Play: ImageVector by lazy {
        icon("TonaloPlay") { moveTo(8.5f, 6.2f); lineTo(8.5f, 17.8f); lineTo(18.2f, 12f); close() }
    }

    val Pause: ImageVector by lazy {
        icon("TonaloPause") {
            moveTo(7.6f, 6.4f); lineTo(9.4f, 6.4f); lineTo(9.4f, 17.6f); lineTo(7.6f, 17.6f); close()
            moveTo(14.6f, 6.4f); lineTo(16.4f, 6.4f); lineTo(16.4f, 17.6f); lineTo(14.6f, 17.6f); close()
        }
    }

    val Previous: ImageVector by lazy {
        icon("TonaloPrevious") {
            moveTo(5.8f, 6.4f); lineTo(7.4f, 6.4f); lineTo(7.4f, 17.6f); lineTo(5.8f, 17.6f); close()
            moveTo(18.4f, 6.6f); lineTo(18.4f, 17.4f); lineTo(9.6f, 12f); close()
        }
    }

    val Next: ImageVector by lazy {
        icon("TonaloNext") {
            moveTo(16.6f, 6.4f); lineTo(18.2f, 6.4f); lineTo(18.2f, 17.6f); lineTo(16.6f, 17.6f); close()
            moveTo(5.6f, 6.6f); lineTo(5.6f, 17.4f); lineTo(14.4f, 12f); close()
        }
    }
}
