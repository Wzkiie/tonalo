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

    /** A filled triangular arrowhead. [len] is positive when it points right, negative when it points left. */
    private fun androidx.compose.ui.graphics.vector.PathBuilder.arrow(tipX: Float, y: Float, len: Float, half: Float) {
        val baseX = tipX - len
        moveTo(baseX, y - half); lineTo(tipX, y); lineTo(baseX, y + half); close()
    }

    /** Stroked lines plus filled arrowheads (the heads get a thin outline in the same colour, which rounds their corners). */
    private fun withHeads(
        name: String,
        lineWidth: Float,
        strokes: androidx.compose.ui.graphics.vector.PathBuilder.() -> Unit,
        heads: androidx.compose.ui.graphics.vector.PathBuilder.() -> Unit,
        extra: (androidx.compose.ui.graphics.vector.PathBuilder.() -> Unit)? = null,
    ): ImageVector =
        ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f).apply {
            addPath(
                nodes(strokes),
                stroke = SolidColor(Color.Black), strokeLineWidth = lineWidth, strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round,
            )
            if (extra != null) {
                addPath(
                    nodes(extra),
                    stroke = SolidColor(Color.Black), strokeLineWidth = 1.8f, strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round,
                )
            }
            addPath(
                nodes(heads),
                fill = SolidColor(Color.Black), stroke = SolidColor(Color.Black), strokeLineWidth = 1f,
                strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round,
            )
        }.build()

    /**
     * Two crossing arrows like SF "shuffle". The path from the lower left to the upper right is whole;
     * the other one is cut open around the crossing so it seems to pass behind.
     */
    val Shuffle: ImageVector by lazy {
        withHeads(
            "TonaloShuffle", 2.2f,
            strokes = {
                // lower left -> upper right, in front
                moveTo(3f, 17f); horizontalLineTo(6f); curveTo(10.5f, 17f, 11f, 7f, 15.5f, 7f); horizontalLineTo(18f)
                // upper left -> lower right, in two pieces with a gap at the crossing
                moveTo(3f, 7f); horizontalLineTo(6f); curveTo(7.125f, 7f, 8f, 7.625f, 8.75f, 8.56f)
                moveTo(12.75f, 15.44f); curveTo(13.5f, 16.375f, 14.375f, 17f, 15.5f, 17f); horizontalLineTo(18f)
            },
            heads = {
                arrow(21.3f, 7f, 3.9f, 3.1f)
                arrow(21.3f, 17f, 3.9f, 3.1f)
            },
        )
    }

    /** The two half loops of SF "repeat": the top one runs right, the bottom one runs left. */
    private fun androidx.compose.ui.graphics.vector.PathBuilder.repeatLoop(yTop: Float, yBottom: Float) {
        val r = 3.1f
        moveTo(3.5f, yTop + 5f); verticalLineTo(yTop + r); arcTo(r, r, 0f, false, true, 3.5f + r, yTop); horizontalLineTo(17.9f)
        moveTo(20.5f, yBottom - 5f); verticalLineTo(yBottom - r); arcTo(r, r, 0f, false, true, 20.5f - r, yBottom); horizontalLineTo(6.1f)
    }

    val Repeat: ImageVector by lazy {
        withHeads(
            "TonaloRepeat", 2.2f,
            strokes = { repeatLoop(6.5f, 17.5f) },
            heads = {
                arrow(21.4f, 6.5f, 3.9f, 3.1f)
                arrow(2.6f, 17.5f, -3.9f, 3.1f)
            },
        )
    }

    /** The loop (a little flatter) with a small "1" at the top right, like SF "repeat.1". */
    val RepeatOne: ImageVector by lazy {
        withHeads(
            "TonaloRepeatOne", 2.2f,
            strokes = { repeatLoop(9.5f, 19f) },
            heads = {
                arrow(21.4f, 9.5f, 3.9f, 2.6f)
                arrow(2.6f, 19f, -3.9f, 2.6f)
            },
            // the "1": a flag and a stem, a little lighter than the loop
            extra = { moveTo(18.1f, 4.1f); lineTo(19.7f, 2.7f); verticalLineTo(6.6f) },
        )
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
    /** A closed polygon whose corners are rounded with quadratic curves (radius [r], capped at half an edge). */
    private fun androidx.compose.ui.graphics.vector.PathBuilder.poly(pts: List<Pair<Float, Float>>, r: Float) {
        val n = pts.size
        for (i in 0 until n) {
            val (px, py) = pts[i]
            val (qx, qy) = pts[(i + n - 1) % n]
            val (sx, sy) = pts[(i + 1) % n]
            val lenIn = kotlin.math.sqrt((qx - px) * (qx - px) + (qy - py) * (qy - py))
            val lenOut = kotlin.math.sqrt((sx - px) * (sx - px) + (sy - py) * (sy - py))
            val rIn = minOf(r, lenIn / 2f) / lenIn
            val rOut = minOf(r, lenOut / 2f) / lenOut
            val ax = px + (qx - px) * rIn
            val ay = py + (qy - py) * rIn
            if (i == 0) moveTo(ax, ay) else lineTo(ax, ay)
            quadTo(px, py, px + (sx - px) * rOut, py + (sy - py) * rOut)
        }
        close()
    }

    private fun filled(name: String, evenOdd: Boolean, build: androidx.compose.ui.graphics.vector.PathBuilder.() -> Unit): ImageVector =
        ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f).apply {
            addPath(
                nodes(build),
                pathFillType = if (evenOdd) androidx.compose.ui.graphics.PathFillType.EvenOdd else androidx.compose.ui.graphics.PathFillType.NonZero,
                fill = SolidColor(Color.Black),
            )
        }.build()

    /** SF "house": a roof with a little overhang, walls with rounded feet and a door. */
    val HomeOutline: ImageVector by lazy {
        line("TonaloHomeOutline", 1.9f) {
            // roof
            moveTo(2.8f, 11.4f); lineTo(12f, 3.5f); lineTo(21.2f, 11.4f)
            // walls and door
            moveTo(5.6f, 9.4f); verticalLineTo(17.6f); arcTo(2f, 2f, 0f, false, false, 7.6f, 19.6f); horizontalLineTo(9.8f)
            verticalLineTo(14.6f); horizontalLineTo(14.2f); verticalLineTo(19.6f); horizontalLineTo(16.4f)
            arcTo(2f, 2f, 0f, false, false, 18.4f, 17.6f); verticalLineTo(9.4f)
        }
    }

    /** SF "house.fill": solid, with the door cut out at the bottom. */
    val HomeFilled: ImageVector by lazy {
        filled("TonaloHomeFilled", evenOdd = true) {
            poly(
                listOf(
                    12f to 3f, 21.2f to 11.4f, 18.4f to 11f, 18.4f to 19.8f, 14.6f to 19.8f, 14.6f to 14.8f,
                    9.4f to 14.8f, 9.4f to 19.8f, 5.6f to 19.8f, 5.6f to 11f, 2.8f to 11.4f,
                ),
                1.2f,
            )
        }
    }

    private fun search(name: String, width: Float): ImageVector =
        line(name, width) {
            // lens: a circle of radius 6.2 around (10.5, 10.5)
            moveTo(10.5f, 4.3f); arcTo(6.2f, 6.2f, 0f, true, true, 10.49f, 4.3f); close()
            // handle
            moveTo(15.4f, 15.4f); lineTo(20.5f, 20.5f)
        }
    val Search: ImageVector by lazy { search("TonaloSearch", 2.2f) }
    val SearchBold: ImageVector by lazy { search("TonaloSearchBold", 3f) }

    // Two upright books and a tilted one (SF "books.vertical"). The tilted book leans about 10 degrees:
    // its sides run along d = (0.174, 0.985), its top and bottom along n = (0.985, -0.174).
    val LibraryOutline: ImageVector by lazy {
        line("TonaloLibraryOutline", 1.7f) {
            moveTo(3.4f, 5f); horizontalLineTo(7f); verticalLineTo(19.4f); horizontalLineTo(3.4f); close()
            moveTo(9.6f, 5f); horizontalLineTo(13.2f); verticalLineTo(19.4f); horizontalLineTo(9.6f); close()
            moveTo(15.6f, 5.6f); lineTo(19.15f, 4.97f); lineTo(21.66f, 19.15f); lineTo(18.11f, 19.78f); close()
            // spine lines
            moveTo(3.4f, 9f); horizontalLineTo(7f)
            moveTo(9.6f, 9f); horizontalLineTo(13.2f)
            moveTo(16.21f, 9.05f); lineTo(19.76f, 8.42f)
        }
    }

    val LibraryFilled: ImageVector by lazy {
        filled("TonaloLibraryFilled", evenOdd = true) {
            // upright books with a thin cut-out line each
            poly(listOf(2.4f to 4.2f, 7.5f to 4.2f, 7.5f to 20f, 2.4f to 20f), 1f)
            moveTo(3.7f, 8.2f); horizontalLineTo(6.2f); verticalLineTo(9.1f); horizontalLineTo(3.7f); close()
            poly(listOf(8.8f to 4.2f, 13.9f to 4.2f, 13.9f to 20f, 8.8f to 20f), 1f)
            moveTo(10.1f, 8.2f); horizontalLineTo(12.6f); verticalLineTo(9.1f); horizontalLineTo(10.1f); close()
            // tilted book
            poly(listOf(15.2f to 4.9f, 20.22f to 4.01f, 22.86f to 18.98f, 17.84f to 19.87f), 1f)
            moveTo(17.14f, 8.41f); lineTo(19.6f, 7.98f); lineTo(19.76f, 8.87f); lineTo(17.3f, 9.3f); close()
        }
    }

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

    // ---- SF Symbols look-alikes (settings, menus, toolbars) ----

    private fun androidx.compose.ui.graphics.vector.PathBuilder.circleAt(cx: Float, cy: Float, r: Float) {
        moveTo(cx, cy - r); arcTo(r, r, 0f, true, true, cx - 0.01f, cy - r); close()
    }

    /** A four-pointed star with concave sides, as in the sparkles symbol. */
    private fun androidx.compose.ui.graphics.vector.PathBuilder.starAt(cx: Float, cy: Float, r: Float) {
        val k = r * 0.22f
        moveTo(cx, cy - r); quadTo(cx + k, cy - k, cx + r, cy); quadTo(cx + k, cy + k, cx, cy + r)
        quadTo(cx - k, cy + k, cx - r, cy); quadTo(cx - k, cy - k, cx, cy - r); close()
    }

    /** gearshape: a ring with eight teeth and a small hub. */
    val Gear: ImageVector by lazy {
        line("TonaloGear", 2.1f) {
            circleAt(12f, 12f, 6.9f)
            circleAt(12f, 12f, 2.7f)
            moveTo(12f, 2.8f); verticalLineTo(5.1f)
            moveTo(12f, 18.9f); verticalLineTo(21.2f)
            moveTo(2.8f, 12f); horizontalLineTo(5.1f)
            moveTo(18.9f, 12f); horizontalLineTo(21.2f)
            moveTo(5.5f, 5.5f); lineTo(7.1f, 7.1f)
            moveTo(16.9f, 16.9f); lineTo(18.5f, 18.5f)
            moveTo(18.5f, 5.5f); lineTo(16.9f, 7.1f)
            moveTo(7.1f, 16.9f); lineTo(5.5f, 18.5f)
        }
    }

    /** tv: a rounded screen on a stand. */
    val Tv: ImageVector by lazy {
        line("TonaloTv", 2f) {
            moveTo(5.4f, 4.8f); horizontalLineTo(18.6f); arcTo(2.2f, 2.2f, 0f, false, true, 20.8f, 7f); verticalLineTo(14.4f)
            arcTo(2.2f, 2.2f, 0f, false, true, 18.6f, 16.6f); horizontalLineTo(5.4f); arcTo(2.2f, 2.2f, 0f, false, true, 3.2f, 14.4f)
            verticalLineTo(7f); arcTo(2.2f, 2.2f, 0f, false, true, 5.4f, 4.8f); close()
            moveTo(8.4f, 20.2f); horizontalLineTo(15.6f)
        }
    }

    val Plus: ImageVector by lazy { line("TonaloPlus", 2.6f) { moveTo(12f, 4.8f); verticalLineTo(19.2f); moveTo(4.8f, 12f); horizontalLineTo(19.2f) } }
    val Xmark: ImageVector by lazy { line("TonaloXmark", 2.6f) { moveTo(6f, 6f); lineTo(18f, 18f); moveTo(18f, 6f); lineTo(6f, 18f) } }
    val Checkmark: ImageVector by lazy { line("TonaloCheckmark", 2.8f) { moveTo(5f, 12.8f); lineTo(9.8f, 17.6f); lineTo(19f, 6.6f) } }

    /** chevron.right, bold; used small. */
    val ChevronRight: ImageVector by lazy { line("TonaloChevronRight", 3f) { moveTo(9f, 5.2f); lineTo(15.8f, 12f); lineTo(9f, 18.8f) } }

    /** arrow.up.arrow.down: sort. */
    val Sort: ImageVector by lazy {
        line("TonaloSort", 2.2f) {
            moveTo(8f, 19f); verticalLineTo(5f); moveTo(4.6f, 8.4f); lineTo(8f, 5f); lineTo(11.4f, 8.4f)
            moveTo(16f, 5f); verticalLineTo(19f); moveTo(12.6f, 15.6f); lineTo(16f, 19f); lineTo(19.4f, 15.6f)
        }
    }

    /** square.grid.2x2. */
    val Grid: ImageVector by lazy {
        line("TonaloGrid", 2f) {
            moveTo(4.6f, 4.6f); horizontalLineTo(9.8f); verticalLineTo(9.8f); horizontalLineTo(4.6f); close()
            moveTo(14.2f, 4.6f); horizontalLineTo(19.4f); verticalLineTo(9.8f); horizontalLineTo(14.2f); close()
            moveTo(4.6f, 14.2f); horizontalLineTo(9.8f); verticalLineTo(19.4f); horizontalLineTo(4.6f); close()
            moveTo(14.2f, 14.2f); horizontalLineTo(19.4f); verticalLineTo(19.4f); horizontalLineTo(14.2f); close()
        }
    }

    /** pin.fill, upright; rotate it 45 degrees at the call site as the iPhone does. */
    val Pin: ImageVector by lazy {
        solid("TonaloPin", 1.6f) {
            moveTo(8.2f, 3.8f); horizontalLineTo(15.8f); lineTo(14.6f, 6f); verticalLineTo(10.6f); lineTo(17.4f, 14f); horizontalLineTo(6.6f)
            lineTo(9.4f, 10.6f); verticalLineTo(6f); close()
            moveTo(12f, 14f); verticalLineTo(20.8f)
        }
    }

    /** text.insert: play next (lines with an arrow pointing in). */
    val TextInsert: ImageVector by lazy {
        line("TonaloTextInsert", 2.1f) {
            moveTo(3.6f, 5.6f); horizontalLineTo(20.4f)
            moveTo(11.4f, 11f); horizontalLineTo(20.4f)
            moveTo(11.4f, 16.4f); horizontalLineTo(20.4f)
            moveTo(3.6f, 13.7f); horizontalLineTo(8.6f)
            moveTo(6.2f, 11.1f); lineTo(8.8f, 13.7f); lineTo(6.2f, 16.3f)
        }
    }

    /** text.append: add to the end of the queue. */
    val TextAppend: ImageVector by lazy {
        line("TonaloTextAppend", 2.1f) {
            moveTo(3.6f, 5.6f); horizontalLineTo(20.4f)
            moveTo(3.6f, 11f); horizontalLineTo(20.4f)
            moveTo(3.6f, 16.4f); horizontalLineTo(10.6f)
            moveTo(13.6f, 16.4f); horizontalLineTo(20.4f)
            moveTo(17.8f, 13.8f); lineTo(20.4f, 16.4f); lineTo(17.8f, 19f)
        }
    }

    /** text.badge.plus: add to a playlist. */
    val TextBadgePlus: ImageVector by lazy {
        line("TonaloTextBadgePlus", 2.1f) {
            moveTo(3.6f, 5.6f); horizontalLineTo(20.4f)
            moveTo(3.6f, 11f); horizontalLineTo(20.4f)
            moveTo(3.6f, 16.4f); horizontalLineTo(10.6f)
            moveTo(17f, 13f); verticalLineTo(19.8f)
            moveTo(13.6f, 16.4f); horizontalLineTo(20.4f)
        }
    }

    /** sparkles: one large and two small stars. */
    val Sparkles: ImageVector by lazy {
        solid("TonaloSparkles", 1f) {
            starAt(9.6f, 14f, 7.4f)
            starAt(18.2f, 6f, 3.6f)
            starAt(19.2f, 18.6f, 2.4f)
        }
    }

    /** music.mic: go to the artist. */
    val Mic: ImageVector by lazy {
        line("TonaloMic", 2.1f) {
            moveTo(9.4f, 6f); arcTo(2.6f, 2.6f, 0f, false, true, 14.6f, 6f); verticalLineTo(10.4f)
            arcTo(2.6f, 2.6f, 0f, false, true, 9.4f, 10.4f); close()
            moveTo(6.2f, 10.2f); arcTo(5.8f, 5.8f, 0f, false, false, 17.8f, 10.2f)
            moveTo(12f, 16f); verticalLineTo(20.4f)
            moveTo(8.6f, 20.4f); horizontalLineTo(15.4f)
        }
    }

    /** square.stack: go to the album. */
    val SquareStack: ImageVector by lazy {
        line("TonaloSquareStack", 2.1f) {
            moveTo(7.6f, 4.8f); horizontalLineTo(18.4f); arcTo(1.6f, 1.6f, 0f, false, true, 20f, 6.4f); verticalLineTo(14.4f)
            moveTo(4.6f, 10f); horizontalLineTo(15f); arcTo(1.4f, 1.4f, 0f, false, true, 16.4f, 11.4f); verticalLineTo(19.2f)
            arcTo(1.4f, 1.4f, 0f, false, true, 15f, 20.6f); horizontalLineTo(5.8f); arcTo(1.4f, 1.4f, 0f, false, true, 4.4f, 19.2f); verticalLineTo(11.2f)
            arcTo(1.2f, 1.2f, 0f, false, true, 4.6f, 10f); close()
        }
    }

    /** dot.radiowaves.left.and.right: radio. */
    val Radio: ImageVector by lazy {
        line("TonaloRadio", 2.1f) {
            moveTo(12f, 12f); horizontalLineTo(12.1f)
            moveTo(15f, 8.8f); arcTo(4.4f, 4.4f, 0f, false, true, 15f, 15.2f)
            moveTo(17.6f, 5.6f); arcTo(8.5f, 8.5f, 0f, false, true, 17.6f, 18.4f)
            moveTo(9f, 15.2f); arcTo(4.4f, 4.4f, 0f, false, true, 9f, 8.8f)
            moveTo(6.4f, 18.4f); arcTo(8.5f, 8.5f, 0f, false, true, 6.4f, 5.6f)
        }
    }

    /** person.2.wave.2: shared listening (Jukebox). */
    val Jukebox: ImageVector by lazy {
        line("TonaloJukebox", 2f) {
            circleAt(8.6f, 8.4f, 2.8f)
            moveTo(3.4f, 19.6f); curveTo(3.4f, 16.2f, 5.6f, 14.2f, 8.6f, 14.2f); curveTo(11.6f, 14.2f, 13.8f, 16.2f, 13.8f, 19.6f); close()
            moveTo(16.6f, 9.4f); arcTo(3.2f, 3.2f, 0f, false, true, 16.6f, 15f)
            moveTo(19.4f, 6.8f); arcTo(6.2f, 6.2f, 0f, false, true, 19.4f, 17.6f)
        }
    }

    /** book.closed. */
    val BookClosed: ImageVector by lazy {
        line("TonaloBookClosed", 2f) {
            moveTo(7f, 3.4f); horizontalLineTo(17.8f); quadTo(19f, 3.4f, 19f, 4.6f); verticalLineTo(19.4f); quadTo(19f, 20.6f, 17.8f, 20.6f)
            horizontalLineTo(7f); quadTo(5f, 20.6f, 5f, 18.6f); verticalLineTo(5.4f); quadTo(5f, 3.4f, 7f, 3.4f); close()
            moveTo(9f, 3.6f); verticalLineTo(15.8f)
            moveTo(5.2f, 17f); quadTo(5.2f, 15.8f, 7f, 15.8f); horizontalLineTo(19f)
        }
    }

    /** trash. */
    val Trash: ImageVector by lazy {
        line("TonaloTrash", 2f) {
            moveTo(4.4f, 6.6f); horizontalLineTo(19.6f)
            moveTo(9.4f, 6.4f); verticalLineTo(4.6f); quadTo(9.4f, 3.6f, 10.4f, 3.6f); horizontalLineTo(13.6f); quadTo(14.6f, 3.6f, 14.6f, 4.6f); verticalLineTo(6.4f)
            moveTo(6.2f, 6.8f); lineTo(7f, 19f); quadTo(7.1f, 20.4f, 8.5f, 20.4f); horizontalLineTo(15.5f); quadTo(16.9f, 20.4f, 17f, 19f); lineTo(17.8f, 6.8f)
            moveTo(10f, 10.4f); verticalLineTo(16.4f)
            moveTo(14f, 10.4f); verticalLineTo(16.4f)
        }
    }

    private val moonPath: androidx.compose.ui.graphics.vector.PathBuilder.() -> Unit = {
        moveTo(9.8f, 4.2f); curveTo(5.8f, 5.2f, 3.2f, 8.6f, 3.2f, 12.6f); curveTo(3.2f, 17.4f, 7f, 20.8f, 11.6f, 20.8f)
        curveTo(14.8f, 20.8f, 17.6f, 19.2f, 19f, 16.6f); curveTo(13.6f, 17f, 9.4f, 12.6f, 9.8f, 4.2f); close()
    }
    private val zzzPath: androidx.compose.ui.graphics.vector.PathBuilder.() -> Unit = {
        moveTo(14.2f, 3.8f); horizontalLineTo(18.2f); lineTo(14.2f, 8f); horizontalLineTo(18.2f)
        moveTo(19.4f, 10.4f); horizontalLineTo(21.4f); lineTo(19.4f, 12.6f); horizontalLineTo(21.4f)
    }

    /** moon.zzz (outline) and moon.zzz.fill: sleep timer. */
    val MoonZzz: ImageVector by lazy {
        ImageVector.Builder("TonaloMoonZzz", 24.dp, 24.dp, 24f, 24f).apply {
            addPath(nodes(moonPath), stroke = SolidColor(Color.Black), strokeLineWidth = 1.9f, strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round)
            addPath(nodes(zzzPath), stroke = SolidColor(Color.Black), strokeLineWidth = 1.9f, strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round)
        }.build()
    }
    val MoonZzzFilled: ImageVector by lazy {
        ImageVector.Builder("TonaloMoonZzzFilled", 24.dp, 24.dp, 24f, 24f).apply {
            addPath(nodes(moonPath), fill = SolidColor(Color.Black), stroke = SolidColor(Color.Black), strokeLineWidth = 1.2f, strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round)
            addPath(nodes(zzzPath), stroke = SolidColor(Color.Black), strokeLineWidth = 1.9f, strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round)
        }.build()
    }

    /** The download circle drawn as dots: some, but not all, of the songs are downloaded. */
    val DownloadPartial: ImageVector by lazy {
        line("TonaloDownloadPartial", 2.3f) {
            val dots = listOf(
                20.8f to 12f, 19.62f to 16.4f, 16.4f to 19.62f, 12f to 20.8f, 7.6f to 19.62f, 4.38f to 16.4f,
                3.2f to 12f, 4.38f to 7.6f, 7.6f to 4.38f, 12f to 3.2f, 16.4f to 4.38f, 19.62f to 7.6f,
            )
            dots.forEach { (x, y) -> moveTo(x, y); horizontalLineTo(x + 0.01f) }
            moveTo(12f, 7.6f); verticalLineTo(15.2f)
            moveTo(8.6f, 12f); lineTo(12f, 15.4f); lineTo(15.4f, 12f)
        }
    }
}
