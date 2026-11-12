<p align="center"><img src="assets/icon-512.png" width="112" alt="Tonalo icon"></p>

<h1 align="center">Tonalo</h1>

<p align="center">A Navidrome client for LG TVs, Windows, Mac and the iPhone. Play your own music library from the couch with nothing but the remote, or take it with you.</p>

<p align="center"><a href="https://tonalo.app">tonalo.app</a> · <a href="https://tonalo.app/changelog">Changelog</a> · <a href="https://apps.apple.com/app/id6827727370">iPhone app</a> · <a href="https://github.com/Wzkiie/tonalo/releases/latest">Windows, Mac &amp; TV download</a></p>

<p align="center">
  <img src="assets/screenshots/tv/home.jpg" width="74%" alt="TV app home screen">
  <img src="assets/screenshots/ios/home.jpg" width="19%" alt="iPhone app home screen">
</p>

Tonalo talks to any server that speaks the Subsonic API. It was built and tested against Navidrome; other Subsonic servers should work but haven't been tried.

There are three apps in this repository. The TV and Windows apps share their code; the iPhone app is written natively for its platform:

| | TV app | Windows app | iPhone app |
|---|---|---|---|
| Runs on | LG TVs with webOS 5 or newer | Windows 10 and 11 (64-bit) | iPhone with iOS 17 or newer, plus Apple Watch |
| Code | [`tv/`](tv) – plain HTML, CSS and JavaScript | [`desktop/`](desktop) – the TV app in an Electron window | [`ios/`](ios) – Swift and SwiftUI |
| Install | Homebrew Channel [repository](#installing) or `.ipk` from the [releases](../../releases/latest) | `Tonalo-Setup-….exe` from the [releases](../../releases/latest), updates itself | [App Store](https://apps.apple.com/app/id6827727370), or build it with Xcode |

## TV app

Navidrome's web UI technically works in the TV browser, but it's made for a mouse and gets fiddly fast. The TV app is a native webOS app built around the remote: arrow keys and OK to get around, Back to go back, and the play/pause and skip buttons do what you'd expect.

### What it does

- Home screen with recently played, recently added, most played and a shuffle mix
- Albums, artists, playlists, genres, favorites and search
- Full-screen player with synced lyrics (if your server has them)
- Queue that survives restarts, plus "play next" and adding to playlists (with a warning for duplicates). Songs in the queue can be moved with ▲▼
- **Endless radio** from a song, an artist, a genre or your favorites – it tops itself up and learns from skips and hearts. Autoplay keeps going with similar songs when an album or playlist ends
- **Radio stations** set up on your server (Navidrome: Radio) play live
- Rename and delete your playlists and remove songs from them; a sleep timer, crossfade (3–12 seconds) and volume leveling with ReplayGain
- **Continue on another device**: the queue is kept on your server, so the TV offers to pick up where the iPhone left off (and the other way round)
- **Control it from your iPhone**: pair once with a code shown on the TV. The iPhone then shows what's playing and the queue, works as a remote, and sends albums, playlists and radio to the TV – or moves the song you're hearing over, at the same second. Everything stays in your home network
- **Jukebox**: friends nearby join with a code on the TV, add up to 20 songs to what's playing and skip. They need an account on the same server and don't see whose account is playing; the TV briefly shows who added what
- **Audiobooks and podcasts from Audiobookshelf** (optional): connect your server under Settings, per account. A *Hörbücher* page with Continue listening and new books, libraries, search, chapters, podcast episodes, speed, skip buttons and a sleep timer, and your progress stays in sync with the server. A book you started on the iPhone moves to the TV at the same second and back, and the phone works as a remote for it – the same way as music
- **DJ** (optional, set up on the iPhone): an AI picks sets from your library and you steer it with *More like this*, *Something else*, moods or a wish in your own words. You bring your own key for Anthropic or Google, or use your own Ollama. If you turn on *Use on paired devices* on the iPhone, the TV gets the setup automatically when it's paired – see [Privacy](PRIVACY.md)
- Several people on one TV: everyone signs in once, then picks their profile on start. Queues and settings stay separate.
- Transcoding options for weaker Wi-Fi, scrobbling, and a moving screensaver so the OLED doesn't burn in
- English, German, Spanish, French, Italian, Portuguese, Dutch, Polish and Turkish – it follows the TV's language

| | |
|---|---|
| ![Now playing with lyrics](assets/screenshots/tv/nowplaying.jpg) | ![Album](assets/screenshots/tv/album.jpg) |
| ![Artist](assets/screenshots/tv/artist.jpg) | ![Search](assets/screenshots/tv/search.jpg) |
| ![Endless radio and genre radios](assets/screenshots/tv/radio.jpg) | ![A radio station playing live](assets/screenshots/tv/station.jpg) |

<p align="center"><img src="assets/screenshots/tv/users.jpg" width="49%" alt="Profile picker"></p>

### Installing

**Rooted TV with the Homebrew Channel (easiest)** – add Tonalo's repository once, then install and update it like any other Homebrew app. In the Homebrew Channel open *Settings*, choose *Add repository* and enter:

```
https://raw.githubusercontent.com/Wzkiie/tonalo/repo/apps.json
```

Tonalo then shows up in the app list. New versions appear there as soon as they're released.

The other ways need the `.ipk` from the [latest release](../../releases/latest).

**Rooted TV, by hand** – the deploy script, which uploads the package over the root telnet shell, installs it and starts the app:

```bash
python3 tv/tools/deploy.py 192.168.x.x    # your TV's IP
```

With SSH enabled you can also do it by hand:

```bash
scp tonalo_*.ipk root@<tv-ip>:/tmp/tonalo.ipk
ssh root@<tv-ip> "luna-send-pub -i 'luna://com.webos.appInstallService/dev/install' '{\"id\":\"tonalo\",\"ipkUrl\":\"/tmp/tonalo.ipk\",\"subscribe\":true}'"
```

**TV in Developer Mode** – install the package with [webOS Dev Manager](https://github.com/webosbrew/dev-manager-desktop) or `ares-install`. Keep in mind that Developer Mode expires unless you extend the session, and the TV removes the app when it does.

On first start, enter your server address (for example `http://192.168.1.10:4533`), user name and password. The password itself isn't stored, only the salted token the Subsonic API uses.

Tested on an LG OLED65CX with webOS 5.6. Anything from webOS 5 up should be fine; older versions are untested.

### Remote

| Button | Action |
|---|---|
| Arrows / OK | Move around / select |
| Back | Go back; at the top level it takes you to the sidebar, then asks to quit |
| ▶ ❚❚ ■ | Play, pause, stop |
| ⏪ ⏩ | Skip 10 seconds, hold to change songs |
| CH + / – | Scroll a page at a time |
| Red / Green / Yellow / Blue | Now playing / Search / Options / Play-pause |

The Magic Remote pointer works too.

## Windows app

The same app as on the TV, made for mouse and keyboard: the same screens and features, including endless radio, lyrics, crossfade and several profiles. On top of that:

- Click anywhere in the progress bar to jump there, a volume slider (or scroll on it), right-click for the options menu
- Keyboard: Space plays and pauses, Ctrl + ← / → changes the song, Ctrl + F searches, Esc goes back, Ctrl + Plus / Minus makes everything bigger or smaller
- Media keys and the Windows media overlay show and control what's playing
- **Control it from your iPhone and host a Jukebox**, just like the TV: pair under *Devices* in the iPhone app, guests join under *Jukebox*. Windows asks once whether Tonalo may use the network – allow it for private networks
- **Custom HTTP headers per server**, entered under *Custom headers* at sign-in, for servers behind Cloudflare Access (service token), Authelia or a similar proxy. There's a one-click preset for the two Cloudflare Access headers. The values are stored encrypted with Windows' own data protection, go out with every request to that server including music and cover art, and never to any other address, not even after a redirect
- Custom headers can be changed later under Settings → *Custom headers*; new values are only saved if the server answers with them
- **A second address** per account (Settings → *Second address*): one in your home network, one reachable from outside. At home Tonalo uses the home address as soon as the same server answers there, and switches back when you leave, mid-song. Custom headers only go to the outside address
- **Audiobookshelf** works like on the TV, and custom headers entered for that server are used for it too
- **Updates install from inside the app**: Tonalo checks GitHub for a new release on start, asks, downloads it and restarts. Settings → Updates checks by hand

### Installing on Windows

Download `Tonalo-Setup-<version>.exe` from the [latest release](../../releases/latest) and run it. It installs for your user only, no admin rights needed. The installer isn't code-signed, so Windows SmartScreen warns the first time: click *More info* → *Run anyway*.

### Installing on the Mac

The same app also runs on macOS. Download `Tonalo-<version>-mac-arm64.dmg` (Apple Silicon) or `Tonalo-<version>-mac-x64.dmg` (Intel) from the [latest release](../../releases/latest), open it and drag Tonalo into *Applications*. The app isn't notarized by Apple, so macOS refuses it the first time: right-click Tonalo, choose *Open*, then *Open* again (or allow it under *System Settings → Privacy & Security*). It has no automatic updates; download the new `.dmg` when there's one. Custom header values are kept encrypted in the Keychain.

## iPhone app

A native SwiftUI app that feels like the big streaming apps rather than a classic Subsonic client.

<p align="center">
  <img src="assets/screenshots/ios/player.jpg" width="30%" alt="Player">
  <img src="assets/screenshots/ios/lyrics.jpg" width="30%" alt="Synced lyrics">
  <img src="assets/screenshots/ios/album.jpg" width="30%" alt="Album">
</p>
<p align="center">
  <img src="assets/screenshots/ios/search.jpg" width="30%" alt="Search with genres">
  <img src="assets/screenshots/ios/library.jpg" width="30%" alt="Your library">
  <img src="assets/screenshots/ios/radio.jpg" width="30%" alt="Endless radio">
</p>
<p align="center">
  <img src="assets/screenshots/ios/station.jpg" width="30%" alt="A radio station playing live, with the song on air found in your library">
</p>

### What it does

- Home, search with genre tiles, and a library with playlists, albums, artists and downloads – sortable, searchable, with pinning (long press) and as a list or grid
- Player with synced lyrics, a queue you can reorder by dragging, swipe gestures, colors taken from the cover and a sleep timer
- **Endless radio**: from a song, an artist, a genre or your favorites. It tops itself up, plays more like what you hear to the end or give a heart, and less of what you skip. Without Last.fm it stays in the genre. When an album or playlist ends, Autoplay keeps going with similar songs (can be turned off)
- **Radio stations**: the stations set up on your server (Navidrome: Radio) play live, with the song on air when the station sends it. If that song is in your library, one tap plays it from there
- **Artist pages** with popular songs, the discography, "Fans also like" and a biography. Without Last.fm on the server, the artist's songs you played most stand in for the popular ones – see [Server tips](#server-tips)
- **Continue on another device**: started on the TV, finished on the iPhone – the app offers to pick up the queue another device left on your server
- **Play on the TV or PC**: pair the iPhone once under *Devices* with a code shown on your TV or in Tonalo for Windows (the PC shows up with a computer icon). While the TV plays, the phone shows it live, and music you pick on the phone plays on the TV. "Play on iPhone" takes it back at the same second. When the TV app is open, *Play on* in the full-screen player picks where the music plays
- **Jukebox** (its own page, next to *Devices*): friends nearby join with a code, add songs to what's playing and skip. The TV or PC hosts it at home, an iPhone in the car – the phones connect directly, without Wi-Fi. Guests need an account on the same server. If someone else is signed in on your TV, your iPhone offers to join their Jukebox instead
- **DJ** (optional, off until you set it up): an AI picks sets from your library. Start it from Home or Your Library, steer it with *More like this*, *Something else*, moods or a wish in your own words. You bring your own key for Anthropic or Google, or point it at your own Ollama – there is no Tonalo server in between. With *Use on paired devices* your own TV, PC or Mac gets the same setup. What is sent is listed in the [privacy policy](PRIVACY.md)
- **Playlists**: create, rename and delete them, add songs from any menu (with a warning for duplicates), remove and reorder songs
- **Crossfade** between songs, adjustable from 1 to 12 seconds
- **Audio quality** set separately for Wi-Fi, cellular and downloads: the original files (lossless, FLAC stays FLAC) or converted by your server to AAC, Opus or MP3, with the data an hour of music takes next to each level. Formats the iPhone can't play are converted automatically.
- **Offline downloads** of songs, albums and playlists, in the background, optionally only on Wi-Fi. A small counter above the player shows how far they are on every page, and a note says when they're done. Lyrics come along, and scrobbles made offline are sent later.
- **Library sync**: loads every album, artist and playlist onto the phone in one go, so the whole library opens instantly and offline. Repeat it whenever you like; the app reminds you after a month.
- **Loading ahead**: the next songs of the queue (1–5, adjustable) are loaded in the background, so a dead spot on the train doesn't stop the music
- **Address at home**: on Wi-Fi the app talks to your server directly in the home network when it answers, and switches back to the outside address when you leave – mid-song without a gap
- **Volume leveling** with the ReplayGain tags of your files, per song or per album
- **Favorites from the lock screen**: a heart button for Control Center and the lock screen (iOS 18+) and a Siri shortcut ("Add this song to my favorites in Tonalo")
- **Apple Watch app**: player with cover, favorites, shuffle and the iPhone's volume on the Digital Crown, plus your playlists and favorites to start music from the wrist. It remote-controls the iPhone.
- **CarPlay**: Home, Library and Downloads on the car screen, with shuffle, repeat and a heart in the player (no search – Apple doesn't allow a keyboard in CarPlay music apps)
- Several accounts, accent colors and alternative app icons
- **Audiobooks and podcasts from Audiobookshelf**: connect your server under Settings, per account, with its own address outside and at home and its own custom headers (Cloudflare Access and similar). A *Continue listening* shelf on Home, results in Search, pages for authors and series, hearts for books and authors that fill Your Library, a player with chapters, speed, skip buttons and a sleep timer, downloads for listening offline, and your progress stays in sync with the server
- **Custom HTTP headers per account**, sent with every request including the audio stream and cover art, so servers behind Cloudflare Access (service token), Authelia or a similar proxy work. There's a one-tap preset for the two Cloudflare Access headers, and all secrets live in the iOS Keychain.
- English and German

### Installing

**App Store (easiest):** get [Tonalo: Navidrome Player](https://apps.apple.com/app/id6827727370) and tap *Get*. The Apple Watch app comes along if your iPhone is paired with a watch.

Feedback is very welcome – as a [GitHub issue](../../issues/new/choose),. The app collects nothing (see the [privacy policy](PRIVACY.md)).

**Build it yourself:** to put your own build on your phone:

1. Open `ios/Tonalo.xcodeproj` in Xcode.
2. Create `ios/Local.xcconfig` with your team ID, `DEVELOPMENT_TEAM = ABCDE12345` (git ignores this file). Alternatively, pick your Apple ID as the team under *Signing & Capabilities* for the Tonalo, TonaloControls and TonaloWatch targets.
3. Connect your iPhone and run the *Tonalo* scheme. The watch app comes along automatically if your iPhone is paired with an Apple Watch.

With a free Apple ID the app has to be reinstalled every 7 days. CarPlay needs an entitlement Apple grants per developer account, so for your own build switch it off with `TONALO_APP_ENTITLEMENTS =` in `ios/Local.xcconfig` (details in [`docs/CARPLAY.md`](docs/CARPLAY.md)).

## Server tips

**Connect Last.fm to Navidrome.** Popular songs, similar artists ("Fans also like") and artist biographies come from your server, and Navidrome gets them from Last.fm. Without it, both apps still work, but artist pages stay rather empty (the iPhone app shows your own most played songs instead). Setting it up takes two minutes and is free:

1. Create an API account at [last.fm/api/account/create](https://www.last.fm/api/account/create) – only the application name is required. Note the *API key* and *Shared secret*.
2. Give them to Navidrome, for example in your Docker Compose file:

   ```yaml
   environment:
     ND_LASTFM_APIKEY: your-api-key
     ND_LASTFM_SECRET: your-shared-secret
   ```

   or as `LastFM.ApiKey` and `LastFM.Secret` in `navidrome.toml`.
3. Restart Navidrome. Artist info is fetched when an artist is opened, so the first visit can take a moment.

The same key also lets every user scrobble to Last.fm from Navidrome's web UI. Details are in Navidrome's [external integrations](https://www.navidrome.org/docs/usage/external-integrations/) docs.

**Lyrics** come from your server too: Navidrome shows lyrics that are embedded in the files or stored next to them as `.lrc`.

## Development

### TV app

There's no framework and no build step – plain HTML, CSS and JavaScript in `tv/app/`. The code sticks to what the Chromium 68 engine in webOS 5 understands, so no optional chaining, `??`, flexbox `gap` and so on.

```bash
node tv/tools/mock_server.js            # demo server + app on http://localhost:4599
python3 tv/tools/build_ipk.py           # builds tv/dist/*.ipk and the Homebrew Channel manifest
node tv/tools/i18n_check.js             # checks that every language has every string
swift tv/tools/screenshots.swift http://localhost:4599 shots   # renders the TV screenshots (macOS)
```

In a desktop browser the UI scales to the window, and arrow keys, Enter and Esc behave like the remote. Log in to the mock server with any user name and password.

**Translations:** German is the source language. The code uses `T('German text')` and each file in `tv/app/js/lang/` maps those strings to another language. To add a language, copy `en.js`, translate it, and register it in `index.html` and `tv/app/js/i18n.js`. Corrections from native speakers are very welcome.

**Releases:** bump the version in `tv/app/appinfo.json` and `tv/app/js/util.js`, commit, then push a tag (`git tag v1.5.1 && git push origin v1.5.1`). GitHub Actions builds the TV package, the Windows installer and the two Mac images and publishes them in one release.

### Windows app

The screens come straight from `tv/app`; `tv/app/js/desktop.js` and `tv/app/css/desktop.css` hold what only applies on Windows (they do nothing on the TV). `desktop/` is the Electron shell around it: the window, the iPhone service from `tv/service` running in the main process, and updates through `electron-updater`. The version is always the TV app's.

```bash
cd desktop && npm ci
npm start               # run it from source (copies tv/app into desktop/web first)
npm run dist            # build the installer into desktop/dist
```

The release workflow attaches the installer to the same release as the TV app, together with the `latest.yml` the installed apps read their updates from. The Mac images are built the same way (`npm run dist:mac` in `desktop/`), ad-hoc signed, and don't update themselves. *Windows-Testbuild* in the Actions tab builds an installer to try out without releasing anything.

### iPhone app

Swift 5 with SwiftUI and `@Observable`, no third-party dependencies. Texts live in String Catalogs (`Localizable.xcstrings`), with English as the source language.

The iPhone screenshots use the same demo server as the TV. It draws its covers as SVG, which iOS can't show, so render them to PNG first:

```bash
swift ios/tools/render_covers.swift http://localhost:4599 covers
MOCK_COVERS=covers node tv/tools/mock_server.js
```

Debug builds sign in to that server when launched with `-demoAccount -demoServer http://localhost:4599`, and `-demoQueue` fills the queue without starting playback. `-demoHome <url>` and `-demoHeader Name=value` set a home address and a custom header, to try both routes.

The demo server has a few switches for testing: `MOCK_SILENT=1` streams silence, `MOCK_LOG=1` prints every request with the address it came in on, and `MOCK_SLOW=1` makes downloads take about 20 seconds. Start a second one on another port (`node tv/tools/mock_server.js 4598`) to stand in for the home address.

The screenshots in this README use a made-up demo library (`tv/tools/mock_server.js`), not real artists.

## Security

- Your password is never stored. Like every Subsonic client, Tonalo keeps the salted token derived from it, and that token is sent with each request. Anyone who gets hold of it can use your server account (but not learn the password) – so use https for any server reachable from the internet.
- iPhone: the token and custom headers live in the Keychain, only on that device. Library info and covers are kept on the device so pages open at once and offline, but never the request addresses, which carry the token. Custom headers never follow a redirect to another host, and plain http is only tried automatically for home-network addresses.
- Windows: custom header values are encrypted on disk (Windows data protection) and stay in the app's main process, which adds them to requests for exactly that server. The screens can set them but never read them back. Over plain http they only go to home-network addresses.
- Audiobookshelf on the TV and PC: only the tokens are kept (the password never), in the same place as the Navidrome token. Audiobookshelf doesn't let web apps talk to it, so the app's background service makes these requests; it only speaks http or https, never follows a redirect (the login can't be sent to another server) and limits the size of answers. The audio itself plays through a listening session, so no token ends up in a stream address.
- TV and iPhone pairing: the code shown on the screen never goes over the network. Both sides agree on a key (ECDH) and the phone proves it knows the code; every request after that is signed and can't be replayed. Each iPhone gets its own key, and nothing leaves your home network.
- DJ: the key for the AI provider lives in the iPhone's Keychain and is only sent to that provider's fixed address, never after a redirect. The answer is treated as untrusted: it can only pick songs from the numbered list it was given. If you share the DJ with your paired devices, the key travels encrypted with the pairing key (AES-GCM) to devices paired with the same account, never to Jukebox guests. Windows and Mac keep it encrypted with the system's data protection and only the background service reads it; the TV has no secure storage, so there it sits in the app's storage – use a key with a spending limit. The DJ makes at most 20 requests an hour per device.
- Second address on Windows and Mac: the home address is only used while the PC is in the network where the same server was seen answering there, so the login doesn't go to a stranger's device in another network with the same addresses.
- TV: webOS has no secure storage, so the token sits in the app's local storage. Without a scheme, addresses in the home network use http and all others https.

Found a security problem? Please report it privately – see [SECURITY.md](SECURITY.md). For bugs and ideas, use the [issue forms](../../issues/new/choose).

## Notes

Tonalo doesn't collect any data – see the [privacy policy](PRIVACY.md). It isn't affiliated with Navidrome, LG or Apple. A good part of the code was written together with an AI coding assistant; everything was tested on a real TV and iPhone.

## License

[MIT](LICENSE)
