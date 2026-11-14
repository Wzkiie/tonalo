package app.tonalo.android.ui

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import app.tonalo.android.R
import app.tonalo.android.dj.DJ
import app.tonalo.android.dj.DJError
import app.tonalo.android.dj.DJProvider
import app.tonalo.android.link.TvLink
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.io.IOException

private val djColors = listOf(Color(0xFF7B5CFF), Color(0xFFFF5FA2))

fun djMessage(context: Context, e: Throwable): String = when (e) {
    is DJError.NotReady -> context.getString(R.string.dj_err_not_ready)
    is DJError.NoTakeOver -> context.getString(R.string.dj_err_take_over)
    is DJError.NotPlaying -> context.getString(R.string.dj_err_not_playing)
    is DJError.Address -> context.getString(R.string.dj_err_address)
    is DJError.Key -> context.getString(R.string.dj_err_key)
    is DJError.Limit -> context.getString(R.string.dj_err_limit)
    is DJError.Refused -> context.getString(R.string.dj_err_refused)
    is DJError.Library -> context.getString(R.string.dj_err_library)
    is DJError.Answer -> context.getString(R.string.dj_err_answer) + if (e.got.isNotEmpty()) "\n\n" + e.got else ""
    is DJError.Status -> context.getString(R.string.dj_err_status, e.code)
    is IOException -> context.getString(R.string.dj_err_network)
    else -> context.getString(R.string.dj_err_network)
}

/** The DJ's art: a purple-to-pink square with sparkles. */
@Composable
fun DJArt(modifier: Modifier = Modifier.fillMaxSize()) {
    Box(
        modifier.background(Brush.linearGradient(listOf(Color(0xFF3D3D3D), Color(0xFF1F1F1F))))
            .background(Brush.linearGradient(listOf(Palette.accent.copy(alpha = 0.22f), Palette.accent.copy(alpha = 0.06f)))),
        contentAlignment = Alignment.Center,
    ) { DJMark(Modifier.fillMaxSize(0.54f), Palette.accent) }
}

/**
 * The DJ's own mark, like the iPhone's: a record, open at the top right where the needle sits,
 * with Tonalo's three bars in the middle.
 */
@Composable
fun DJMark(modifier: Modifier, color: Color) {
    androidx.compose.foundation.Canvas(modifier) {
        val s = minOf(size.width, size.height)
        val line = s * 0.1f
        val r = (s - line) / 2
        val c = androidx.compose.ui.geometry.Offset(size.width / 2, size.height / 2)
        // The ring: 84 % of a circle, the gap around the top right
        drawArc(
            color, startAngle = -16.2f, sweepAngle = 360f * 0.84f, useCenter = false,
            topLeft = androidx.compose.ui.geometry.Offset(c.x - r, c.y - r), size = androidx.compose.ui.geometry.Size(r * 2, r * 2),
            style = androidx.compose.ui.graphics.drawscope.Stroke(width = line, cap = androidx.compose.ui.graphics.StrokeCap.Round),
        )
        drawCircle(color, radius = line * 0.625f, center = androidx.compose.ui.geometry.Offset(c.x + r * 0.7071f, c.y - r * 0.7071f))
        val gap = s * 0.07f
        val heights = listOf(0.22f, 0.40f, 0.30f)
        var x = c.x - (line * 3 + gap * 2) / 2
        heights.forEach { h ->
            val hh = s * h
            drawRoundRect(color, topLeft = androidx.compose.ui.geometry.Offset(x, c.y - hh / 2),
                size = androidx.compose.ui.geometry.Size(line, hh), cornerRadius = androidx.compose.ui.geometry.CornerRadius(line / 2))
            x += line + gap
        }
    }
}

