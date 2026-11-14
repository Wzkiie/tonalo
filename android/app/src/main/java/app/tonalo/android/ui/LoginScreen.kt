package app.tonalo.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForwardIos
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Book
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.Cloud
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusDirection
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.tonalo.android.R
import app.tonalo.android.data.Account
import app.tonalo.android.data.AudiobookFiles
import app.tonalo.android.data.AudiobookServer
import app.tonalo.android.data.bookErrorText
import app.tonalo.android.data.HeaderField
import app.tonalo.android.data.SubsonicClient
import app.tonalo.android.data.headerValid
import app.tonalo.android.tonalo
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.io.IOException

private enum class LoginPage { MAIN, HOME, HEADERS, BOOK_HOME, BOOK_HEADERS }

/** What a new sign-in connects: music, audiobooks or both, each with its own address, login and headers. */
private enum class Service { MUSIC, BOOKS, BOTH }

/** The header lists of the sign-in, kept over a turn of the screen. */
class LoginForm : androidx.lifecycle.ViewModel() {
    val headers = mutableStateListOf<HeaderField>()
    /** The Audiobookshelf server's own headers. */
    val bookHeaders = mutableStateListOf<HeaderField>()
    var loaded = false
}

/** Everything typed on the sign-in. Passwords stay out of the saved state (a Bundle): a turned screen asks for them again. */
private class LoginFields(
    server: String = "", username: String = "", home: String = "",
    bookServer: String = "", bookUsername: String = "", bookHome: String = "",
    service: Service = Service.MUSIC, same: Boolean = false,
) {
    var server by mutableStateOf(server)
    var username by mutableStateOf(username)
    var home by mutableStateOf(home)
    var bookServer by mutableStateOf(bookServer)
    var bookUsername by mutableStateOf(bookUsername)
    var bookHome by mutableStateOf(bookHome)
    var service by mutableStateOf(service)
    /** The same headers for both, for when one Cloudflare Access token opens both servers. */
    var same by mutableStateOf(same)
    var password by mutableStateOf("")
    var bookPassword by mutableStateOf("")
}

private val FieldsSaver = listSaver<LoginFields, String>(
    save = { listOf(it.server, it.username, it.home, it.bookServer, it.bookUsername, it.bookHome, it.service.name, it.same.toString()) },
    restore = { LoginFields(it[0], it[1], it[2], it[3], it[4], it[5], Service.valueOf(it[6]), it[7].toBoolean()) },
)

/** Custom headers usually hold secrets – on plain http to a public address anyone on the way could read them. */
private fun plainOverInternet(address: String) = address.trim().lowercase().startsWith("http://") && !SubsonicClient.isLocal(address)

private fun invalidHeaders(list: List<HeaderField>) = list.any { if (it.name.isNotBlank()) !headerValid(it.name, it.value) else it.value.isNotEmpty() }

/**
 * Sign in to a server, or change an existing account ([editing]) – like the iPhone app: a new sign-in is the
 * logo, the service chips (music, audiobooks or both), the fields and one big button, the rest under "More options";
 * changing an account is a grouped page. The address at home and the custom headers open as their own pages.
 * The account is only saved once the server(s) answered with the login.
 */
