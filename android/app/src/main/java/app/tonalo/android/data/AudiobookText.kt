package app.tonalo.android.data

import android.content.Context
import app.tonalo.android.R

// The Android side of the audiobook texts: error messages and shelf titles from the string resources.

/** A message for the user for whatever went wrong talking to Audiobookshelf. */
fun Throwable.bookErrorText(context: Context): String = when (this) {
    is AudiobookError.Login -> context.getString(R.string.books_error_login)
    is AudiobookError.NotConnected -> context.getString(R.string.books_error_not_connected)
    is AudiobookError.Refused -> context.getString(R.string.books_error_refused)
    is AudiobookError.Unexpected -> context.getString(R.string.books_error_unexpected)
    is AudiobookError.Http -> context.getString(R.string.books_error_http, status)
    is AudiobookError.SaveFailed -> context.getString(R.string.books_error_save)
    is java.io.IOException -> context.getString(R.string.error_network)
    else -> message ?: context.getString(R.string.books_error_unexpected)
}

/** The shelf's title in the app's language; shelves the server invented keep the label it sent. */
fun ABSShelf.localTitle(context: Context): String = when (id) {
    ABSShelf.CONTINUE_LISTENING -> context.getString(R.string.books_shelf_continue_listening)
    "continue-series" -> context.getString(R.string.books_shelf_continue_series)
    "recently-added" -> context.getString(R.string.books_shelf_recently_added)
    "episodes-recently-added" -> context.getString(R.string.books_shelf_new_episodes)
    "recommended" -> context.getString(R.string.books_shelf_recommended)
    "listen-again" -> context.getString(R.string.books_shelf_listen_again)
    "discover" -> context.getString(R.string.books_shelf_discover)
    else -> title
}
