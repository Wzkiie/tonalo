# Tonalo for Android

A native Android app for Navidrome and other Subsonic servers. It is written in Kotlin with Jetpack Compose and Media3, and modelled on the iPhone app in [`ios/`](../ios).

**Status: early version.** It looks and reads like the iPhone app (same pages, same wording) and has its music features, including the TV remote, the Jukebox and the DJ, plus Audiobookshelf. So far it was only tried on an emulator, not on a real phone, and the Audiobookshelf part was not tested at all yet.

## What it does

- **Sign in:** server address, user and password. You can add custom headers (Cloudflare Access and similar) and an optional **home address**. The home address is used on Wi-Fi when the same server answers there. Several accounts are supported.
- **Same look as the iPhone app:** black or dark gray background, an accent color you pick, and pages tinted with the cover's color (player, albums, mini player).
- **Home:** quick tiles, *Made for you* (Shuffle mix, Favorites mix, Discover), *Radio*, then album shelves. There are chips for Playlists and Downloads.
- **Search:** *Browse all* genre tiles, then artists, albums and songs.
- **Your Library:** Favorite songs and Downloads pinned on top, then playlists and albums. Chips filter by Playlists, Albums, Artists or Downloads.
- **Pages:** album, artist (top songs, biography, artist radio) and playlist (reorder songs, remove songs, delete the playlist).
- **Endless radio:** Your radio, *More like …*, genre radios, *Radio from this song*. It tops itself up and learns from skips and hearts, like on the iPhone.
- **Radio stations** from the server play live and show the current title.
- **Offline downloads** of songs, albums and playlists, in a quality of their own. Downloaded songs play without a connection.
- **Player:** seek bar, shuffle, repeat, lyrics page (synced, tap a line to jump), queue page (reorder, remove, clear) and a sleep timer (minutes or end of song).
- **Background playback:** notification, lock screen, headphone and Bluetooth buttons, *resume* after the app was closed, with heart and shuffle buttons in the system's media controls.
- **Android Auto:** four tabs (Home with mixes and albums, Playlists, Library with artists, albums, favorites and downloads, Radio with endless radios and stations), search, voice requests ("Hey Google, play Silver Weather on Tonalo"), heart, shuffle and radio buttons, and covers. Covers reach the car through the app's own content provider (`playback/Covers.kt`), so the server login never leaves the app.
- **Quality** for Wi-Fi, mobile data and downloads.
- **More playback settings:** fading between songs, volume leveling with ReplayGain, autoplay when an album ends, and an equalizer (five bands, presets; it uses the phone's own audio effect, so it also works in Android Auto and over Bluetooth).
- **Scrobbling:** plays without a connection are sent later, with the time they were played.
- **Continue on another device:** the queue is kept on the server.
- **TV & Jukebox** (same protocol as the iPhone app, `tv/service/service.js`):
  - Pair once with the code your Tonalo TV or computer shows. It's found with mDNS (`_tonalo._tcp`), or by address when the network blocks mDNS.
  - While the TV plays, the player here shows it and works as its remote: play/pause, skip, seek, jump in the queue, shuffle, repeat and heart.
  - Music you pick here plays there. *Play on TV* moves what plays on the phone over at the same second, and *Play here* brings it back.
  - Join a Jukebox as a guest: add songs and skip.
  - Host a Jukebox on the phone: friends join with a code shown on the phone.
- **DJ** (optional, same rules as the iPhone app):
  - An AI model you choose picks sets from your library: Ollama on your own computer, Ollama Cloud, Anthropic or Google Gemini, with your own key.
  - You steer it with *More like this*, *Something else*, moods or a wish you type. It can also take over from the song that plays.
  - Off until you agree to what is sent. The page shows exactly what goes out.
  - It sends at most 20 requests an hour. When the provider can't be reached, the radio fills in.
  - Can be shared with your paired TV or computer. The setup is sealed with AES-GCM, using a key derived from the pairing.
- **Audiobooks and podcasts** (Audiobookshelf, optional, like the iPhone app):
  - Connect at sign-in (*Music*, *Audiobooks* or *Both*) or later under Settings. A books-only account works too.
  - Home shelves, browse by title, author, series, narrator and genre, search, favorites, progress and *mark finished*.
  - The player has chapters, speed, skip intervals, a sleep timer (also at the end of a chapter) and syncs your progress to the server, also after being offline.
  - Downloads for offline listening. A book plays in the same player service as the music; the music queue is put aside and comes back afterwards.
  - Controlling a TV with books is not part of the Android app yet.
- Saved library answers, so pages show at once and work offline.
- English and German.

## Security notes

- Accounts (token, salt, header values) are stored AES-GCM-encrypted with a key in the Android Keystore. Backups are off.
- The password itself is never stored, only the Subsonic token `md5(password + salt)`.
- Redirects are only followed to the same host and never from https down to http, so custom headers and the token only reach your own server.
- Covers get the custom headers only when they come from the account's own server.

## Building

You need Android Studio (Ladybug or newer) or JDK 17 with the Android SDK (API 35).

1. In Android Studio, choose *Open* and pick the `android/` folder. Studio downloads Gradle 8.11.1 and all dependencies by itself.
2. Run the `app` configuration on a phone or emulator (Android 8.0 / API 26 or newer).

Without Android Studio (JDK 17 and the Android SDK installed, `ANDROID_HOME` set):

```bash
./gradlew assembleDebug
```

## Testing Android Auto

`app/src/androidTest/.../AndroidAutoTest.kt` talks to the playback service the way Android Auto does: it browses the tabs, opens covers, searches, plays songs, albums, mixes, a radio and voice requests, and presses the heart. It needs the app signed in to a server (the demo server from `tv/tools/mock_server.js` works):

```bash
./gradlew assembleDebug assembleDebugAndroidTest
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb install -r app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb shell am instrument -w app.tonalo.android.test/androidx.test.runner.AndroidJUnitRunner
```

On a phone with the real Android Auto app, the Desktop Head Unit (`sdkmanager "extras;google;auto"`) shows the car screen; developer settings in Android Auto need *Unknown sources* switched on for a debug build.

## Not there yet

These are in the iPhone app but not on Android yet:

- Sending audiobooks to the TV and controlling a TV that plays a book
- A Wear OS app (the counterpart of the Apple Watch app)

"Fading between songs" is a fade out and in. ExoPlayer has one output, so two songs don't overlap the way they do on the iPhone.
