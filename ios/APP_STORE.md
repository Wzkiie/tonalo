# App Store – Einreichen

Alles, was beim Einreichen der iPhone-App in App Store Connect gebraucht wird. Die Blöcke unter „Zum Einfügen“ sind auf Englisch und können direkt kopiert werden.

## Schon im Code erledigt

- **Privacy Manifest** (`Tonalo/PrivacyInfo.xcprivacy`): kein Tracking, keine erhobenen Daten; `UserDefaults` mit Grund `CA92.1` (nur eigene App-Daten).
- **Verschlüsselung:** `ITSAppUsesNonExemptEncryption = NO` in `Info.plist` – die App nutzt nur Standard-HTTPS von iOS, damit entfällt die Export-Frage bei jedem Upload.
- **Zugangsdaten** im Schlüsselbund (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), Passwort wird nie gespeichert.
- **Berechtigungstext** für das lokale Netzwerk auf Englisch und Deutsch.
- **Datenschutzerklärung:** [`PRIVACY.md`](../PRIVACY.md)

## In App Store Connect ausfüllen

| Feld | Eintrag |
|---|---|
| Kategorie | Music |
| Datenschutzerklärung (URL) | `https://github.com/Wzkiie/tonalo/blob/main/PRIVACY.md` |
| Support-URL | `https://github.com/Wzkiie/tonalo/issues` |
| App Privacy | **Data Not Collected** („Es werden keine Daten erhoben“) |
| Copyright | `2026 Wzkiie` |
| Altersfreigabe | Fragebogen ehrlich ausfüllen. Die App zeigt nur Musik aus der eigenen Bibliothek des Nutzers, hat keinen Browser und keine Inhalte von uns. |
| Anmeldung für Prüfer | Ja, Zugangsdaten siehe unten |
| EU-Händlerstatus (DSA) | **Nicht-Händler** wählen, solange die App kostenlos ist und keine Einnahmen hat. Als Händler werden Name, Adresse, Telefon und E-Mail öffentlich im Store angezeigt. |

Name und Untertitel: „Tonalo“ als Name. Navidrome nur beschreibend verwenden, z. B. Untertitel *Music player for Navidrome*, nie so, dass es wie die offizielle App wirkt.

## Zum Einfügen: Sign-in information

```
Server:   https://demo.navidrome.org
Username: demo
Password: demo
```

## Zum Einfügen: Notes for the reviewer

```
Tonalo is a client for self-hosted music servers that speak the Subsonic API
(for example Navidrome). It does not include, sell or stream any music of its
own – users connect to their own server and play their own library.

To test, sign in with the public Navidrome demo server above. Its library
consists of Creative Commons music provided by the Navidrome project.

Background audio: the app plays music in the background and on the lock
screen, like any music player.

App Transport Security (NSAllowsArbitraryLoads): users enter the address of
their own server. Self-hosted servers very often run on a home network
(e.g. http://192.168.1.10:4533) or behind a reverse proxy without a public
certificate, so the app has to allow plain HTTP connections to an address
the user chooses. The app does not load any other remote content.

Custom HTTP headers: users can add headers (for example a Cloudflare Access
service token) that are sent to their server. They are stored in the Keychain.

Accounts: the app does not create accounts. It only signs in to an existing
server, and accounts can be removed from the device in Settings.
```

## Vorher selbst testen

1. Mit dem Demo-Server anmelden, Album abspielen, App in den Hintergrund – Musik läuft weiter, Sperrbildschirm zeigt Cover und Steuerung.
2. In Xcode: **Product → Generate Privacy Report** – darf keine fehlenden Gründe melden.
3. Archiv bauen (**Product → Archive**) und über **Validate App** prüfen lassen, bevor hochgeladen wird.