@Composable
fun LoginScreen(editing: Account? = null, onClose: (() -> Unit)? = null) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val f = rememberSaveable(saver = FieldsSaver) {
        LoginFields(server = editing?.serverURL ?: "", username = editing?.takeIf { it.hasMusic }?.username ?: "", home = editing?.localURL ?: "")
    }
    // The headers are secrets too: a ViewModel keeps them over a turn of the screen without writing them into the saved state
    val form: LoginForm = androidx.lifecycle.viewmodel.compose.viewModel(key = "login-" + (editing?.id ?: "new"))
    if (!form.loaded) { form.headers.addAll(editing?.headers.orEmpty()); form.loaded = true }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var page by rememberSaveable { mutableStateOf(LoginPage.MAIN) }

    // Changing an account is always its music server; a new sign-in connects what the chips say
    val wantsMusic = editing != null || f.service != Service.BOOKS
    val wantsBooks = editing == null && f.service != Service.MUSIC
    val named = form.headers.filter { it.name.isNotBlank() }
    val namedBook = form.bookHeaders.filter { it.name.isNotBlank() }
    val canSave = !busy && if (editing != null) {
        // An audiobooks-only account can get a music server here, which needs a password the first time
        f.server.isNotBlank() && f.username.isNotBlank() &&
            (f.password.isNotEmpty() || (editing.hasMusic && editing.serverURL.equals(SubsonicClient.normalize(f.server), ignoreCase = true) && editing.username == f.username.trim()))
    } else {
        (!wantsMusic || (f.server.isNotBlank() && f.username.isNotBlank() && f.password.isNotEmpty())) &&
            (!wantsBooks || (f.bookServer.isNotBlank() && f.bookUsername.isNotBlank() && f.bookPassword.isNotEmpty()))
    }
    val sentToBooks = if (f.service == Service.BOTH && f.same) named else namedBook
    val headersUnencrypted = (wantsMusic && plainOverInternet(f.server) && named.isNotEmpty()) ||
        (wantsBooks && plainOverInternet(f.bookServer) && sentToBooks.isNotEmpty())

    fun submit() {
        if (!canSave) return
        if ((wantsMusic && invalidHeaders(form.headers)) || (wantsBooks && !(f.service == Service.BOTH && f.same) && invalidHeaders(form.bookHeaders))) {
            error = context.getString(R.string.header_invalid)
            return
        }
        // A public name here would get the login over plain http from anywhere
        if ((wantsMusic && f.home.isNotBlank() && !SubsonicClient.isLocal(f.home)) || (wantsBooks && f.bookHome.isNotBlank() && !SubsonicClient.isLocal(f.bookHome))) {
            error = context.getString(R.string.home_only)
            return
        }
        scope.launch {
            busy = true
            error = null
            val app = context.tonalo
            var books: AudiobookServer? = null
            // A failed one says which it was; an Audiobookshelf login that is not needed any more is ended on the server
            fun abort(message: String) { error = message; books?.let { app.books.logout(it) } }
            fun finish() {
                form.headers.clear(); form.bookHeaders.clear(); form.loaded = false
                f.password = ""; f.bookPassword = ""
                app.checkRoute(); onClose?.invoke()
            }
            try {
                val current = app.current.value
                val bookUser = f.bookUsername.trim()
                val bookHome = f.bookHome.ifBlank { null }
                // Audiobooks only: into the account you are in when that has music and no books, otherwise an account of its own
                if (editing == null && f.service == Service.BOOKS) {
                    try {
                        if (current != null && current.hasMusic && current.audiobooks == null) {
                            app.books.connect(f.bookServer, bookUser, f.bookPassword, namedBook, bookHome)
                        } else {
                            app.books.connectAsAccount(f.bookServer, bookUser, f.bookPassword, namedBook, bookHome)
                        }
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        error = context.getString(R.string.bka_abs_error, e.bookErrorText(context))
                        return@launch
                    }
                    finish()
                    return@launch
                }
                // Both have to work before anything is saved
                if (wantsBooks) {
                    books = try {
                        app.books.signIn(f.bookServer, bookUser, f.bookPassword, sentToBooks).copy(localURL = SubsonicClient.normalizeLocal(f.bookHome))
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        error = context.getString(R.string.bka_abs_error, e.bookErrorText(context))
                        return@launch
                    }
                }
                // Music for an audiobooks-only account joins that account
                val base = when {
                    editing != null -> editing
                    f.service == Service.MUSIC && current != null && !current.hasMusic -> current
                    else -> null
                }
                val kept = if (f.password.isEmpty()) {
                    base?.takeIf { it.hasMusic && it.serverURL.equals(SubsonicClient.normalize(f.server), ignoreCase = true) && it.username == f.username.trim() }?.let { it.salt to it.token }
                } else null
                val token = kept ?: SubsonicClient.makeToken(f.password)
                var account = (base ?: Account(serverURL = "", username = "", salt = "", token = "")).copy(
                    serverURL = SubsonicClient.normalize(f.server),
                    username = f.username.trim(),
                    salt = token.first,
                    token = token.second,
                    headers = named.map { it.copy(name = it.name.trim()) },
                    localURL = SubsonicClient.normalizeLocal(f.home),
                    audiobooks = books ?: base?.audiobooks,
                )
                account = try {
                    SubsonicClient(account).ping()
                    account
                } catch (first: IOException) {
                    // No scheme typed and https didn't connect at all (typical for an IP in the home network): try plain http.
                    // Only for home-network addresses – for a public one, someone blocking https could otherwise
                    // make the app send the login and custom headers unencrypted.
                    if ("://" in f.server) throw first
                    if (!SubsonicClient.isLocal(f.server)) {
                        abort(context.getString(R.string.error_https_only))
                        return@launch
                    }
                    account.copy(serverURL = "http://" + account.serverURL.removePrefix("https://")).also { SubsonicClient(it).ping() }
                }
                if (books != null) AudiobookFiles.reopen(account.id)
                if (!app.save(account)) abort(context.getString(R.string.error_network)) else finish()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                abort(errorText(context, e))
            } finally {
                busy = false
            }
        }
    }

    BackHandler(enabled = page != LoginPage.MAIN) { page = LoginPage.MAIN }
    when (page) {
        LoginPage.HOME -> HomeAddressPage(f.home, { f.home = it }) { page = LoginPage.MAIN }
        LoginPage.HEADERS -> HeadersPage(form.headers) { page = LoginPage.MAIN }
        LoginPage.BOOK_HOME -> HomeAddressPage(f.bookHome, { f.bookHome = it }, stringResource(R.string.bka_abs_home_hint)) { page = LoginPage.MAIN }
        LoginPage.BOOK_HEADERS -> HeadersPage(form.bookHeaders) { page = LoginPage.MAIN }
        LoginPage.MAIN -> if (editing == null) {
            SignIn(
                f, named.size, namedBook.size, headersUnencrypted, error, busy, canSave,
                onService = { f.service = it; error = null },
                onPage = { page = it }, onSubmit = ::submit, onClose = onClose,
            )
        } else {
            EditAccount(
                editing, f, named.size, headersUnencrypted, error, busy, canSave,
                onPage = { page = it }, onSubmit = ::submit, onClose = onClose ?: {},
            )
        }
    }
}

