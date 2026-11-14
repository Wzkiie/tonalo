package app.tonalo.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.tonalo.android.R
import app.tonalo.android.playback.BookPlayer

/** The audiobook or podcast that's playing, above the tabs, in the cover's color. Tap opens the full player. */
@Composable
fun BookMiniBar(onOpen: () -> Unit) {
    val state by BookPlayer.state.collectAsState()
    val item = state.item
    if (!state.active || item == null) return
    val tint = rememberBookCoverColor(item.id)
    val chapter = state.chapters.getOrNull(state.chapterIndex)
    val title = state.episode?.title ?: item.title
    val progress = if (state.durationSec > 0) (state.positionSec / state.durationSec).toFloat().coerceIn(0f, 1f) else 0f
    Box(
        Modifier.padding(horizontal = 10.dp, vertical = 4.dp).clip(RoundedCornerShape(16.dp))
            .background(tint?.darken(0.75f) ?: Palette.elevated).clickable(onClick = onOpen),
    ) {
        Column {
            Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                BplCover(item.id, 42.dp, corner = 8.dp, pixels = 120)
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f)) {
                    Text(chapter?.title?.ifBlank { null } ?: title, maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.SemiBold,
                        style = MaterialTheme.typography.bodyMedium)
                    Text(if (chapter != null) title else item.creator, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        style = MaterialTheme.typography.bodySmall, color = Color.White.copy(alpha = 0.7f))
                }
                if (state.tvName != null) Icon(Icons.Default.Tv, null, Modifier.padding(horizontal = 4.dp).size(18.dp), tint = Palette.accent)
                IconButton(onClick = { BookPlayer.skip(-state.skipBack) }) {
                    BplSkipIcon(false, state.skipBack, 26.dp)
                }
                if (state.loading) Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(Modifier.size(22.dp), color = Color.White, strokeWidth = 2.dp)
                } else IconButton(onClick = { BookPlayer.toggle() }) {
                    Icon(
                        if (state.playing) Icons.Default.Pause else Icons.Default.PlayArrow,
                        stringResource(if (state.playing) R.string.cd_pause else R.string.cd_play),
                    )
                }
            }
            LinearProgressIndicator(
                progress = { progress },
                modifier = Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, bottom = 2.dp).height(2.dp).clip(RoundedCornerShape(1.dp)),
                color = Color.White, trackColor = Color.White.copy(alpha = 0.2f),
                gapSize = 0.dp, drawStopIndicator = {},
            )
        }
    }
}
