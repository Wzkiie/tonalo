# Tonalo for Stream Deck

A plugin for Elgato's Stream Deck (also Stream Deck+) that controls Tonalo on Windows and Mac.

Actions: Now playing / Play-Pause (shows the cover), Favorite (heart fills when the song is a favorite),
DJ, Random mix, Your radio, Shuffle / Smart Shuffle, Next, Previous, and a Volume dial for the Stream Deck+.

## Install

1. In Tonalo, open Settings and switch **Stream-Deck-Plugin zulassen** (Stream Deck plugin) to *On*. It is off by default.
2. Copy the folder `com.tonalo.sdPlugin` into the Stream Deck plugin folder, then restart the Stream Deck app:
   - Windows: `%APPDATA%\Elgato\StreamDeck\Plugins\`
   - Mac: `~/Library/Application Support/com.elgato.StreamDeck/Plugins/`
3. Drag the Tonalo actions onto your keys.

Keys stay grey until Tonalo is running with the switch on.

## How it works

The plugin runs on Node (started by the Stream Deck app) and talks to Tonalo over a local HTTP channel on
`127.0.0.1`. Port and key are read from `streamdeck.json` in Tonalo's data folder. The app side is `desktop/streamdeck.js`;
see the Security section of the main README for what it accepts.

`vendor/ws` is the [ws](https://github.com/websockets/ws) WebSocket library (MIT, version 8), used to talk to the Stream Deck app. Only its `lib/` and `index.js` are included; the e-mail address of an author was dropped from the license file (name and text are unchanged).
