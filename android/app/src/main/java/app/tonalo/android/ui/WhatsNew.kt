package app.tonalo.android.ui

import android.content.Context
import androidx.activity.compose.BackHandler
import androidx.annotation.StringRes
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Headphones
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import app.tonalo.android.R
import androidx.compose.ui.window.DialogProperties
import androidx.compose.animation.core.tween
import kotlinx.coroutines.launch

// region CONTENT – edit here ---------------------------------------------------------------------
// One list for the update sheet and the version history: versions, newest first, each with its items.
// An item is: icon, color, title (string resource), text (string resource). Strings live in
// res/values/strings_news.xml (+ values-de). The sheet shows the newest release that is not newer than
// the installed app version; the history shows all of them.

class NewsItem(val icon: ImageVector, val color: Color, @StringRes val title: Int, @StringRes val text: Int)
class NewsRelease(val version: String, val items: List<NewsItem>)

private val Blue = Color(0xFF5B9DFF)
private val Purple = Color(0xFFAF7BFF)
private val Green = Color(0xFF34C759)
private val Orange = Color(0xFFFF9F0A)
private val Pink = Color(0xFFFF4F8B)
private val Teal = Color(0xFF30C4C4)
private val Red = Color(0xFFFF5A52)

val NewsReleases: List<NewsRelease> = listOf(
    NewsRelease("0.9.0", listOf(
        NewsItem(Icons.Filled.Headphones, Orange, R.string.wn_090_books_t, R.string.wn_090_books),
    )),
    NewsRelease("0.8.0", listOf(
        NewsItem(Icons.Filled.GraphicEq, Blue, R.string.wn_080_playing_t, R.string.wn_080_playing),
        NewsItem(Icons.Filled.AutoAwesome, Purple, R.string.wn_080_dj_t, R.string.wn_080_dj),
        NewsItem(Icons.Filled.Refresh, Green, R.string.wn_080_refresh_t, R.string.wn_080_refresh),
        NewsItem(Icons.Filled.Groups, Orange, R.string.wn_080_accounts_t, R.string.wn_080_accounts),
        NewsItem(Icons.Filled.Lock, Teal, R.string.wn_080_safer_t, R.string.wn_080_safer),
    )),
    NewsRelease("0.7.0", listOf(NewsItem(Icons.Filled.DirectionsCar, Blue, R.string.wn_070_t, R.string.news_07))),
    NewsRelease("0.5.0", listOf(NewsItem(Icons.Filled.GridView, Pink, R.string.wn_050_t, R.string.news_05))),
    NewsRelease("0.4.0", listOf(NewsItem(Icons.Filled.AutoAwesome, Purple, R.string.wn_040_t, R.string.news_04))),
    NewsRelease("0.3.0", listOf(NewsItem(Icons.Filled.Tv, Orange, R.string.wn_030_t, R.string.news_03))),
    NewsRelease("0.2.0", listOf(NewsItem(Icons.Filled.Download, Green, R.string.wn_020_t, R.string.news_02))),
    NewsRelease("0.1.0", listOf(NewsItem(Icons.Filled.PlayArrow, Red, R.string.wn_010_t, R.string.news_01))),
)
// endregion --------------------------------------------------------------------------------------

/** "Show once after an update" bookkeeping, in its own plain SharedPreferences file (no secrets). */
object WhatsNew {
    private const val FILE = "whats_new"
    private const val KEY = "seen_version"

    private fun prefs(c: Context) = c.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun installedVersion(c: Context): String =
        try { c.packageManager.getPackageInfo(c.packageName, 0).versionName ?: "0" } catch (_: Exception) { "0" }

    /** Call once at launch: a fresh install remembers the current version, so no sheet shows for it. */
    fun init(c: Context) {
        val p = prefs(c)
        if (p.contains(KEY)) return
        val fresh = try {
            val i = c.packageManager.getPackageInfo(c.packageName, 0)
            i.firstInstallTime == i.lastUpdateTime
        } catch (_: Exception) { true }
        if (fresh) p.edit().putString(KEY, installedVersion(c)).apply()
    }