/** The DJ page: what it plays, more / something else / moods / a wish, and stop. Starts the DJ when it isn't running. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun DJScreen() {
    val context = LocalContext.current
    val nav = LocalNav.current
    val player = LocalPlayer.current
    val snackbar = LocalSnackbar.current
    val scope = rememberCoroutineScope()
    val localActive by DJ.active.collectAsState()
    val remote by TvLink.remote.collectAsState()
    // On the own TV the DJ is what the TV reports as playing from it
    val active = if (remote != null) remote?.guest == false && remote?.state?.context?.kind == "dj" else localActive
    val line by DJ.line.collectAsState()
    val busy by DJ.busy.collectAsState()
    val state by player.state.collectAsState()
    var wish by remember { mutableStateOf("") }

    fun run(block: suspend () -> Unit) = scope.launch {
        try { block() } catch (e: CancellationException) { throw e } catch (e: Exception) { snackbar.showSnackbar(djMessage(context, e)) }
    }

    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(djColors[0].darken(0.55f), Palette.canvas), endY = 1400f))) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).statusBarsPadding().padding(horizontal = 20.dp)) {
            Row(Modifier.fillMaxWidth().padding(top = 64.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(84.dp).clip(RoundedCornerShape(6.dp))) { DJArt() }
                Spacer(Modifier.size(16.dp))
                Column(Modifier.weight(1f)) {
                    Text(stringResource(R.string.dj), style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
                    Text(
                        if (busy) stringResource(R.string.dj_choosing).uppercase() else line ?: stringResource(R.string.dj_tile),
                        color = Color.White.copy(alpha = 0.75f), style = MaterialTheme.typography.bodyMedium,
                    )
                }
                if (busy) CircularProgressIndicator(Modifier.size(24.dp), color = Color.White, strokeWidth = 2.dp)
            }

            if (active) {
                state.current?.let { s ->
                    Row(Modifier.padding(top = 24.dp), verticalAlignment = Alignment.CenterVertically) {
                        Cover(s.coverArt, 48.dp, corner = 4.dp, pixels = 120)
                        Spacer(Modifier.size(12.dp))
                        Column {
                            Text(s.title, fontWeight = FontWeight.SemiBold)
                            Text(s.artist ?: "", color = Palette.secondaryText, style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
                Row(Modifier.fillMaxWidth().padding(top = 20.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Button(onClick = { run { DJ.change(DJ.Change.More, state.current) } }, enabled = !busy, modifier = Modifier.weight(1f)) {
                        Text(stringResource(R.string.more_like_this))
                    }
                    FilledTonalButton(onClick = { run { DJ.change(DJ.Change.Mood, state.current) } }, enabled = !busy, modifier = Modifier.weight(1f)) {
                        Text(stringResource(R.string.something_else))
                    }
                }
            }

            FlowRow(Modifier.padding(top = 20.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                val labels = mapOf(
                    "calm" to R.string.mood_calm, "energy" to R.string.mood_energy, "older" to R.string.mood_older,
                    "newer" to R.string.mood_newer, "favorites" to R.string.mood_favorites,
                )
                DJ.moods.forEach { (key, text) ->
                    Chip(stringResource(labels.getValue(key)), false) {
                        if (!busy) run { if (active) DJ.change(DJ.Change.Wish(text), state.current) else DJ.start(text) }
                    }
                }
            }

            OutlinedTextField(
                wish, { wish = it.take(200) }, Modifier.fillMaxWidth().padding(top = 20.dp),
                placeholder = { Text(stringResource(R.string.wish_hint)) },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                trailingIcon = {
                    IconButton(enabled = wish.isNotBlank() && !busy, onClick = {
                        val w = wish
                        wish = ""
                        run { if (active) DJ.change(DJ.Change.Wish(w), state.current) else DJ.start(w) }
                    }) { Icon(Icons.AutoMirrored.Filled.Send, stringResource(R.string.send_wish)) }
                },
            )
            Text(stringResource(R.string.wish_info, DJ.recipient), Modifier.padding(top = 6.dp), color = Palette.secondaryText, style = MaterialTheme.typography.bodySmall)

            Spacer(Modifier.height(24.dp))
            if (active) TextButton(onClick = { DJ.stop() }, modifier = Modifier.align(Alignment.CenterHorizontally)) {
                Text(stringResource(R.string.stop_dj), color = Palette.secondaryText)
            } else Button(onClick = { run { DJ.start() } }, enabled = !busy, modifier = Modifier.fillMaxWidth().height(52.dp)) {
                Text(stringResource(R.string.start_dj))
            }
            TextButton(onClick = { nav.navigate("dj/settings") }, modifier = Modifier.align(Alignment.CenterHorizontally)) {
                Icon(Icons.Default.Settings, null, Modifier.size(18.dp)); Spacer(Modifier.size(6.dp)); Text(stringResource(R.string.dj_settings))
            }
            Spacer(Modifier.height(24.dp))
        }
        RoundBackButton()
    }
}

/** Provider, key or address, model, a test, what is sent – and the switch, which asks for consent first. */
@Composable
fun DJSettingsScreen() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val enabled by DJ.enabled.collectAsState()
    val provider by DJ.provider.collectAsState()
    val model by DJ.model.collectAsState()
    val ollama by DJ.ollamaAddress.collectAsState()
    val share by DJ.shareWithDevices.collectAsState()
    val hasKey by DJ.hasKey.collectAsState()
    var key by remember { mutableStateOf("") }
    var models by remember(provider) { mutableStateOf(provider.fixedModels) }
    var loading by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<String?>(null) }
    var testing by remember { mutableStateOf(false) }
    var consent by remember { mutableStateOf(false) }
    var shareConsent by remember { mutableStateOf(false) }
    var preview by remember { mutableStateOf<String?>(null) }
    var pickModel by remember { mutableStateOf(false) }

    GroupedPage(stringResource(R.string.dj)) {
        item {
            Group(footer = stringResource(R.string.dj_intro)) {
                ToggleRow(stringResource(R.string.dj), enabled) { on -> if (on && !DJ.agreed(provider)) consent = true else DJ.setEnabled(on) }
            }
        }
        item {
            Group(stringResource(R.string.who_picks)) {
                DJProvider.entries.forEach { p ->
                    CheckRow(if (p == DJProvider.OLLAMA) stringResource(R.string.ollama_own) else p.title, p == provider) { DJ.setProvider(p); result = null }
                }
            }
        }
        item {
            Group(footer = if (provider.needsKey) stringResource(R.string.key_storage, DJ.recipient) else null) {
                if (provider == DJProvider.OLLAMA) {
                    FieldRow(ollama, { DJ.setOllamaAddress(it) }, "192.168.1.20:11434", title = stringResource(R.string.ollama_address),
                        keyboard = KeyboardOptions(keyboardType = KeyboardType.Uri))
                } else if (hasKey) {
                    ValueRow(stringResource(R.string.api_key), stringResource(R.string.key_saved, DJ.keyHint ?: ""))
                    ActionRow(stringResource(R.string.delete_key), destructive = true) { DJ.deleteKey(); models = provider.fixedModels }
                } else {
                    FieldRow(key, { key = it }, "sk-…", title = stringResource(R.string.api_key), password = true)
                    ActionRow(stringResource(R.string.save_key), enabled = key.isNotBlank()) { if (DJ.saveKey(key)) key = "" }
                }
            }
        }
        item {
            Group(stringResource(R.string.model), footer = if (provider == DJProvider.ANTHROPIC) stringResource(R.string.model_info) else null) {
                if (models.isNotEmpty()) PickerRow(stringResource(R.string.model), model, models.let { if (model in it || model.isBlank()) it else listOf(model) + it },
                    label = { it.ifBlank { "–" } }) { DJ.setModel(it) }
                if (provider != DJProvider.ANTHROPIC) FieldRow(model, { DJ.setModel(it) }, "llama3.1:8b", title = stringResource(R.string.model))
                if (provider != DJProvider.ANTHROPIC) ActionRow(stringResource(R.string.load_models), enabled = !loading) {
                    loading = true
                    scope.launch {
                        try { models = DJ.models() }
                        catch (e: CancellationException) { throw e } catch (e: Exception) { result = djMessage(context, e) }
                        loading = false
                    }
                }
                ActionRow(stringResource(R.string.test), enabled = !testing && DJ.configured) {
                    testing = true
                    scope.launch {
                        result = try { context.getString(R.string.test_ok, DJ.test()) }
                        catch (e: CancellationException) { throw e } catch (e: Exception) { djMessage(context, e) }
                        testing = false
                    }
                }
                if (loading || testing) GroupBox { LinearProgressIndicator(Modifier.fillMaxWidth(), color = Palette.accent, trackColor = Palette.elevated) }
                result?.let { GroupBox { Text(it, style = MaterialTheme.typography.bodyMedium) } }
            }
        }
        item {
            Group(stringResource(R.string.privacy_title), footer = stringResource(R.string.what_is_sent)) {
                NavRow(stringResource(R.string.show_sent)) { scope.launch { preview = DJ.preview() } }
                ToggleRow(stringResource(R.string.share_devices), share, sub = stringResource(R.string.share_info)) { on ->
                    if (on) shareConsent = true else DJ.setShare(false)
                }
            }
        }
    }

    if (consent) AlertDialog(
        onDismissRequest = { consent = false },
        title = { Text(stringResource(R.string.consent_title)) },
        text = { Text(stringResource(R.string.consent_text, DJ.recipient)) },
        confirmButton = { TextButton(onClick = { DJ.setEnabled(true); consent = false }) { Text(stringResource(R.string.agree)) } },
        dismissButton = { TextButton(onClick = { consent = false }) { Text(stringResource(R.string.cancel)) } },
    )
    if (shareConsent) AlertDialog(
        onDismissRequest = { shareConsent = false },
        title = { Text(stringResource(R.string.share_consent_title)) },
        text = { Text(stringResource(R.string.share_consent_text, DJ.recipient)) },
        confirmButton = { TextButton(onClick = { DJ.setShare(true); shareConsent = false }) { Text(stringResource(R.string.share)) } },
        dismissButton = { TextButton(onClick = { shareConsent = false }) { Text(stringResource(R.string.cancel)) } },
    )
    preview?.let { text ->
        AlertDialog(
            onDismissRequest = { preview = null },
            text = {
                Text(text.ifEmpty { stringResource(R.string.dj_err_library) }, Modifier.height(420.dp).verticalScroll(rememberScrollState()),
                    fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
            },
            confirmButton = { TextButton(onClick = { preview = null }) { Text("OK") } },
        )
    }
}