/** The line between two rows of "More options". */
@Composable
private fun OptionDivider() {
    Box(Modifier.padding(start = 52.dp).fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.1f)))
}

/** A new sign-in: logo on an accent glow, the service chips, the fields, one capsule button, the rest under "More options". */
@Composable
private fun SignIn(
    f: LoginFields, headerCount: Int, bookHeaderCount: Int, headersUnencrypted: Boolean,
    error: String?, busy: Boolean, canSave: Boolean,
    onService: (Service) -> Unit, onPage: (LoginPage) -> Unit, onSubmit: () -> Unit, onClose: (() -> Unit)?,
) {
    val focus = LocalFocusManager.current
    val wantsMusic = f.service != Service.BOOKS
    val wantsBooks = f.service != Service.MUSIC
    val both = f.service == Service.BOTH
    var options by rememberSaveable { mutableStateOf(f.home.isNotEmpty() || f.bookHome.isNotEmpty() || headerCount > 0 || bookHeaderCount > 0) }
    Box(
        Modifier.fillMaxSize().background(Palette.canvas)
            .drawBehind {
                drawRect(Brush.radialGradient(listOf(Palette.accent.copy(alpha = 0.38f), Color.Transparent), center = Offset(size.width / 2, 0f), radius = 460.dp.toPx()))
            },
    ) {
        Column(
            Modifier.fillMaxSize().statusBarsPadding().imePadding().verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Column(Modifier.widthIn(max = 460.dp).fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                Spacer(Modifier.height(if (onClose != null) 64.dp else 52.dp))
                TonaloLogo(88)
                Spacer(Modifier.height(14.dp))
                Text("Tonalo", fontSize = 34.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(6.dp))
                Text(stringResource(R.string.login_tagline), color = Palette.subtle, style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.Center)
                Spacer(Modifier.height(28.dp))

                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Chip(stringResource(R.string.music), f.service == Service.MUSIC) { onService(Service.MUSIC) }
                    Chip(stringResource(R.string.bk_audiobooks), f.service == Service.BOOKS) { onService(Service.BOOKS) }
                    Chip(stringResource(R.string.bka_both), both) { onService(Service.BOTH) }
                }
                Spacer(Modifier.height(20.dp))

                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (wantsMusic) {
                        if (both) FieldsTitle(stringResource(R.string.bka_music_navidrome))
                        LoginField(Icons.Default.Dns, stringResource(R.string.server_address), f.server, { f.server = it }, KeyboardType.Uri) {
                            focus.moveFocus(FocusDirection.Down)
                        }
                        LoginField(Icons.Default.Person, stringResource(R.string.username), f.username, { f.username = it }, KeyboardType.Text) {
                            focus.moveFocus(FocusDirection.Down)
                        }
                        LoginField(Icons.Default.Lock, stringResource(R.string.password), f.password, { f.password = it }, KeyboardType.Password, last = !wantsBooks) {
                            if (wantsBooks) focus.moveFocus(FocusDirection.Down) else { focus.clearFocus(); onSubmit() }
                        }
                    }
                    if (wantsBooks) {
                        if (both) { Spacer(Modifier.height(4.dp)); FieldsTitle(stringResource(R.string.bka_books_abs)) }
                        LoginField(Icons.Default.Book, stringResource(R.string.bka_abs_address), f.bookServer, { f.bookServer = it }, KeyboardType.Uri) {
                            focus.moveFocus(FocusDirection.Down)
                        }
                        LoginField(Icons.Default.Person, stringResource(R.string.username), f.bookUsername, { f.bookUsername = it }, KeyboardType.Text) {
                            focus.moveFocus(FocusDirection.Down)
                        }
                        LoginField(Icons.Default.Lock, stringResource(R.string.password), f.bookPassword, { f.bookPassword = it }, KeyboardType.Password, last = true) {
                            focus.clearFocus(); onSubmit()
                        }
                    }
                }

                if (wantsBooks && plainOverInternet(f.bookServer)) {
                    Notice(Icons.Default.Warning, stringResource(R.string.bka_http_password_warning), Color(0xFFFF9F0A), Modifier.padding(top = 16.dp))
                }
                error?.let { Notice(Icons.Default.Error, it, Color(0xFFFF5A5F), Modifier.padding(top = 16.dp)) }

                Spacer(Modifier.height(28.dp))
                val active = canSave || busy
                val bg by animateColorAsState(if (active) Palette.accent else Palette.elevated, tween(200), label = "button")
                Box(
                    Modifier.fillMaxWidth().height(54.dp).clip(CircleShape).background(bg)
                        .clickable(enabled = canSave) { focus.clearFocus(); onSubmit() },
                    contentAlignment = Alignment.Center,
                ) {
                    if (busy) CircularProgressIndicator(Modifier.size(22.dp), color = Color.Black, strokeWidth = 2.dp)
                    else Text(stringResource(R.string.sign_in), fontWeight = FontWeight.SemiBold, fontSize = 17.sp, color = if (active) Color.Black else Palette.subtle)
                }

                Spacer(Modifier.height(28.dp))
                val turn by animateFloatAsState(if (options) 180f else 0f, tween(200), label = "chevron")
                Row(
                    Modifier.clip(CircleShape).clickable { options = !options }.padding(horizontal = 12.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(stringResource(R.string.more_options), color = Palette.subtle, style = MaterialTheme.typography.bodyMedium)
                    Icon(Icons.Default.KeyboardArrowDown, null, tint = Palette.subtle, modifier = Modifier.padding(start = 4.dp).size(18.dp).rotate(turn))
                }
                AnimatedVisibility(options, enter = fadeIn() + expandVertically(), exit = fadeOut() + shrinkVertically()) {
                    Column(Modifier.padding(top = 14.dp).fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Palette.elevated)) {
                        if (wantsMusic) {
                            OptionRow(Icons.Default.Home, stringResource(R.string.address_at_home), f.home.ifEmpty { stringResource(R.string.off) }) { onPage(LoginPage.HOME) }
                            OptionDivider()
                            OptionRow(
                                Icons.Default.Key, stringResource(if (both && !f.same) R.string.bka_headers_music else R.string.custom_headers),
                                if (headerCount == 0) stringResource(R.string.none) else "$headerCount",
                            ) { onPage(LoginPage.HEADERS) }
                        }
                        if (wantsBooks) {
                            if (wantsMusic) OptionDivider()
                            OptionRow(
                                Icons.Default.Home, stringResource(if (both) R.string.bka_books_home else R.string.address_at_home),
                                f.bookHome.ifEmpty { stringResource(R.string.off) },
                            ) { onPage(LoginPage.BOOK_HOME) }
                        }
                        if (both) {
                            OptionDivider()
                            Row(
                                Modifier.fillMaxWidth().height(52.dp).clickable { f.same = !f.same }.padding(horizontal = 16.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Icon(Icons.Default.Link, null, tint = Palette.accent, modifier = Modifier.size(22.dp))
                                Spacer(Modifier.width(14.dp))
                                Text(stringResource(R.string.bka_same_headers), color = Color.White, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                                Switch(
                                    f.same, { f.same = it },
                                    colors = SwitchDefaults.colors(checkedThumbColor = Color.Black, checkedTrackColor = Palette.accent),
                                )
                            }
                        }
                        if (f.service == Service.BOOKS || (both && !f.same)) {
                            OptionDivider()
                            OptionRow(
                                Icons.Default.Key, stringResource(if (both) R.string.bka_headers_books else R.string.custom_headers),
                                if (bookHeaderCount == 0) stringResource(R.string.none) else "$bookHeaderCount",
                            ) { onPage(LoginPage.BOOK_HEADERS) }
                        }
                    }
                }
                if (headersUnencrypted) Notice(Icons.Default.Warning, stringResource(R.string.headers_unencrypted), Color(0xFFFF9F0A), Modifier.padding(top = 10.dp))

                Spacer(Modifier.height(24.dp))
                if (wantsBooks) {
                    Text(
                        stringResource(R.string.bka_vpn_footer), color = Palette.subtle.copy(alpha = 0.8f),
                        style = MaterialTheme.typography.bodySmall, textAlign = TextAlign.Center,
                    )
                    Spacer(Modifier.height(12.dp))
                }
                Text(
                    stringResource(if (wantsMusic) R.string.login_footer else R.string.bka_books_login_footer), color = Palette.subtle.copy(alpha = 0.8f),
                    style = MaterialTheme.typography.bodySmall, textAlign = TextAlign.Center,
                )
                Spacer(Modifier.height(24.dp))
                Spacer(Modifier.navigationBarsPadding())
            }
        }
        if (onClose != null) {
            TextButton(onClick = onClose, Modifier.statusBarsPadding().padding(8.dp).align(Alignment.TopStart)) {
                Text(stringResource(R.string.cancel), color = Color.White)
            }
        }
    }
}

