package app.tonalo.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.tonalo.android.R
import app.tonalo.android.link.JukeboxHost
import app.tonalo.android.link.LinkDevice
import app.tonalo.android.link.PairResult
import app.tonalo.android.link.TvLink
import kotlinx.coroutines.launch

private val LinkDevice.icon: ImageVector get() = if (isPhone) Icons.Default.PhoneAndroid else if (isPC) Icons.Default.Computer else Icons.Default.Tv

/**
 * TV & Jukebox: the own TV or computer (paired once, then it's a remote control), Jukeboxes nearby to join
 * as a guest, and this phone's own Jukebox.
 */
@Composable
fun DevicesScreen(jukebox: Boolean = false) {
    val devices by TvLink.devices.collectAsState()
    val pairings by TvLink.pairings.collectAsState()
    val remote by TvLink.remote.collectAsState()
    val ownTv by TvLink.ownTv.collectAsState()
    val guestOnly by TvLink.guestOnly.collectAsState()
    val joined by TvLink.jukebox.collectAsState()
    val hosting by JukeboxHost.running.collectAsState()
    val guests by JukeboxHost.guests.collectAsState()
    val present by JukeboxHost.present.collectAsState()
    var pairWith by remember { mutableStateOf<Pair<LinkDevice, Boolean>?>(null) }
    var byAddress by remember { mutableStateOf(false) }

    val own = devices.filter { d -> !d.isPhone && pairings.any { it.tv == d.id && it.guest != true } }
    val unpaired = devices.filter { d -> !d.isPhone && pairings.none { it.tv == d.id } }
    val jukeboxes = devices.filter { d -> d.isPhone || d.id in guestOnly || pairings.any { it.tv == d.id && it.guest == true } }

    val accent = Palette.accent
    val deviceIcon = @Composable { d: LinkDevice, on: Boolean -> Icon(d.icon, null, tint = if (on) accent else Palette.secondaryText, modifier = Modifier.size(26.dp)) }
    GroupedPage(stringResource(if (jukebox) R.string.jukebox else R.string.devices_title)) {
        if (!jukebox) {
            item {
                Group(stringResource(R.string.your_devices), footer = stringResource(R.string.your_devices_info)) {
                    own.forEach { d ->
                        val status = when {
                            remote?.device?.id == d.id -> stringResource(R.string.playing_on, d.name)
                            d.id in guestOnly -> stringResource(R.string.own_tv_other_account)
                            ownTv?.id == d.id -> stringResource(R.string.connected)
                            else -> null
                        }
                        GroupRow(icon = { deviceIcon(d, ownTv?.id == d.id) },
                            trailing = { IconButton(onClick = { TvLink.unpair(d.id) }) { Icon(Icons.Default.Close, stringResource(R.string.remove), tint = Palette.subtle) } }) {
                            Text(d.name, style = MaterialTheme.typography.bodyLarge)
                            if (status != null) Text(status, color = Palette.secondaryText, style = MaterialTheme.typography.bodySmall)
                        }
                    }
                    if (own.isEmpty()) ValueRow(stringResource(R.string.not_connected), null)
                }
            }
            item {
                Group(stringResource(R.string.nearby), footer = if (unpaired.isEmpty()) stringResource(R.string.nothing_nearby) else null) {
                    unpaired.forEach { d ->
                        GroupRow({ pairWith = d to false }, icon = { deviceIcon(d, false) },
                            trailing = { Text(stringResource(R.string.pair), color = accent, style = MaterialTheme.typography.bodyMedium) }) {
                            Text(d.name, style = MaterialTheme.typography.bodyLarge)
                        }
                    }
                    ActionRow(stringResource(R.string.add_by_address), Icons.Default.Add) { byAddress = true }
                }
            }
        } else {
            item {
                Group(stringResource(R.string.your_jukebox), footer = stringResource(R.string.host_jukebox_info)) {
                    ToggleRow(stringResource(R.string.host_jukebox), hosting) { if (it) JukeboxHost.start() else JukeboxHost.stop() }
                    guests.forEach { g ->
                        GroupRow(icon = { NameAvatar(g.name, 30.dp) },
                            trailing = { IconButton(onClick = { JukeboxHost.remove(g) }) { Icon(Icons.Default.Close, stringResource(R.string.remove), tint = Palette.subtle) } }) {
                            Text(g.name, style = MaterialTheme.typography.bodyLarge)
                            if (g.name in present) Text(stringResource(R.string.here), color = accent, style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            }
            item {
                Group(stringResource(R.string.join_jukebox), footer = stringResource(R.string.join_jukebox_info)) {
                    jukeboxes.forEach { d ->
                        val paired = pairings.any { it.tv == d.id }
                        val isJoined = joined == d.id
                        GroupRow(icon = { deviceIcon(d, isJoined) }, trailing = {
                            TextButton(onClick = {
                                when {
                                    isJoined -> TvLink.leave()
                                    paired -> TvLink.join(d)
                                    else -> pairWith = d to true
                                }
                            }) { Text(stringResource(if (isJoined) R.string.leave else R.string.join), color = accent) }
                        }) {
                            Text(d.name, style = MaterialTheme.typography.bodyLarge)
                            if (isJoined) Text(stringResource(R.string.joined), color = accent, style = MaterialTheme.typography.bodySmall)
                        }
                    }
                    if (jukeboxes.isEmpty()) ValueRow(stringResource(R.string.nothing_nearby), null)
                }
            }
        }
    }

    pairWith?.let { (d, guest) -> PairDialog(d, guest) { pairWith = null } }
    if (byAddress) AddressDialog { found -> byAddress = false; if (found != null) pairWith = found to false }
}

@Composable
private fun Info(text: String) {
    Text(text, Modifier.padding(horizontal = 16.dp, vertical = 4.dp), color = Palette.secondaryText, style = MaterialTheme.typography.bodySmall)
}

/** Asks the other screen to show a code, then the code is typed in here. */
@Composable
private fun PairDialog(device: LinkDevice, guest: Boolean, onDone: () -> Unit) {
    val scope = rememberCoroutineScope()
    var code by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(true) }
    val context = LocalContext.current
    LaunchedEffect(device.id) {
        val status = TvLink.startPairing(device, guest)
        busy = false
        if (status != 200) error = context.getString(when (status) { 503 -> R.string.pair_not_ready; 409 -> R.string.pair_other_profile; else -> R.string.pair_failed }, device.name)
    }
    AlertDialog(
        onDismissRequest = onDone,
        title = { Text(stringResource(R.string.pair_title, device.name)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(stringResource(R.string.pair_enter_code, device.name))
                OutlinedTextField(
                    code, { code = it.filter(Char::isDigit).take(6) }, Modifier.fillMaxWidth(),
                    label = { Text(stringResource(R.string.pair_code)) }, singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword),
                    textStyle = MaterialTheme.typography.headlineSmall.copy(letterSpacing = 6.sp, textAlign = TextAlign.Center),
                )
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                if (busy) CircularProgressIndicator(Modifier.size(24.dp).align(Alignment.CenterHorizontally))
            }
        },
        confirmButton = {
            Button(enabled = code.length == 6 && !busy, onClick = {
                busy = true
                scope.launch {
                    when (TvLink.finishPairing(device, code, guest)) {
                        PairResult.OK -> onDone()
                        PairResult.WRONG_CODE -> { error = context.getString(R.string.pair_wrong); code = "" }
                        PairResult.EXPIRED -> error = context.getString(R.string.pair_expired)
                        PairResult.FAILED -> error = context.getString(R.string.pair_failed, device.name)
                    }
                    busy = false
                }
            }) { Text(stringResource(R.string.pair)) }
        },
        dismissButton = { TextButton(onClick = onDone) { Text(stringResource(R.string.cancel)) } },
    )
}

@Composable
private fun AddressDialog(onDone: (LinkDevice?) -> Unit) {
    val scope = rememberCoroutineScope()
    var address by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val notFound = stringResource(R.string.address_not_found)
    AlertDialog(
        onDismissRequest = { onDone(null) },
        title = { Text(stringResource(R.string.add_by_address)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(address, { address = it }, Modifier.fillMaxWidth(), singleLine = true,
                    placeholder = { Text(stringResource(R.string.address_hint)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri))
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
        },
        confirmButton = {
            Button(enabled = address.isNotBlank() && !busy, onClick = {
                busy = true
                scope.launch {
                    val d = TvLink.addByAddress(address)
                    busy = false
                    if (d == null) error = notFound else onDone(d)
                }
            }) { Text(stringResource(R.string.pair)) }
        },
        dismissButton = { TextButton(onClick = { onDone(null) }) { Text(stringResource(R.string.cancel)) } },
    )
}

/** A guest wants to join this phone's Jukebox: the code, big. Shown over every page. */
@Composable
fun JukeboxRequestDialog() {
    val request by JukeboxHost.request.collectAsState()
    val r = request ?: return
    AlertDialog(
        onDismissRequest = {},
        title = { Text(stringResource(R.string.wants_to_join, r.name), textAlign = TextAlign.Center) },
        text = {
            Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(r.code.chunked(3).joinToString(" "), fontSize = 44.sp, fontWeight = FontWeight.Bold, letterSpacing = 4.sp, color = Color.White)
                Text(stringResource(R.string.show_code, r.name), color = Palette.secondaryText, textAlign = TextAlign.Center)
            }
        },
        confirmButton = { TextButton(onClick = { JukeboxHost.cancelRequest() }) { Text(stringResource(R.string.cancel)) } },
    )
}
