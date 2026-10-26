# Privacy Policy

*Last updated: October 26, 2026*

This policy covers the Tonalo apps for LG webOS TVs, iPhone and Apple Watch.

## The short version

Tonalo doesn't collect anything. There are no accounts with us, no analytics, no ads, no tracking and no third-party SDKs. The apps only talk to the music server **you** enter, and everything else stays on your device.

## What is stored on your device

- **Login details:** the server address (and, if you add one, a second address for your home network), your user name, the authentication token and salt derived from your password, and any custom HTTP headers you add (for example a Cloudflare Access service token). On iPhone these are stored in the iOS Keychain. Your password itself is never stored.
- **App data:** settings, the appearance you chose, your play queue and recent search. On iPhone this lives in the app's own storage; on the TV in the app's local storage.
- **Downloads (iPhone):** songs you download for offline listening, with their cover art and lyrics, are stored in the app's own storage.
- **Library cache (iPhone):** what you've browsed – album, artist and playlist lists, your favorites and cover art – is kept in the app's storage, so pages open at once and still show without a connection. It contains no login details and is removed together with the account.
- **Apple Watch:** the watch app gets what it shows – the song that's playing, its cover and your playlists – from your iPhone over Apple's watch connection. It never talks to the server itself and stores no login details.

None of this is sent to us – we have no server that could receive it.

## What is sent, and where

Tonalo connects only to the Subsonic-compatible server you configure (for example your own Navidrome). Requests to that server include your user name, the authentication token and your custom headers, and they're used to browse your library, stream music, load cover art and lyrics, and – if scrobbling is turned on – report which songs you played. What your server does with that data is up to whoever runs it.

To let you continue on another device, the apps save your play queue and the position in the current song on that same server (the Subsonic "play queue" feature) and read it back when you open them.

If you set an address for your home network, the iPhone app uses it on Wi-Fi when it answers. Your custom headers are not sent to that address.

The iPhone app only opens other websites when you tap a link yourself, such as the GitHub link in Settings.

## Deleting your data

Removing an account in the app deletes its login details, play queue and downloads from the device. The play queue saved on your server stays there until it's replaced or removed on the server. Uninstalling the app removes everything else.

## Children

Tonalo isn't aimed at children and doesn't knowingly collect any data from anyone.

## Changes and contact

If this policy changes, the new version will be published here with a new date. Questions can be asked through the project's [GitHub issues](https://github.com/Wzkiie/tonalo/issues).

---

## Datenschutz (Kurzfassung auf Deutsch)

Tonalo erhebt keine Daten: keine Konten bei uns, keine Analyse, keine Werbung, kein Tracking, keine Fremd-SDKs. Die Apps verbinden sich ausschließlich mit dem Musikserver, den du selbst einträgst. Zugangsdaten (Serveradresse, Benutzername, aus dem Passwort berechneter Token und eigene Header) bleiben auf deinem Gerät – auf dem iPhone im Schlüsselbund; das Passwort selbst wird nie gespeichert. Damit du auf einem anderen Gerät weiterhören kannst, legen die Apps die Warteschlange auf deinem eigenen Server ab. Konto in der App entfernen oder App löschen entfernt die Daten vom Gerät. Fragen über die [GitHub-Issues](https://github.com/Wzkiie/tonalo/issues).