/** The small gray title above a group of fields when both servers are asked for. */
@Composable
private fun FieldsTitle(text: String) {
    Text(text, Modifier.padding(start = 4.dp), color = Palette.subtle, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
}

/** Changing an account that's already signed in: a grouped page with Save at the top. */
@Composable
private fun EditAccount(
    account: Account, f: LoginFields, headerCount: Int, headersUnencrypted: Boolean,
    error: String?, busy: Boolean, canSave: Boolean,
    onPage: (LoginPage) -> Unit, onSubmit: () -> Unit, onClose: () -> Unit,
) {
    val app = LocalContext.current.tonalo
    val current by app.current.collectAsState()
    var disconnect by remember { mutableStateOf(false) }
    SubPage(stringResource(R.string.music_server), onClose, actions = {
        if (busy) CircularProgressIndicator(Modifier.padding(end = 12.dp).size(22.dp), strokeWidth = 2.dp)
        else TextButton(onClick = onSubmit, enabled = canSave) {
            Text(stringResource(R.string.save), fontWeight = FontWeight.Bold, color = if (canSave) Palette.accent else Palette.subtle)
        }
    }) {
        item {
            Group(stringResource(R.string.server)) {
                FieldRow(f.server, { f.server = it }, stringResource(R.string.server_hint) + " / 192.168.1.10:4533",
                    keyboard = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false))
            }
        }
        item {
            Group(stringResource(R.string.login_section)) {
                FieldRow(f.username, { f.username = it }, stringResource(R.string.username),
                    keyboard = KeyboardOptions(autoCorrectEnabled = false))
                FieldRow(f.password, { f.password = it }, stringResource(if (account.hasMusic) R.string.password_keep else R.string.password), password = true,
                    keyboard = KeyboardOptions(keyboardType = KeyboardType.Password))
            }
        }
        item {
            Group(stringResource(R.string.advanced), footer = if (headersUnencrypted) stringResource(R.string.headers_unencrypted) else null) {
                NavRow(stringResource(R.string.address_at_home), f.home.ifEmpty { stringResource(R.string.off) }) { onPage(LoginPage.HOME) }
                NavRow(stringResource(R.string.custom_headers), if (headerCount == 0) stringResource(R.string.none) else "$headerCount") { onPage(LoginPage.HEADERS) }
            }
        }
        error?.let { item { Notice(Icons.Default.Error, it, Color(0xFFFF5A5F), Modifier.padding(horizontal = 16.dp)) } }
        // The audiobooks keep the account going; without them there is nothing to take out here
        if (account.hasMusic && account.audiobooks != null && current?.id == account.id) item {
            Group { ActionRow(stringResource(R.string.bka_disconnect), destructive = true, centered = true) { disconnect = true } }
        }
    }
    if (disconnect) androidx.compose.material3.AlertDialog(
        onDismissRequest = { disconnect = false },
        containerColor = Palette.elevated,
        title = { Text(stringResource(R.string.bka_disconnect_music_q)) },
        text = { Text(stringResource(R.string.bka_disconnect_music_text), style = MaterialTheme.typography.bodyMedium) },
        confirmButton = {
            TextButton(onClick = { disconnect = false; onClose(); app.disconnectMusic() }) {
                Text(stringResource(R.string.bka_disconnect), color = Color(0xFFFF5A5F))
            }
        },
        dismissButton = { TextButton(onClick = { disconnect = false }) { Text(stringResource(R.string.cancel)) } },
    )
}

