<p align="center"><img src="assets/icon-512.png" width="128" alt="Tonalo"></p>

# Tonalo

**Inoffizieller [Navidrome](https://www.navidrome.org/)-/Subsonic-Client für LG-Fernseher mit webOS.**
Höre deine eigene Musikbibliothek auf dem TV – komplett mit der Fernbedienung bedienbar (Pfeiltasten und Magic-Remote-Zeiger).

> Tonalo ist ein privates Hobbyprojekt und steht in keiner Verbindung zum Navidrome-Projekt oder zu LG Electronics.

Getestet auf **LG OLED65CX** (webOS 5.6, gerootet mit Homebrew Channel). Läuft vermutlich auf allen LG-TVs ab webOS 5; ältere Versionen sind ungetestet.

## Funktionen
- **Mehrere Benutzer:** Jede Person meldet sich einmal an, beim Start erscheint „Wer hört gerade?“. Warteschlange, Position und Einstellungen sind pro Person getrennt.
- **Startseite** mit Schnellzugriff, Zufallsmix sowie „Zuletzt gespielt“, „Neu hinzugefügt“, „Häufig gespielt“ und „Entdecken“
- **Bibliothek:** Alben (7 Sortierungen), Künstler (mit Bio, Top-Songs, ähnlichen Künstlern), Playlists, Genres, Favoriten, Suche
- **Player:** Leiste unten plus Vollbild mit Coverfarbe im Hintergrund, Shuffle, Wiederholen (alle/eins), Spulen
- **Synchronisierte Songtexte** (OpenSubsonic, z. B. Navidrome ≥ 0.50)
- **Warteschlange:** springen, entfernen, mischen, als Playlist speichern; bleibt nach dem Neustart erhalten
- **Kontextmenü** (gelbe Taste oder `⋯`): Als Nächstes, Warteschlange, Song-/Künstler-Radio, Favorit, Zu Playlist
- Scrobbling, Transkodierung (Original / 320 / 192 / 128 kbps, MP3 / Opus / AAC)
- **OLED-Bildschirmschoner** (wanderndes, gedimmtes Cover mit Uhr) gegen Einbrennen
- Anmeldung per Token: Das Passwort wird nicht gespeichert, nur ein daraus berechneter Token.
- **9 Sprachen:** Deutsch, English, Español, Français, Italiano, Português, Nederlands, Polski, Türkçe – automatisch nach Sprache des Fernsehers, umschaltbar in den Einstellungen

## Installation
Lade die neueste `.ipk`-Datei unter **[Releases](../../releases/latest)** herunter.

**Gerooteter TV mit Homebrew Channel** (Telnet auf Port 23 aktiv):
```bash
python3 tools/deploy.py 192.168.x.x     # IP deines Fernsehers
```
Das Skript baut das IPK, lädt es auf den TV, installiert und startet die App.
Mit SSH-Zugang geht es auch von Hand:
```bash
scp tonalo_*.ipk root@<TV-IP>:/tmp/tonalo.ipk
ssh root@<TV-IP> "luna-send-pub -i 'luna://com.webos.appInstallService/dev/install' '{\"id\":\"tonalo\",\"ipkUrl\":\"/tmp/tonalo.ipk\",\"subscribe\":true}'"
```

**Nicht gerooteter TV im Entwicklermodus:** Das IPK mit dem [webOS Dev Manager](https://github.com/webosbrew/dev-manager-desktop) oder `ares-install` installieren. Im Entwicklermodus muss die Sitzung regelmäßig verlängert werden, sonst entfernt der TV die App.

Danach in der App die Adresse deines Navidrome-Servers eintragen, z. B. `http://192.168.1.10:4533`.

## Fernbedienung
| Taste | Funktion |
|---|---|
| Pfeile / OK | Navigieren / Auswählen |
| Zurück | Zurück; in der obersten Ebene → Seitenleiste → Beenden |
| ▶ / ❚❚ / ■ | Play / Pause / Stopp |
| ⏪ ⏩ | 10 s spulen, gedrückt halten = Song wechseln |
| CH + / – | Seitenweise scrollen |
| Rot / Grün / Gelb / Blau | Läuft gerade / Suchen / Optionen / Play-Pause |

## Entwicklung
Kein Framework und kein Build-Schritt: reines HTML/CSS/JavaScript, kompatibel mit der Chromium-68-Engine von webOS 5 (kein `?.`, `??`, flex-`gap` usw.).

```bash
node tools/mock_server.js app      # Test-Server mit Beispieldaten auf http://localhost:4599
python3 tools/build_ipk.py         # baut dist/*.ipk + Homebrew-Channel-Manifest
node tools/i18n_check.js           # prüft, ob alle Sprachen vollständig sind
```
Im Browser skaliert sich die Oberfläche aufs Fenster; Pfeiltasten, Enter und Esc verhalten sich wie die Fernbedienung.

**Übersetzungen:** Deutsch ist die Ausgangssprache – im Code steht `T('Deutscher Text')`, die Dateien in `app/js/lang/` ordnen jedem deutschen Text die Übersetzung zu. Neue Sprache: Datei kopieren, übersetzen, in `index.html` und `app/js/i18n.js` eintragen.

**Release:** Version in `app/appinfo.json` erhöhen, committen, dann `git tag vX.Y.Z && git push origin vX.Y.Z` – GitHub Actions baut IPK und Manifest und veröffentlicht das Release.

Entwickelt mit Unterstützung von KI (Claude), getestet auf echter Hardware.

## Lizenz
[MIT](LICENSE)
