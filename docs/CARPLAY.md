# CarPlay

Tonalo hat von Apple die CarPlay-Freigabe für Audio-Apps (`com.apple.developer.carplay-audio`) bekommen. Seit Build 1.1.0 (5) ist CarPlay in den TestFlight- und App-Store-Builds **eingeschaltet** (`ios/Tonalo/CarPlay.swift`).

## Selbst gebaut ohne Freigabe

Die Freigabe gilt nur für das Entwicklerkonto, dem Apple sie erteilt hat. Wer Tonalo mit einem anderen Konto oder einer kostenlosen Apple-ID selbst baut, schaltet sie in `ios/Local.xcconfig` ab, sonst schlägt das Signieren fehl:

```
TONALO_APP_ENTITLEMENTS =
```

CarPlay zeigt die Musik dann trotzdem unter **„Wird gespielt“** an, mit Cover, Titel, Play/Pause und Vor/Zurück – nur ohne eigenes Tonalo-Symbol.

## Was CarPlay zeigt

Tonalo bekommt ein eigenes Symbol in CarPlay mit drei Tabs:

- **Start:** Zufallsmix, Lieblingsmix, „Zuletzt gespielt“ und „Neu hinzugefügt“ als Cover-Reihen, deine Playlists
- **Bibliothek:** Lieblingssongs, Playlists, Alben, Künstler
- **Downloads:** funktioniert auch ohne Netz, zum Beispiel im Funkloch

Im Player gibt es Zufall, Wiederholen und ein **Herz** für die Lieblingssongs. Über „Als Nächstes“ kommst du an die Warteschlange.

Eine Suche gibt es nicht: Apple erlaubt Musik-Apps in CarPlay keine Tastatur.

## Wie die Freigabe eingerichtet wurde

1. CarPlay-Freigabe für Audio-Apps beantragt: https://developer.apple.com/contact/carplay/
2. Nach Apples Zusage unter *Certificates, Identifiers & Profiles → Identifiers → io.github.wzkiie.tonalo* die Fähigkeit „CarPlay Audio App“ eingeschaltet (Xcode kann solche von Apple erteilten Fähigkeiten nicht selbst setzen).
3. Das Target **Tonalo** signiert mit `ios/Tonalo-CarPlay.entitlements` (Einstellung `TONALO_APP_ENTITLEMENTS` in `ios/Signing.xcconfig`). Beim Archivieren mit `-allowProvisioningUpdates` holt Xcode das passende Profil.

## Ohne Auto testen

Der iOS-Simulator prüft die Freigabe nicht. So kann man CarPlay auch ohne Freigabe am Mac ausprobieren:

1. In Xcode einen **Simulator** als Ziel wählen und die App starten (das geht auch ohne Freigabe).
2. Im Simulator-Menü **I/O → External Displays → CarPlay** öffnen.