/** Second address for the home network, used on Wi-Fi when it answers. */
@Composable
internal fun HomeAddressPage(address: String, onChange: (String) -> Unit, placeholder: String = "192.168.1.10:4533", back: () -> Unit) {
    SubPage(stringResource(R.string.address_at_home), back) {
        item {
            Group(footer = stringResource(R.string.home_address_footer)) {
                FieldRow(address, onChange, placeholder,
                    keyboard = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false, imeAction = ImeAction.Done))
            }
        }
        if (address.isNotBlank() && !SubsonicClient.isLocal(address)) {
            item { Notice(Icons.Default.Warning, stringResource(R.string.home_only), Color(0xFFFF9F0A), Modifier.padding(horizontal = 16.dp)) }
        }
    }
}

/** Extra HTTP headers for Cloudflare Access, Authelia and similar proxies. Swipe a header left to remove it. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun HeadersPage(headers: SnapshotStateList<HeaderField>, back: () -> Unit) {
    SubPage(stringResource(R.string.custom_headers), back) {
        if (headers.isNotEmpty()) item {
            Group(footer = stringResource(R.string.swipe_remove_header)) {
                headers.toList().forEach { h ->
                    androidx.compose.runtime.key(h.id) {
                        val state = rememberSwipeToDismissBoxState(confirmValueChange = {
                            if (it == SwipeToDismissBoxValue.EndToStart) headers.removeAll { x -> x.id == h.id }
                            it == SwipeToDismissBoxValue.EndToStart
                        })
                        SwipeToDismissBox(
                            state, enableDismissFromStartToEnd = false,
                            backgroundContent = {
                                Box(Modifier.fillMaxSize().background(Color(0xFFFF453A)).padding(end = 20.dp), contentAlignment = Alignment.CenterEnd) {
                                    Icon(Icons.Default.Delete, stringResource(R.string.delete), tint = Color.White)
                                }
                            },
                        ) {
                            HeaderRow(h) { new -> headers.indexOfFirst { it.id == h.id }.takeIf { it >= 0 }?.let { headers[it] = new } }
                        }
                    }
                }
            }
        }
        if (headers.any { if (it.name.isNotBlank()) !headerValid(it.name, it.value) else it.value.isNotEmpty() }) item {
            Notice(Icons.Default.Warning, stringResource(R.string.header_invalid), Color(0xFFFF9F0A), Modifier.padding(start = 16.dp, end = 16.dp, bottom = 16.dp))
        }
        item {
            Group(footer = stringResource(R.string.headers_footer)) {
                ActionRow(stringResource(R.string.add_header), Icons.Default.Add) { headers.add(HeaderField(name = "", value = "")) }
                ActionRow(stringResource(R.string.add_cloudflare), Icons.Outlined.Cloud) {
                    for (name in listOf("CF-Access-Client-Id", "CF-Access-Client-Secret")) {
                        if (headers.none { it.name.trim().equals(name, ignoreCase = true) }) headers.add(HeaderField(name = name, value = ""))
                    }
                }
            }
        }
    }
}

/** One header: the name in monospace, the value hidden behind dots until the eye is tapped. */
@Composable
private fun HeaderRow(h: HeaderField, onChange: (HeaderField) -> Unit) {
    var shown by remember { mutableStateOf(false) }
    val mono = MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.Monospace)
    Column(Modifier.fillMaxWidth().background(Palette.card).padding(horizontal = 16.dp, vertical = 12.dp)) {
        PlainField(h.name, { onChange(h.copy(name = it)) }, stringResource(R.string.header_name_hint), mono.copy(color = Color.White))
        Row(Modifier.padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f)) {
                PlainField(h.value, { onChange(h.copy(value = it)) }, stringResource(R.string.header_value), mono.copy(color = Palette.secondaryText),
                    hidden = !shown)
            }
            IconButton(onClick = { shown = !shown }, Modifier.size(36.dp)) {
                Icon(
                    if (shown) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                    stringResource(if (shown) R.string.hide_value else R.string.show_value), tint = Palette.secondaryText,
                )
            }
        }
    }
}

