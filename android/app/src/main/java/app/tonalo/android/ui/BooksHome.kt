package app.tonalo.android.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavController
import app.tonalo.android.R
import app.tonalo.android.data.bookErrorText
import app.tonalo.android.data.localTitle
import app.tonalo.android.tonalo
import kotlinx.coroutines.launch

// The audiobook part of the Home page (BooksHomeContent of ios/Tonalo/Views/AudiobookViews.swift).

/**
 * Items for the Home page's `LazyColumn`: the shelves of the Audiobookshelf server ("Continue listening" first, then
 * the others, see [AudiobookLibrary.shelves]). Empty when no server is connected. Used by HomeScreen, also for accounts
 * without music. Pull to refresh on Home should call `app.books.load(force = true)`.
 */
fun LazyListScope.booksHomeItems(nav: NavController) {
    item(key = "books-home") { BooksHomeContent() }
}

/** The shelves themselves, in a column: loading wheel, error with retry or a hint while there are none. Used by [booksHomeItems]. */
@Composable
fun BooksHomeContent() {
    val context = LocalContext.current
    val books = context.tonalo.books
    val scope = rememberCoroutineScope()
    val connected by books.connected.collectAsState()
    val shelves by books.shelves.collectAsState()
    val loading by books.loading.collectAsState()
    val error by books.error.collectAsState()
    val started by books.inProgress.collectAsState()
    // Without a connection what is being listened to is still known
    val offlineStarted = shelves.isEmpty() && started.isNotEmpty()
    LaunchedEffect(connected) { if (connected) books.load() }
    if (!connected) return
    Column(Modifier.fillMaxWidth()) {
        if (offlineStarted) BookShelf(context.getString(R.string.books_shelf_continue_listening), started)
        shelves.forEach { shelf -> BookShelf(shelf.localTitle(context), shelf.items) }
        if (shelves.isEmpty() && !offlineStarted) when {
            loading -> Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            error != null -> Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(error?.bookErrorText(context) ?: "", color = Palette.secondaryText)
                Button(onClick = { scope.launch { books.load(force = true) } }) { Text(stringResource(R.string.retry)) }
            }
            else -> Text(stringResource(R.string.bk_nothing_yet), Modifier.padding(16.dp), color = Palette.subtle, fontSize = 15.sp)
        }
    }
}