    fun markSeen(c: Context) { prefs(c).edit().putString(KEY, installedVersion(c)).apply() }

    private fun parts(v: String) = v.split('.', '-').map { it.takeWhile(Char::isDigit).toIntOrNull() ?: 0 }

    fun compare(a: String, b: String): Int {
        val x = parts(a); val y = parts(b)
        for (i in 0 until maxOf(x.size, y.size)) {
            val d = x.getOrElse(i) { 0 }.compareTo(y.getOrElse(i) { 0 })
            if (d != 0) return d
        }
        return 0
    }

    /** The newest release that is not newer than the installed app. */
    fun currentRelease(c: Context): NewsRelease? =
        NewsReleases.filter { compare(it.version, installedVersion(c)) <= 0 }.maxWithOrNull { a, b -> compare(a.version, b.version) }

    /** The release to show now: it must be newer than what the user last saw. Null if nothing is due. */
    fun due(c: Context): NewsRelease? {
        val seen = prefs(c).getString(KEY, null) ?: "0"
        val r = currentRelease(c) ?: return null
        return if (compare(r.version, seen) > 0) r else null
    }
    // To test again: clear the app's storage, or `adb shell run-as app.tonalo.android rm shared_prefs/whats_new.xml`
    // and restart (with the key missing on an updated install it counts as "never seen").
}