@Composable
private fun PlainField(value: String, onChange: (String) -> Unit, placeholder: String, style: androidx.compose.ui.text.TextStyle, hidden: Boolean = false) {
    Box {
        if (value.isEmpty()) Text(placeholder, style = style.copy(color = Palette.subtle))
        BasicTextField(
            value, onChange, Modifier.fillMaxWidth(), singleLine = true, textStyle = style,
            cursorBrush = SolidColor(Palette.accent),
            visualTransformation = if (hidden) PasswordVisualTransformation() else VisualTransformation.None,
            keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = if (hidden) KeyboardType.Password else KeyboardType.Ascii),
        )
    }
}

/** A page of the sign-in with the round back button – works before there's any navigation (first sign-in). */
@Composable
internal fun SubPage(title: String, back: () -> Unit, actions: @Composable () -> Unit = {}, content: androidx.compose.foundation.lazy.LazyListScope.() -> Unit) {
    Column(Modifier.fillMaxSize().background(Palette.canvas).imePadding()) {
        Box(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 12.dp, vertical = 8.dp).height(48.dp)) {
            GlassBackButton(Modifier.align(Alignment.CenterStart), onClick = back)
            Text(
                title, Modifier.align(Alignment.Center).padding(horizontal = 64.dp), maxLines = 1, overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold,
            )
            Row(Modifier.align(Alignment.CenterEnd), verticalAlignment = Alignment.CenterVertically) { actions() }
        }
        androidx.compose.foundation.lazy.LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 32.dp),
            content = content,
        )
    }
}

