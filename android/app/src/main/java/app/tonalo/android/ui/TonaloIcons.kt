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

/** Line and filled symbols in the iPhone's style: round ends, even weight. Drawn on a 24 x 24 grid; the color comes from the Icon's tint. */
object TonaloGlyphs {
    private fun line(name: String, width: Float = 2.2f, build: androidx.compose.ui.graphics.vector.PathBuilder.() -> Unit): ImageVector =
        ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f).path(
            fill = null, stroke = SolidColor(Color.Black), strokeLineWidth = width,
            strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round, pathBuilder = build,
        ).build()

    private fun solid(name: String, outline: Float = 1.2f, build: androidx.compose.ui.graphics.vector.PathBuilder.() -> Unit): ImageVector =
        ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f).path(
            fill = SolidColor(Color.Black), stroke = SolidColor(Color.Black), strokeLineWidth = outline,
            strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round, pathBuilder = build,
        ).build()

    private fun nodes(build: androidx.compose.ui.graphics.vector.PathBuilder.() -> Unit) =
        androidx.compose.ui.graphics.vector.PathBuilder().apply(build).nodes

    /** Two crossing arrows. */
    val Shuffle: ImageVector by lazy {
        line("TonaloShuffle", 2.3f) {
            moveTo(3.2f, 7f); horizontalLineTo(6.4f); curveTo(11f, 7f, 11.6f, 17f, 16.2f, 17f); horizontalLineTo(20.3f)
            moveTo(17.6f, 14.4f); lineTo(20.3f, 17f); lineTo(17.6f, 19.6f)
            moveTo(3.2f, 17f); horizontalLineTo(6.4f); curveTo(8f, 17f, 9f, 16.2f, 9.9f, 15f)
            moveTo(13.4f, 9f); curveTo(14.3f, 7.8f, 15.2f, 7f, 16.8f, 7f); horizontalLineTo(20.3f)
            moveTo(17.6f, 4.4f); lineTo(20.3f, 7f); lineTo(17.6f, 9.6f)
        }
    }

    /** Two arrows chasing each other round a loop. */
    private val repeatPath: androidx.compose.ui.graphics.vector.PathBuilder.() -> Unit = {
        moveTo(3.6f, 11.6f); verticalLineTo(10.6f); arcTo(3.6f, 3.6f, 0f, false, true, 7.2f, 7f); horizontalLineTo(20.4f)
        moveTo(17.8f, 4.4f); lineTo(20.4f, 7f); lineTo(17.8f, 9.6f)
        moveTo(20.4f, 12.4f); verticalLineTo(13.4f); arcTo(3.6f, 3.6f, 0f, false, true, 16.8f, 17f); horizontalLineTo(3.6f)
        moveTo(6.2f, 14.4f); lineTo(3.6f, 17f); lineTo(6.2f, 19.6f)
    }
    val Repeat: ImageVector by lazy { line("TonaloRepeat", 2.3f, repeatPath) }

    /** The loop with a "1" in the middle. */
    val RepeatOne: ImageVector by lazy {
        ImageVector.Builder("TonaloRepeatOne", 24.dp, 24.dp, 24f, 24f).apply {
            addPath(
                nodes(repeatPath),
                stroke = SolidColor(Color.Black), strokeLineWidth = 2.3f, strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round,
            )
            addPath(
                nodes { moveTo(10.6f, 10.4f); lineTo(12.4f, 9.4f); verticalLineTo(14.8f) },
                stroke = SolidColor(Color.Black), strokeLineWidth = 1.9f, strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round,
            )
        }.build()
    }

    private val heartPath: androidx.compose.ui.graphics.vector.PathBuilder.() -> Unit = {
        moveTo(12f, 20.2f)
        curveTo(5.2f, 15.4f, 3f, 11.6f, 3f, 8.6f)
        curveTo(3f, 6.1f, 4.9f, 4.2f, 7.3f, 4.2f)
        curveTo(9.2f, 4.2f, 10.9f, 5.2f, 12f, 7f)
        curveTo(13.1f, 5.2f, 14.8f, 4.2f, 16.7f, 4.2f)
        curveTo(19.1f, 4.2f, 21f, 6.1f, 21f, 8.6f)
        curveTo(21f, 11.6f, 18.8f, 15.4f, 12f, 20.2f)
        close()
    }
    val Heart: ImageVector by lazy { line("TonaloHeart", 2.1f, heartPath) }
    val HeartFilled: ImageVector by lazy { solid("TonaloHeartFilled", 1.2f, heartPath) }

    /** A speech bubble with quote marks: lyrics. */
    val Lyrics: ImageVector by lazy {
        ImageVector.Builder("TonaloLyrics", 24.dp, 24.dp, 24f, 24f).apply {
            addPath(
                nodes {
                    moveTo(6f, 3.8f); horizontalLineTo(18f); arcTo(2.6f, 2.6f, 0f, false, true, 20.6f, 6.4f); verticalLineTo(14f)
                    arcTo(2.6f, 2.6f, 0f, false, true, 18f, 16.6f); horizontalLineTo(12.8f); lineTo(8.6f, 20.2f); verticalLineTo(16.6f); horizontalLineTo(6f)
                    arcTo(2.6f, 2.6f, 0f, false, true, 3.4f, 14f); verticalLineTo(6.4f); arcTo(2.6f, 2.6f, 0f, false, true, 6f, 3.8f); close()
                },
                stroke = SolidColor(Color.Black), strokeLineWidth = 1.9f, strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round,
            )
            addPath(
                nodes {
                    moveTo(9.6f, 8.2f); verticalLineTo(9.4f); curveTo(9.6f, 10.6f, 9.1f, 11.1f, 8.2f, 11.5f)
                    moveTo(14.8f, 8.2f); verticalLineTo(9.4f); curveTo(14.8f, 10.6f, 14.3f, 11.1f, 13.4f, 11.5f)
                },
                stroke = SolidColor(Color.Black), strokeLineWidth = 2.1f, strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round,
            )
        }.build()
    }

    /** Bullets and lines: the queue. */
    val Queue: ImageVector by lazy {
        line("TonaloQueue", 2.3f) {
            moveTo(9.4f, 6.4f); horizontalLineTo(20.4f)
            moveTo(9.4f, 12f); horizontalLineTo(20.4f)
            moveTo(9.4f, 17.6f); horizontalLineTo(20.4f)
            moveTo(3.9f, 6.4f); horizontalLineTo(4f)
            moveTo(3.9f, 12f); horizontalLineTo(4f)
            moveTo(3.9f, 17.6f); horizontalLineTo(4f)
        }
    }

    val ChevronDown: ImageVector by lazy { line("TonaloChevronDown", 2.8f) { moveTo(5.6f, 9f); lineTo(12f, 15.4f); lineTo(18.4f, 9f) } }
    val ChevronLeft: ImageVector by lazy { line("TonaloChevronLeft", 2.8f) { moveTo(15f, 5.2f); lineTo(8.2f, 12f); lineTo(15f, 18.8f) } }

    val MoreHorizontal: ImageVector by lazy {
        line("TonaloMore", 3.6f) { moveTo(5.2f, 12f); horizontalLineTo(5.3f); moveTo(12f, 12f); horizontalLineTo(12.1f); moveTo(18.7f, 12f); horizontalLineTo(18.8f) }
    }

    // Tab bar: an outline when not chosen, filled when chosen (as the iPhone does)
    private val housePath: androidx.compose.ui.graphics.vector.PathBuilder.() -> Unit = {
        moveTo(12f, 3.4f); lineTo(3f, 11f); horizontalLineTo(5.2f); verticalLineTo(19.6f); horizontalLineTo(9.8f); verticalLineTo(14.2f)
        horizontalLineTo(14.2f); verticalLineTo(19.6f); horizontalLineTo(18.8f); verticalLineTo(11f); horizontalLineTo(21f); close()
    }
    val HomeOutline: ImageVector by lazy { line("TonaloHomeOutline", 1.9f, housePath) }
    val HomeFilled: ImageVector by lazy { solid("TonaloHomeFilled", 1.6f, housePath) }

    val Search: ImageVector by lazy {
        line("TonaloSearch", 2.3f) {
            moveTo(10.6f, 4.4f); arcTo(6.2f, 6.2f, 0f, true, true, 10.59f, 4.4f); close()
            moveTo(15.3f, 15.3f); lineTo(20.4f, 20.4f)
        }
    }
    val SearchBold: ImageVector by lazy {
        line("TonaloSearchBold", 3.1f) {
            moveTo(10.6f, 4.4f); arcTo(6.2f, 6.2f, 0f, true, true, 10.59f, 4.4f); close()
            moveTo(15.3f, 15.3f); lineTo(20.4f, 20.4f)
        }
    }

    // Three books standing on a shelf
    private val booksPath: androidx.compose.ui.graphics.vector.PathBuilder.() -> Unit = {
        moveTo(4f, 5f); horizontalLineTo(8f); verticalLineTo(19.6f); horizontalLineTo(4f); close()
        moveTo(9.6f, 5f); horizontalLineTo(13.6f); verticalLineTo(19.6f); horizontalLineTo(9.6f); close()
        moveTo(15.4f, 5.6f); lineTo(19f, 4.6f); lineTo(22.2f, 18.6f); lineTo(18.6f, 19.6f); close()
    }
    val LibraryOutline: ImageVector by lazy { line("TonaloLibraryOutline", 1.9f, booksPath) }
    val LibraryFilled: ImageVector by lazy { solid("TonaloLibraryFilled", 1.4f, booksPath) }

    /** A circle with an arrow pointing down: download. */
    val Download: ImageVector by lazy {
        line("TonaloDownload", 2f) {
            moveTo(12f, 3.2f); arcTo(8.8f, 8.8f, 0f, true, true, 11.99f, 3.2f); close()
            moveTo(12f, 7.6f); verticalLineTo(15.2f)
            moveTo(8.6f, 12f); lineTo(12f, 15.4f); lineTo(15.4f, 12f)
        }
    }

    /** The same circle, filled, with the arrow cut out: downloaded. */
    val Downloaded: ImageVector by lazy {
        ImageVector.Builder("TonaloDownloaded", 24.dp, 24.dp, 24f, 24f).apply {
            addPath(
                nodes {
                    moveTo(12f, 2.6f); arcTo(9.4f, 9.4f, 0f, true, true, 11.99f, 2.6f); close()
                    moveTo(10.9f, 7.2f); lineTo(13.1f, 7.2f); lineTo(13.1f, 11.9f); lineTo(15.7f, 11.9f); lineTo(12f, 15.8f); lineTo(8.3f, 11.9f); lineTo(10.9f, 11.9f); close()
                },
                fill = SolidColor(Color.Black), pathFillType = androidx.compose.ui.graphics.PathFillType.EvenOdd,
            )
        }.build()
    }
}
