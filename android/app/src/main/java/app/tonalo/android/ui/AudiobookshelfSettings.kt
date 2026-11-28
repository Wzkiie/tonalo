package app.tonalo.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Error
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import app.tonalo.android.R
import app.tonalo.android.data.HeaderField
import app.tonalo.android.data.SubsonicClient
import app.tonalo.android.data.bookErrorText
import app.tonalo.android.data.headerValid
import app.tonalo.android.tonalo
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

private enum class AbsPage { MAIN, HOME, HEADERS }

/** The custom headers of the Audiobookshelf settings, kept over a turn of the screen (they are secrets, so not in the saved state). */
class AbsForm : androidx.lifecycle.ViewModel() {
    val headers = mutableStateListOf<HeaderField>()
    var filled = false
}

/**
 * Settings > Audiobooks & podcasts > Server (AudiobookshelfSettingsView of the iPhone app): connect this account to an
 * Audiobookshelf server – or, when connected, change where it is found (address, address at home, custom headers),
 * and disconnect. Route "settings/audiobookshelf".
 */
@Composable
fun AudiobookshelfSettingsScreen() {
    val context = LocalContext.current
    val app = context.tonalo
    val books = app.books
    val scope = rememberCoroutineScope()
    val account by app.current.collectAsState()
    val atHome by books.atHome.collectAsState()
    val canDownload by books.canDownload.collectAsState()
    val stored = account?.audiobooks
    val form: AbsForm = androidx.lifecycle.viewmodel.compose.viewModel(key = "abs-" + (account?.id ?: ""))

    var address by rememberSaveable { mutableStateOf("") }
    var username by rememberSaveable { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var home by rememberSaveable { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var page by rememberSaveable { mutableStateOf(AbsPage.MAIN) }
    var confirm by remember { mutableStateOf(false) }

    fun fill() {
        form.filled = true
        val s = account?.audiobooks ?: return
        address = s.url
        home = s.localURL ?: ""
        form.headers.clear()
        form.headers.addAll(s.headers)
    }
    // Coming back from the pages for home address and headers keeps what was typed
    if (!form.filled) fill()

    val named = form.headers.filter { it.name.isNotBlank() }.map { it.copy(name = it.name.trim()) }
    val homeValid = home.isBlank() || SubsonicClient.isLocal(home)
    val headersOk = form.headers.none { if (it.name.isNotBlank()) !headerValid(it.name, it.value) else it.value.isNotEmpty() }
    val plain = address.trim().lowercase().startsWith("http://") && !SubsonicClient.isLocal(address)
    val changed = stored != null && (
        SubsonicClient.normalize(address) != stored.url || SubsonicClient.normalizeLocal(home) != stored.localURL ||
            named.map { it.name to it.value } != stored.headers.map { it.name to it.value }
        )
    val musicHeaders = account?.headers.orEmpty()

    fun attempt(block: suspend () -> Unit) {
        if (!headersOk) { error = context.getString(R.string.header_invalid); return }
        if (!homeValid) { error = context.getString(R.string.home_only); return }
        scope.launch {
            busy = true
            try {
                block()
                error = null
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                error = e.bookErrorText(context)
            } finally {
                busy = false
            }
        }
    }

    BackHandler(enabled = page != AbsPage.MAIN) { page = AbsPage.MAIN }
    when (page) {
        AbsPage.HOME -> { HomeAddressPage(home, { home = it }, stringResource(R.string.bka_abs_home_hint)) { page = AbsPage.MAIN }; return }
        AbsPage.HEADERS -> { HeadersPage(form.headers) { page = AbsPage.MAIN }; return }
        AbsPage.MAIN -> Unit
    }

    /** Home address, headers and whatever they can come from: the same whether signing in or changing them later. */
    @Composable
    fun RouteRows() {
        NavRow(stringResource(R.string.address_at_home), home.ifEmpty { stringResource(R.string.off) }) { page = AbsPage.HOME }
        NavRow(stringResource(R.string.custom_headers), if (named.isEmpty()) stringResource(R.string.none) else "${named.size}") { page = AbsPage.HEADERS }
        if (named.isEmpty() && musicHeaders.isNotEmpty()) {
            ActionRow(stringResource(R.string.bka_use_music_headers)) {
                form.headers.clear()
                form.headers.addAll(musicHeaders.map { HeaderField(name = it.name, value = it.value) })
            }
        }
    }

    GroupedPage(stringResource(R.string.bka_abs)) {
        if (stored != null) {
            item {
                Group(
                    stringResource(R.string.server_address),
                    footer = stringResource(if (plain) R.string.bka_http_login_warning else R.string.bka_server_footer),
                ) {
                    FieldRow(address, { address = it }, stringResource(R.string.bka_abs_hint),
                        keyboard = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false))
                }
            }
            item { Group(footer = stringResource(R.string.bka_route_footer)) { RouteRows() } }
            if (changed) {
                error?.let { item { Notice(Icons.Default.Error, it, Color(0xFFFF5A5F), Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) } }
                item {
                    Group {
                        if (busy) GroupRow { Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp) } }
                        else ActionRow(stringResource(R.string.save), enabled = address.isNotBlank() && homeValid) {
                            attempt { books.updateConnection(address, home.ifBlank { null }, named); fill() }
                        }
                    }
                }
            }
            item {
                Group(footer = stringResource(R.string.bka_connected_footer)) {
                    ValueRow(stringResource(R.string.bka_user), stored.username)
                    if (stored.localURL != null) {
                        ValueRow(stringResource(R.string.bka_connected_through), stringResource(if (atHome) R.string.address_at_home else R.string.server_address))
                    }
                    if (!canDownload) GroupRow {
                        Text(stringResource(R.string.bka_not_allowed_download), color = Color(0xFFFF9F0A), style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
            item {
                Group {
                    // Without a music server this account has nothing left
                    if (account?.hasMusic == false) ActionRow(stringResource(R.string.bka_remove_account), destructive = true) { confirm = true }
                    else ActionRow(stringResource(R.string.bka_disconnect), destructive = true) { confirm = true }
                }
            }
        } else {
            item {
                Group(
                    stringResource(R.string.server),
                    footer = stringResource(if (plain) R.string.bka_http_password_warning else R.string.bka_vpn_footer),
                ) {
                    FieldRow(address, { address = it }, stringResource(R.string.bka_abs_hint),
                        keyboard = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false))
                }
            }
            item {
                Group(stringResource(R.string.login_section)) {
                    FieldRow(username, { username = it }, stringResource(R.string.username), keyboard = KeyboardOptions(autoCorrectEnabled = false))
                    FieldRow(password, { password = it }, stringResource(R.string.password), password = true,
                        keyboard = KeyboardOptions(keyboardType = KeyboardType.Password))
                }
            }
            item { Group(footer = stringResource(R.string.bka_books_login_footer)) { RouteRows() } }
            error?.let { item { Notice(Icons.Default.Error, it, Color(0xFFFF5A5F), Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) } }
            item {
                Group {
                    if (busy) GroupRow { Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp) } }
                    else ActionRow(
                        stringResource(R.string.bka_connect),
                        enabled = address.isNotBlank() && username.isNotBlank() && password.isNotEmpty() && homeValid,
                    ) {
                        attempt {
                            books.connect(address, username.trim(), password, named, home.ifBlank { null })
                            password = ""
                            fill()
                        }
                    }
                }
            }
        }
    }

    if (confirm) {
        val acc = account
        if (acc != null && !acc.hasMusic) {
            LogoutDialog(acc) { confirm = false }
        } else AlertDialog(
            onDismissRequest = { confirm = false },
            containerColor = Palette.elevated,
            title = { Text(stringResource(R.string.bka_disconnect_abs_q)) },
            text = { Text(stringResource(R.string.bka_disconnect_abs_text), style = MaterialTheme.typography.bodyMedium) },
            confirmButton = {
                TextButton(onClick = { confirm = false; form.filled = false; books.disconnect() }) {
                    Text(stringResource(R.string.bka_disconnect), color = Color(0xFFFF5A5F))
                }
            },
            dismissButton = { TextButton(onClick = { confirm = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}