/** Text field of the sign-in screen: icon, rounded dark surface, an accent ring while typing. */
@Composable
private fun LoginField(
    icon: ImageVector, prompt: String, value: String, onChange: (String) -> Unit, type: KeyboardType,
    last: Boolean = false, next: () -> Unit,
) {
    val interaction = remember { MutableInteractionSource() }
    val focused by interaction.collectIsFocusedAsState()
    val ring by animateColorAsState(if (focused) Palette.accent.copy(alpha = 0.8f) else Color.Transparent, tween(150), label = "ring")
    val shape = RoundedCornerShape(14.dp)
    BasicTextField(
        value, onChange,
        Modifier.fillMaxWidth().height(54.dp),
        singleLine = true,
        textStyle = MaterialTheme.typography.bodyLarge.copy(color = Color.White),
        cursorBrush = SolidColor(Palette.accent),
        interactionSource = interaction,
        visualTransformation = if (type == KeyboardType.Password) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(keyboardType = type, autoCorrectEnabled = false, imeAction = if (last) ImeAction.Go else ImeAction.Next),
        keyboardActions = KeyboardActions(onNext = { next() }, onGo = { next() }),
        decorationBox = { inner ->
            Row(
                Modifier.fillMaxSize().clip(shape).background(Palette.elevated).border(1.5.dp, ring, shape).padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(icon, null, tint = Palette.subtle, modifier = Modifier.size(22.dp))
                Spacer(Modifier.width(14.dp))
                Box(Modifier.weight(1f)) {
                    if (value.isEmpty()) Text(prompt, color = Palette.subtle, style = MaterialTheme.typography.bodyLarge)
                    inner()
                }
            }
        },
    )
}

