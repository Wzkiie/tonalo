package app.tonalo.android.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Home
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.tonalo.android.R
import app.tonalo.android.data.Account
import app.tonalo.android.data.AudioQuality
import app.tonalo.android.data.Backdrop
import app.tonalo.android.data.CardShape
import app.tonalo.android.data.CoverSize
import app.tonalo.android.data.Settings
import app.tonalo.android.data.VolumeLeveling
import app.tonalo.android.downloads.BookDownloads
import app.tonalo.android.downloads.Downloads
import app.tonalo.android.link.JukeboxHost
import app.tonalo.android.link.TvLink
import app.tonalo.android.tonalo

/** Settings, sorted like the iPhone's: the account on top, then music, books, general, other accounts, about. */
@Composable
fun SettingsScreen() {
    val context = LocalContext.current
    val app = context.tonalo
    val nav = LocalNav.current
    val accounts by app.accountList.collectAsState()
    val current by app.current.collectAsState()
    val atHome by app.atHome.collectAsState()
    val pairings by TvLink.pairings.collectAsState()
    val hosting by JukeboxHost.running.collectAsState()
    val booksConnected by app.books.connected.collectAsState()
    val bookDownloads by BookDownloads.books.collectAsState()
    val bookBytes = bookDownloads.sumOf { it.bytes }
    var logout by remember { mutableStateOf<Account?>(null) }
    var removeOther by remember { mutableStateOf<Account?>(null) }

    GroupedPage(stringResource(R.string.tab_settings)) {
        current?.let { acc ->
            item {
                Group {
                    GroupRow(icon = { NameAvatar(acc.username, 56.dp) }) {
                        Text(acc.username, fontSize = 22.sp, fontWeight = FontWeight.Bold)
                        if (atHome) Row(Modifier.padding(top = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.Home, null, tint = Palette.accent, modifier = Modifier.size(14.dp))
                            Spacer(Modifier.width(4.dp))
                            Text(stringResource(R.string.at_home), color = Palette.accent, style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            }
            item {
                Group(stringResource(R.string.music)) {
                    // An audiobooks-only account has no music server: the same page adds one
                    if (acc.hasMusic) NavRow(stringResource(R.string.server), acc.host) { nav.open("account/" + android.net.Uri.encode(acc.id)) }
                    else NavRow(stringResource(R.string.server), stringResource(R.string.not_connected), sub = stringResource(R.string.bka_add_music)) {
                        nav.open("account/" + android.net.Uri.encode(acc.id))
                    }
                    if (acc.hasMusic) {
                        NavRow(stringResource(R.string.audio_quality)) { nav.navigate("settings/quality") }
                        NavRow(stringResource(R.string.playback)) { nav.navigate("settings/playback") }
                        NavRow(stringResource(R.string.dj)) { nav.navigate("dj/settings") }
                        NavRow(stringResource(R.string.offline)) { nav.navigate("settings/offline") }
                        NavRow(stringResource(R.string.devices_title), pairings.firstOrNull { it.guest != true }?.name ?: stringResource(R.string.not_connected)) {
                            nav.navigate("devices")
                        }
                        NavRow(stringResource(R.string.jukebox), stringResource(if (hosting) R.string.jukebox_on else R.string.off)) { nav.navigate("jukebox") }
                    }
                }
            }
            item {
                Group(stringResource(R.string.books_podcasts)) {
                    NavRow(stringResource(R.string.server), acc.audiobooks?.host ?: stringResource(R.string.not_connected)) { nav.open("settings/audiobookshelf") }
                    if (booksConnected) {
                        NavRow(stringResource(R.string.bpl_settings_title)) { nav.open("settings/bookplayback") }
                        NavRow(stringResource(R.string.downloads), android.text.format.Formatter.formatShortFileSize(context, bookBytes)) { nav.open("downloads") }
                    }
                }
            }
        }
        item {
            Group(stringResource(R.string.general)) {
                NavRow(stringResource(R.string.appearance)) { nav.navigate("settings/appearance") }
            }
        }
        item {
            Group(stringResource(R.string.other_accounts), footer = stringResource(R.string.other_accounts_info)) {
                accounts.filter { it.id != current?.id }.forEach { acc ->
                    GroupRow({ app.select(acc.id) }, icon = { NameAvatar(acc.username, 34.dp) }, trailing = {
                        Text(stringResource(R.string.switch_account), color = Palette.accent, style = MaterialTheme.typography.bodyMedium,
                            modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { app.select(acc.id) }.padding(6.dp))
                        Text("✕", color = Palette.subtle, modifier = Modifier.clip(CircleShape).clickable { removeOther = acc }.padding(8.dp))
                    }) {
                        Text(acc.username, style = MaterialTheme.typography.bodyLarge)
                        Text(acc.host, color = Palette.secondaryText, style = MaterialTheme.typography.bodySmall)
                    }
                }
                ActionRow(stringResource(R.string.add_other_account), Icons.Default.Add) { nav.navigate("account/new") }
            }
        }
        item {
            Group(stringResource(R.string.info), footer = stringResource(R.string.unofficial)) {
                val version = runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: "–"
                ValueRow(stringResource(R.string.version_label), version)
                NavRow(stringResource(R.string.whats_new)) { nav.navigate("settings/news") }
                LinkRow(stringResource(R.string.github)) {
                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://github.com/Wzkiie/tonalo")))
                }
            }
        }
        current?.let { acc ->
            item { Group { ActionRow(stringResource(R.string.sign_out), destructive = true, centered = true) { logout = acc } } }
        }
    }

    logout?.let { LogoutDialog(it) { logout = null } }
    removeOther?.let { LogoutDialog(it) { removeOther = null } }
}

@Composable
private fun qualityLabel(q: AudioQuality): String = if (q == AudioQuality.LOSSLESS) stringResource(R.string.original_files) else q.title

@Composable
fun QualitySettingsScreen() {
    val s = LocalContext.current.tonalo.settings
    val wifi by s.wifiQuality.collectAsState()
    val mobile by s.mobileQuality.collectAsState()
    val download by s.downloadQuality.collectAsState()
    GroupedPage(stringResource(R.string.audio_quality)) {
        item {
            Group(footer = stringResource(R.string.quality_footer)) {
                PickerRow(stringResource(R.string.wifi), wifi, AudioQuality.entries, label = { qualityLabel(it) }) { s.setWifiQuality(it) }
                PickerRow(stringResource(R.string.mobile_data), mobile, AudioQuality.entries, label = { qualityLabel(it) }) { s.setMobileQuality(it) }
                PickerRow(stringResource(R.string.downloads), download, AudioQuality.entries, label = { qualityLabel(it) }) { s.setDownloadQuality(it) }
            }
        }
    }
}

@Composable
fun PlaybackSettingsScreen() {
    val s = LocalContext.current.tonalo.settings
    val crossfade by s.crossfade.collectAsState()
    val leveling by s.leveling.collectAsState()
    val autoplay by s.autoplay.collectAsState()
    val scrobble by s.scrobble.collectAsState()
    val syncQueue by s.syncQueue.collectAsState()
    val eqOn by s.eqEnabled.collectAsState()
    val eqPreset by s.eqPreset.collectAsState()
    val nav = LocalNav.current
    GroupedPage(stringResource(R.string.playback)) {
        item {
            Group {
                NavRow(stringResource(R.string.equalizer), if (eqOn) eqPresetName(eqPreset) else stringResource(R.string.off)) { nav.navigate("settings/eq") }
            }
        }
        item {
            Group(footer = stringResource(R.string.playback_footer)) {
                GroupBox {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(stringResource(R.string.crossfade), Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
                        Text(if (crossfade == 0) stringResource(R.string.off) else stringResource(R.string.seconds, crossfade), color = Palette.secondaryText)
                    }
                    Slider(
                        crossfade.toFloat(), { s.setCrossfade(it.toInt()) }, valueRange = 0f..12f, steps = 11,
                        colors = SliderDefaults.colors(thumbColor = Color.White, activeTrackColor = Palette.accent, inactiveTrackColor = Palette.elevated,
                            activeTickColor = Color.Transparent, inactiveTickColor = Color.Transparent),
                    )
                }
                PickerRow(stringResource(R.string.leveling), leveling, VolumeLeveling.entries, label = {
                    stringResource(when (it) {
                        VolumeLeveling.OFF -> R.string.leveling_off
                        VolumeLeveling.TRACK -> R.string.leveling_track
                        VolumeLeveling.ALBUM -> R.string.leveling_album
                    })
                }) { s.setLeveling(it) }
                ToggleRow(stringResource(R.string.autoplay), autoplay) { s.setAutoplay(it) }
                ToggleRow(stringResource(R.string.scrobble), scrobble) { s.setScrobble(it) }
            }
        }
        item {
            Group(footer = stringResource(R.string.sync_queue_info)) {
                ToggleRow(stringResource(R.string.sync_queue), syncQueue) { s.setSyncQueue(it) }
            }
        }
    }
}

@Composable
fun OfflineSettingsScreen() {
    val context = LocalContext.current
    val app = context.tonalo
    val nav = LocalNav.current
    val current by app.current.collectAsState()
    val downloads by Downloads.all.collectAsState()
    val downloaded = Downloads.forAccount(downloads, current?.id).filter { it.done }
    var removeAll by remember { mutableStateOf(false) }
    GroupedPage(stringResource(R.string.offline)) {
        item {
            Group(footer = stringResource(R.string.offline_footer)) {
                NavRow(stringResource(R.string.downloaded_music), pluralString(R.plurals.song_count, downloaded.size)) { nav.navigate("downloads") }
            }
        }
        if (downloaded.isNotEmpty()) item {
            Group { ActionRow(stringResource(R.string.remove_all_downloads), destructive = true) { removeAll = true } }
        }
    }
    if (removeAll) androidx.compose.material3.AlertDialog(
        onDismissRequest = { removeAll = false },
        containerColor = Palette.elevated,
        text = { Text(stringResource(R.string.remove_all_downloads_confirm, downloaded.size)) },
        confirmButton = {
            androidx.compose.material3.TextButton(onClick = { Downloads.remove(context, downloaded.map { it.song.id }); removeAll = false }) {
                Text(stringResource(R.string.remove), color = Color(0xFFFF5A5F))
            }
        },
        dismissButton = { androidx.compose.material3.TextButton(onClick = { removeAll = false }) { Text(stringResource(R.string.cancel)) } },
    )
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun AppearanceScreen() {
    val s = LocalContext.current.tonalo.settings
    val accent by s.accent.collectAsState()
    val backdrop by s.backdrop.collectAsState()
    val shape by s.cardShape.collectAsState()
    val coverSize by s.coverSize.collectAsState()
    val coverTint by s.coverTint.collectAsState()
    val lyricsFirst by s.lyricsFirst.collectAsState()
    val startTab by s.startTab.collectAsState()
    val hidden by s.hiddenHomeRows.collectAsState()
    GroupedPage(stringResource(R.string.appearance)) {
        item {
            Group(stringResource(R.string.accent_color)) {
                GroupBox {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(14.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                        Settings.accentPresets.forEach { hex ->
                            val color = Palette.parse(hex) ?: Color.Gray
                            val selected = hex.equals(accent, ignoreCase = true)
                            Box(
                                Modifier.size(52.dp).then(if (selected) Modifier.border(2.dp, Color.White, CircleShape) else Modifier)
                                    .padding(4.dp).clip(CircleShape).background(color).clickable { s.setAccent(hex) },
                                contentAlignment = Alignment.Center,
                            ) { if (selected) Icon(Icons.Default.Check, null, tint = Color.Black, modifier = Modifier.size(20.dp)) }
                        }
                    }
                }
            }
        }
        item {
            Group(stringResource(R.string.look), footer = stringResource(R.string.cover_size_info)) {
                PickerRow(stringResource(R.string.background), backdrop, listOf(Backdrop.GRAY, Backdrop.BLACK),
                    label = { stringResource(if (it == Backdrop.BLACK) R.string.background_black else R.string.background_gray) }) { s.setBackdrop(it) }
                PickerRow(stringResource(R.string.corners), shape, CardShape.entries, label = {
                    stringResource(when (it) {
                        CardShape.SHARP -> R.string.corners_sharp
                        CardShape.STANDARD -> R.string.corners_standard
                        CardShape.ROUND -> R.string.corners_round
                    })
                }) { s.setCardShape(it) }
                PickerRow(stringResource(R.string.cover_size), coverSize, CoverSize.entries, label = {
                    stringResource(when (it) {
                        CoverSize.SMALL -> R.string.size_small
                        CoverSize.STANDARD -> R.string.size_standard
                        CoverSize.LARGE -> R.string.size_large
                    })
                }) { s.setCoverSize(it) }
            }
        }
        item {
            Group(stringResource(R.string.behavior)) {
                ToggleRow(stringResource(R.string.cover_tint), coverTint) { s.setCoverTint(it) }
                ToggleRow(stringResource(R.string.lyrics_first), lyricsFirst) { s.setLyricsFirst(it) }
                PickerRow(stringResource(R.string.start_screen), startTab, listOf(0, 1, 2), label = {
                    stringResource(when (it) { 0 -> R.string.tab_home; 1 -> R.string.tab_search; else -> R.string.tab_library })
                }) { s.setStartTab(it) }
            }
        }
        item {
            Group(stringResource(R.string.home_rows)) {
                homeRows.forEach { (id, title) ->
                    ToggleRow(stringResource(title), id !in hidden.split(",")) { s.setHomeRowShown(id, it) }
                }
            }
        }
        item {
            Group {
                ActionRow(stringResource(R.string.reset_defaults), destructive = true) {
                    s.setAccent(Settings.DEFAULT_ACCENT); s.setBackdrop(Backdrop.GRAY); s.setCardShape(CardShape.STANDARD)
                    s.setCoverSize(CoverSize.STANDARD); s.setCoverTint(true); s.setLyricsFirst(false); s.setStartTab(0)
                    homeRows.forEach { (id, _) -> s.setHomeRowShown(id, true) }
                }
            }
        }
    }
}

/** What changed in each Android version, newest first (the content lives in WhatsNew.kt). */
@Composable
fun WhatsNewScreen() {
    GroupedPage(stringResource(R.string.whats_new)) { versionHistory() }
}

@Composable
fun AccountEditScreen(id: String) {
    val nav = LocalNav.current
    val accounts by LocalContext.current.tonalo.accountList.collectAsState()
    val account = accounts.firstOrNull { it.id == id } ?: return
    LoginScreen(editing = account, onClose = { nav.popBackStack() })
}
