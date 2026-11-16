package app.tonalo.android.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.res.stringResource
import app.tonalo.android.R
import app.tonalo.android.playback.BookPlayer

/** Settings > Audiobook playback: the speed and the skip buttons, kept for all audiobooks and podcasts. */
@Composable
fun BookPlaybackSettingsScreen() {
    val state by BookPlayer.state.collectAsState()
    GroupedPage(stringResource(R.string.bpl_settings_title)) {
        item {
            Group(footer = stringResource(R.string.bpl_speed_footer)) {
                PickerRow(stringResource(R.string.bpl_speed), state.rate, BookPlayer.rates, label = { bplRateText(it) }) { BookPlayer.setRate(it) }
            }
        }
        item {
            Group(header = stringResource(R.string.bpl_skip_buttons)) {
                PickerRow(stringResource(R.string.bpl_skip_back), state.skipBack, BookPlayer.skipChoices, label = { stringResource(R.string.bpl_seconds, it) }) { BookPlayer.setSkipBack(it) }
                PickerRow(stringResource(R.string.bpl_skip_forward), state.skipForward, BookPlayer.skipChoices, label = { stringResource(R.string.bpl_seconds, it) }) { BookPlayer.setSkipForward(it) }
            }
        }
    }
}