/** A row under "More options": accent icon, title, the current value, a chevron. */
@Composable
private fun OptionRow(icon: ImageVector, title: String, value: String, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().height(52.dp).clickable(onClick = onClick).padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = Palette.accent, modifier = Modifier.size(22.dp))
        Spacer(Modifier.width(14.dp))
        Text(title, color = Color.White, style = MaterialTheme.typography.bodyLarge)
        Spacer(Modifier.weight(1f))
        Text(value, color = Palette.subtle, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(start = 12.dp).widthIn(max = 160.dp))
        Icon(Icons.AutoMirrored.Filled.ArrowForwardIos, null, tint = Palette.subtle.copy(alpha = 0.6f), modifier = Modifier.padding(start = 8.dp).size(12.dp))
    }
}

/** A short warning or error line with an icon. */
@Composable
internal fun Notice(icon: ImageVector, text: String, color: Color, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
        Icon(icon, null, tint = color, modifier = Modifier.padding(top = 1.dp).size(16.dp))
        Spacer(Modifier.width(6.dp))
        Text(text, color = color, style = MaterialTheme.typography.bodySmall)
    }
}

/** The app icon drawn in Compose, so it follows the accent color. The bars breathe gently. */
@Composable
fun TonaloLogo(sizeDp: Int) {
    val heights = listOf(0.21f, 0.375f, 0.54f, 0.335f, 0.19f)
    val swing = listOf(1.25f, 0.85f, 1.1f, 0.8f, 1.3f)
    val t by rememberInfiniteTransition(label = "logo").animateFloat(
        0f, 1f, infiniteRepeatable(tween(1200, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "bars",
    )
    val accent = Palette.accent
    Canvas(
        Modifier.size(sizeDp.dp)
            .shadow(28.dp, RoundedCornerShape((sizeDp * 0.225f).dp), ambientColor = accent, spotColor = accent),
    ) {
        val s = size.width
        drawRoundRect(accent, cornerRadius = CornerRadius(s * 0.225f))
        val w = s * 0.07f
        val gap = s * 0.045f
        val total = w * 5 + gap * 4
        heights.forEachIndexed { i, h ->
            val bar = s * h * (1f + (swing[i] - 1f) * t)
            val x = (s - total) / 2 + i * (w + gap)
            drawRoundRect(Color(0xFF121212), Offset(x, (s - bar) / 2), Size(w, bar), CornerRadius(w / 2))
        }
    }
}
