# CarPlay

Der CarPlay-Teil ist fertig programmiert (`ios/Tonalo/CarPlay.swift`), aber noch **ausgeschaltet**. iOS zeigt eine Musik-App in CarPlay nur an, wenn Apple sie dafür freigegeben hat.

## Was schon ohne Freigabe geht

Läuft Musik in Tonalo, zeigt CarPlay sie unter **„Wird gespielt“** an, mit Cover, Titel, Play/Pause und Vor/Zurück. Dafür ist nichts weiter nötig.

## Was die Freigabe dazu bringt

Tonalo bekommt ein eigenes Symbol in CarPlay mit drei Tabs:

- **Start:** Zufallsmix, Lieblingsmix, „Zuletzt gespielt“ und „Neu hinzugefügt“ als Cover-Reihen, deine Playlists
- **Bibliothek:** Lieblingssongs, Playlists, Alben, Künstler
- **Downloads:** funktioniert auch ohne Netz, zum Beispiel im Funkloch

Im Player gibt es Zufall, Wiederholen und ein **Herz** für die Lieblingssongs. Über „Als Nächstes“ kommst du an die Warteschlange.

Eine Suche gibt es nicht: Apple erlaubt Musik-Apps in CarPlay keine Tastatur.

## Freischalten

1. Kostenpflichtiges Apple-Entwicklerkonto (99 €/Jahr). Mit der kostenlosen Apple-ID geht es nicht.
2. Die CarPlay-Freigabe für Audio-Apps bei Apple beantragen: https://developer.apple.com/contact/carplay/
   Apple meldet sich per Mail, das kann ein paar Tage bis Wochen dauern.
3. Nach der Zusage: In Xcode beim Target **Tonalo** unter *Build Settings → Code Signing Entitlements* die Datei `ios/Tonalo-CarPlay.entitlements` eintragen. Die liegt schon im Ordner `ios/` und enthält den Schlüssel `com.apple.developer.carplay-audio`.
4. Neu aufs iPhone spielen. Tonalo erscheint dann in CarPlay.

## Ohne Auto testen

Der iOS-Simulator prüft die Freigabe nicht. So kann man CarPlay auch ohne Freigabe am Mac ausprobieren:

1. In Xcode beim Target **Tonalo** unter *Code Signing Entitlements* vorübergehend `ios/Tonalo-CarPlay.entitlements` eintragen und einen **Simulator** als Ziel wählen.
2. App starten, dann im Simulator-Menü **I/O → External Displays → CarPlay**.
3. Danach den Eintrag wieder entfernen, sonst klappt das Aufspielen aufs echte iPhone nicht.
