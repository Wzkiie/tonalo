# Launch-Checkliste

Was vor dem ersten großen Launch erledigt sein sollte, in dieser Reihenfolge. Abhaken, wenn erledigt.

## 1. Auf den eigenen Geräten testen

Neuen Stand aufspielen: iPhone über Xcode, TV mit `python3 tv/tools/build_ipk.py` und `python3 tv/tools/deploy.py <TV-IP>`.

**iPhone**
- [ ] Anmelden mit eigenem Navidrome (mit und ohne Cloudflare-Header)
- [ ] Startseite, Suche, Bibliothek, Album, Künstler, Playlist öffnen
- [ ] Abspielen, Spulen, Überblenden anhören, Sperrbildschirm-Steuerung
- [ ] Qualität: FLAC und Opus im WLAN „Verlustfrei“, Mobilfunk-Stufe, Plakette im Player
- [ ] Downloads im WLAN und über Mobilfunk, abbrechen, löschen
- [ ] Flugmodus: Downloads abspielen, Songtexte, Scrobbles werden später nachgereicht
- [ ] Heim-Adresse: „Zuhause verbunden“, WLAN aus während ein Song läuft → spielt weiter
- [ ] Playlists: anlegen, Song hinzufügen, doppelt hinzufügen, umsortieren, umbenennen, löschen
- [ ] Sleep-Timer (Minuten und „Ende des Songs“), Lautstärke angleichen
- [ ] Herz-Taste im Kontrollzentrum und Siri
- [ ] Apple Watch: Player, Herz, Bibliothek, Lautstärke per Krone
- [ ] Kleines iPhone (oder Simulator iPhone SE) und große Schrift (Bedienungshilfen) ansehen

**TV**
- [ ] Anmelden, Profile wechseln, Fernbedienungstasten
- [ ] Weiterhören: am iPhone pausieren → TV öffnen fragt „Weiterhören vom iPhone?“; umgekehrt Banner am iPhone
- [ ] Bildschirmschoner, App über Nacht offen lassen

**Danach:** Gefundene Fehler beheben, neues TV-Release (Version in `tv/app/appinfo.json` und `tv/app/js/util.js` erhöhen, Tag pushen). Beim ersten Release nach 5dfb870 prüfen, ob der Workflow mit den gepinnten Actions durchläuft.

## 2. Härtetests

- [ ] Große Bibliothek: Startseite, Künstlerliste und eine Playlist mit 1000+ Songs flüssig? (Notfalls Demo-Server: `demo.navidrome.org`, Zugang demo/demo – dort nichts anlegen oder löschen, er wird geteilt)
- [ ] Langsames Netz: iPhone Einstellungen → Entwickler → Network Link Conditioner „3G“ / „Very Bad Network“
- [ ] Server weg (NAS aus): verständliche Meldungen, nichts hängt
- [ ] Anderer Subsonic-Server: z. B. Gonic oder Airsonic-Advanced in Docker kurz aufsetzen und anmelden

## 3. Sicherheit und Datenschutz

- [ ] GitHub: **Settings → Code security → Private vulnerability reporting** einschalten (sonst funktioniert der Link in `SECURITY.md` nicht)
- [ ] Am eigenen TV: Root-Telnet abschalten, SSH nutzen (`deploy.py` dann auf SSH umstellen)
- [ ] `PRIVACY.md` und README-Abschnitt „Security“ passen noch zum Stand?

## 4. Kleine Beta

- [ ] 3–10 Leute aus der Navidrome-Szene fragen (r/navidrome, r/selfhosted, Navidrome-Discussions auf GitHub)
- [ ] TV: ipk aus dem Release; iPhone: TestFlight (braucht das bezahlte Entwicklerkonto, 99 €/Jahr)
- [ ] Eine Woche laufen lassen, Issues sammeln, beheben

## 5. Veröffentlichen

- [ ] **Homebrew Channel:** Antrag im Repo `webosbrew/apps-repo`; verlangt eigenes Icon, Beschreibung, Test auf echtem TV, Hinweis auf KI-Unterstützung (steht im README)
- [ ] **App Store:** Schritte in [`ios/APP_STORE.md`](ios/APP_STORE.md)
- [ ] **CarPlay:** Freigabe bei Apple beantragen, Anleitung in [`ios/CARPLAY.md`](ios/CARPLAY.md)
- [ ] Ankündigung: kurzer Post mit Screenshots (r/navidrome, r/selfhosted, r/webos), Link aufs Repo

## Nach dem Launch

- Issues zeitnah beantworten, Fehlerberichte mit den Vorlagen (Version, Gerät, Server) nachfragen
- Release-Notes auf Englisch
- Keine Analyse oder Absturzberichte einbauen – Feedback kommt über Issues (Privacy by Design)
