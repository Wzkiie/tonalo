package app.tonalo.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Logout
import androidx.compose.material.icons.filled.Book
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.outlined.ArrowCircleDown
import androidx.compose.material.icons.outlined.Groups
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Tv
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalDrawerSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.tonalo.android.R
import app.tonalo.android.data.Account
import app.tonalo.android.tonalo

/** The side menu behind the avatar, like the iPhone's: who is signed in, other accounts, the main places, log out. */
@Composable
fun ProfileMenu(close: () -> Unit, open: (String) -> Unit) {
    val app = LocalContext.current.tonalo
    val accounts by app.accountList.collectAsState()
    val current by app.current.collectAsState()
    var logout by remember { mutableStateOf(false) }

    ModalDrawerSheet(
        Modifier.width(310.dp),
        drawerShape = RectangleShape,
        drawerContainerColor = Palette.card,
        drawerContentColor = Color.White,
    ) {
        Column(Modifier.fillMaxHeight().statusBarsPadding().navigationBarsPadding().padding(horizontal = 20.dp).padding(top = 24.dp)) {
            current?.let { acc ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    NameAvatar(acc.username, 52.dp)
                    Spacer(Modifier.width(12.dp))
                    Text(acc.username, fontSize = 20.sp, fontWeight = FontWeight.Bold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                // Both servers, each with the user it's signed in as
                Column(Modifier.padding(top = 12.dp, bottom = 18.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (acc.hasMusic) ServerLine(Icons.Default.MusicNote, acc.username, acc.host)
                    acc.audiobooks?.let { ServerLine(Icons.Default.Book, it.username, it.host) }
                }
            }
            Box(Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.12f)))
            Spacer(Modifier.height(12.dp))
            accounts.filter { it.id != current?.id }.forEach { acc ->
                MenuRow(acc.username, acc.host, icon = { NameAvatar(acc.username, 28.dp) }) { close(); app.select(acc.id) }
            }
            MenuRow(stringResource(R.string.downloads), icon = Icons.Outlined.ArrowCircleDown) { open("downloads") }
            if (current?.hasMusic != false) {
                MenuRow(stringResource(R.string.devices_title), icon = Icons.Outlined.Tv) { open("devices") }
                MenuRow(stringResource(R.string.jukebox), icon = Icons.Outlined.Groups) { open("jukebox") }
                MenuRow(stringResource(R.string.dj), icon = { DJMark(Modifier.size(24.dp), Color.White) }) { open("dj") }
            }
            MenuRow(stringResource(R.string.tab_settings), icon = Icons.Outlined.Settings) { open("settings") }
            Spacer(Modifier.weight(1f))
            if (current != null) MenuRow(stringResource(R.string.sign_out), icon = Icons.AutoMirrored.Outlined.Logout, color = Palette.subtle) { logout = true }
            Spacer(Modifier.height(8.dp))
        }
    }

    if (logout) current?.let { acc -> LogoutDialog(acc, onDone = close) { logout = false } }
}

@Composable
private fun ServerLine(icon: ImageVector, user: String, host: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = Palette.subtle, modifier = Modifier.size(15.dp))
        Spacer(Modifier.width(8.dp))
        Text("$user · $host", color = Palette.subtle, fontSize = 13.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun MenuRow(title: String, sub: String? = null, icon: ImageVector, color: Color = Color.White, onClick: () -> Unit) =
    MenuRow(title, sub, icon = { Icon(icon, null, tint = color, modifier = Modifier.size(26.dp)) }, color = color, onClick = onClick)

@Composable
private fun MenuRow(title: String, sub: String? = null, icon: @Composable () -> Unit, color: Color = Color.White, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 13.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.width(30.dp), contentAlignment = Alignment.Center) { icon() }
        Spacer(Modifier.width(16.dp))
        Column {
            Text(title, color = color, fontSize = 17.sp)
            if (sub != null) Text(sub, color = Palette.subtle, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** Asks before signing an account out – that also deletes its downloads and cache on this phone. */
@Composable
fun LogoutDialog(account: Account, onDone: () -> Unit = {}, dismiss: () -> Unit) {
    val app = LocalContext.current.tonalo
    AlertDialog(
        onDismissRequest = dismiss,
        containerColor = Palette.elevated,
        title = { Text(stringResource(R.string.log_out_title, account.host)) },
        text = { Text(stringResource(R.string.log_out_text), style = MaterialTheme.typography.bodyMedium) },
        confirmButton = {
            TextButton(onClick = { dismiss(); onDone(); app.remove(account) }) {
                Text(stringResource(R.string.sign_out), color = Color(0xFFFF5A5F))
            }
        },
        dismissButton = { TextButton(onClick = dismiss) { Text(stringResource(R.string.cancel)) } },
    )
}