/** Mounted above MainScreen: shows the update sheet once, as a full-screen dialog. */
@Composable
fun WhatsNewHost() {
    val context = LocalContext.current
    var release by remember { mutableStateOf(WhatsNew.due(context)) }
    val r = release ?: return
    WhatsNewSheet(r, onClose = { WhatsNew.markSeen(context); release = null })
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun WhatsNewSheet(release: NewsRelease, onClose: () -> Unit) {
    var showAll by remember { mutableStateOf(false) }
    Dialog(
        onDismissRequest = { if (showAll) showAll = false else onClose() },
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        Box(Modifier.fillMaxSize().background(Palette.canvas)) {
            if (showAll) {
                Column(Modifier.fillMaxSize()) {
                    TopBar(stringResource(R.string.whats_new), back = false) {
                        Text(stringResource(R.string.done), Modifier.clip(CircleShape).clickable { showAll = false }.padding(horizontal = 16.dp, vertical = 10.dp),
                            color = Palette.accent, fontWeight = FontWeight.SemiBold)
                    }
                    androidx.compose.foundation.lazy.LazyColumn(
                        Modifier.fillMaxSize(),
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 32.dp),
                    ) { versionHistory() }
                }
            } else {
                SheetPages(release, onClose) { showAll = true }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SheetPages(release: NewsRelease, onClose: () -> Unit, onChangelog: () -> Unit) {
    val count = release.items.size + 1 // page 0 is the welcome
    val pager = rememberPagerState { count }
    val scope = rememberCoroutineScope()
    val page = pager.currentPage
    val last = page == count - 1
    val target = if (page == 0) Palette.accent else release.items[page - 1].color
    val color by animateColorAsState(target, tween(400), label = "glow")
    fun next() { if (last) onClose() else scope.launch { pager.animateScrollToPage(page + 1) } }

    Box(
        Modifier.fillMaxSize().drawBehind {
            drawRect(Brush.radialGradient(
                listOf(color.copy(alpha = 0.35f), Color.Transparent),
                center = Offset(size.width / 2, size.height * 0.34f), radius = size.height * 0.5f,
            ))
        },
    ) {
        Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()) {
            Box(Modifier.fillMaxWidth().height(48.dp).padding(horizontal = 12.dp), contentAlignment = Alignment.CenterEnd) {
                if (!last) {
                    Text(stringResource(R.string.wn_skip), Modifier.clip(CircleShape).clickable { onClose() }.padding(horizontal = 14.dp, vertical = 8.dp),
                        color = Palette.subtle, fontSize = 16.sp, fontWeight = FontWeight.Medium)
                }
            }
            HorizontalPager(pager, Modifier.weight(1f).fillMaxWidth()) { i ->
                Box(Modifier.fillMaxSize().clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { next() }) {
                    if (i == 0) WelcomePage() else ItemPage(release.items[i - 1])
                }
            }
            Row(Modifier.fillMaxWidth().padding(bottom = 20.dp), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                repeat(count) { i ->
                    Box(Modifier.padding(horizontal = 4.dp).height(7.dp).width(if (i == page) 22.dp else 7.dp)
                        .clip(CircleShape).background(if (i == page) color else Color.White.copy(alpha = 0.22f)))
                }
            }
            Box(
                Modifier.padding(horizontal = 28.dp).fillMaxWidth().clip(CircleShape).background(color).clickable { next() }.padding(vertical = 16.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(stringResource(if (last) R.string.done else R.string.wn_next), color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            }
            Box(
                Modifier.padding(start = 28.dp, end = 28.dp, top = 10.dp, bottom = 16.dp).fillMaxWidth().clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.08f)).clickable { onChangelog() }.padding(vertical = 14.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(stringResource(R.string.wn_show_changelog), color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.Medium)
            }
        }
    }
}

@Composable
private fun WelcomePage() {
    val version = WhatsNew.installedVersion(LocalContext.current)
    Column(Modifier.fillMaxSize().padding(horizontal = 32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Box(Modifier.size(120.dp).clip(RoundedCornerShape(30.dp)).background(Palette.accent), contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.MusicNote, null, Modifier.size(60.dp), tint = Color.White)
        }
        Spacer(Modifier.height(28.dp))
        Text(stringResource(R.string.wn_welcome_title), fontSize = 30.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
        Spacer(Modifier.height(10.dp))
        Text(stringResource(R.string.wn_welcome_version, version), color = Palette.accent, fontSize = 20.sp, fontWeight = FontWeight.Medium)
        Spacer(Modifier.height(10.dp))
        Text(stringResource(R.string.wn_welcome_sub), color = Palette.subtle, fontSize = 16.sp)
    }
}

@Composable
private fun ItemPage(item: NewsItem) {
    Column(Modifier.fillMaxSize().padding(horizontal = 32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Box(Modifier.size(120.dp).clip(CircleShape).background(item.color), contentAlignment = Alignment.Center) {
            Icon(item.icon, null, Modifier.size(56.dp), tint = Color.White)
        }
        Spacer(Modifier.height(28.dp))
        Text(stringResource(item.title), fontSize = 28.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
        Spacer(Modifier.height(12.dp))
        Text(stringResource(item.text), color = Palette.subtle, fontSize = 16.sp, textAlign = TextAlign.Center, lineHeight = 22.sp)
    }
}

/** The version history: a card per release (newest first), one row per item. */
fun LazyListScope.versionHistory() {
    items(NewsReleases.size) { index ->
        val release = NewsReleases[index]
        val context = LocalContext.current
        val isCurrent = WhatsNew.currentRelease(context)?.version == release.version
        Column(Modifier.padding(bottom = 24.dp)) {
            Row(Modifier.padding(start = 4.dp, bottom = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(release.version, fontSize = 28.sp, fontWeight = FontWeight.Bold)
                if (isCurrent) {
                    Spacer(Modifier.width(10.dp))
                    Text(stringResource(R.string.wn_current).uppercase(), color = Palette.accent, fontSize = 11.sp, fontWeight = FontWeight.Bold,
                        modifier = Modifier.clip(CircleShape).background(Palette.accent.copy(alpha = 0.16f)).padding(horizontal = 8.dp, vertical = 4.dp))
                }
            }
            Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(22.dp)).background(Palette.card).padding(horizontal = 16.dp)) {
                release.items.forEachIndexed { i, item ->
                    if (i > 0) Box(Modifier.padding(start = 56.dp).fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.07f)))
                    Row(Modifier.padding(vertical = 14.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        Box(Modifier.size(42.dp).clip(RoundedCornerShape(12.dp)).background(item.color), contentAlignment = Alignment.Center) {
                            Icon(item.icon, null, Modifier.size(22.dp), tint = Color.White)
                        }
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(stringResource(item.title), fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                            Text(stringResource(item.text), style = MaterialTheme.typography.bodyMedium, color = Palette.subtle)
                        }
                    }
                }
            }
        }
    }
}
