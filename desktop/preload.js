// Die einzige Brücke zwischen Oberfläche und Hauptprozess: Dienst fürs iPhone, Updates, Titelleiste
const { contextBridge, ipcRenderer, webFrame } = require('electron');

const BAR = process.platform === 'darwin' ? 28 : 34; // Höhe der Titelleiste in Bildschirmpunkten

contextBridge.exposeInMainWorld('TonaloNative', {
  platform: process.platform,
  // In CSS-Pixeln, die mit dem Zoom kleiner oder größer werden
  titleBar: () => BAR / webFrame.getZoomFactor(),
  service: {
    call: (id, uri, params) => ipcRenderer.send('svc-call', +id, String(uri), String(params || '{}')),
    cancel: (id) => ipcRenderer.send('svc-cancel', +id),
    onMessage: (fn) => { ipcRenderer.on('svc-msg', (_e, id, msg) => fn(id, msg)); }
  },
  headers: {
    names: (url) => ipcRenderer.invoke('hdr-names', String(url)),
    attempt: (url, rows) => ipcRenderer.invoke('hdr-try', String(url), rows),
    commit: () => ipcRenderer.invoke('hdr-commit'),
    discard: () => ipcRenderer.invoke('hdr-discard'),
    keepOnly: (urls) => ipcRenderer.invoke('hdr-keep', urls)
  },
  // Für die Wahl zwischen Heimadresse und der von außen: woran man das Netz erkennt, und ob eine Adresse darin liegt
  net: { state: (host) => ipcRenderer.invoke('net-state', String(host || '')) },
  // Zustand für Taskleiste und Dock-Menü hinaus, Befehle (prev, toggle, next) von dort herein
  transport: {
    state: (s) => ipcRenderer.send('media-state', { has: !!s.has, playing: !!s.playing, title: String(s.title || ''), artist: String(s.artist || '') }),
    onCommand: (fn) => { ipcRenderer.on('media-cmd', (_e, c) => fn(String(c))); }
  },
  // Stream-Deck-Plugin: Zustand hinaus, Befehle herein, Schalter in den Einstellungen
  streamDeck: {
    state: (s) => ipcRenderer.send('sd-state', s),
    onCommand: (fn) => { ipcRenderer.on('sd-cmd', (_e, c, v) => fn(String(c), +v || 0)); },
    // Bild umwandeln (z. B. WebP in JPEG): fn(bytes, mime) liefert ein Promise mit der Daten-Adresse
    onConvert: (fn) => {
      ipcRenderer.on('sd-conv', (_e, id, bytes, mime) => {
        Promise.resolve(fn(bytes, String(mime))).then((d) => ipcRenderer.send('sd-conv-result', id, String(d || '')), () => ipcRenderer.send('sd-conv-result', id, ''));
      });
    },
    // Plugin im Ordner des Stream Deck: { available, installed, current } und kopieren (true bei Erfolg)
    pluginStatus: () => ipcRenderer.invoke('sd-plugin-status'),
    pluginInstall: () => ipcRenderer.invoke('sd-plugin-install'),
    enabled: () => ipcRenderer.invoke('sd-get'),
    setEnabled: (on) => ipcRenderer.invoke('sd-set', !!on)
  },
  updates: {
    ready: () => ipcRenderer.send('upd-ready'),
    check: () => ipcRenderer.send('upd-check'),
    download: () => ipcRenderer.send('upd-download'),
    install: () => ipcRenderer.send('upd-install'),
    onStatus: (fn) => { ipcRenderer.on('upd-status', (_e, s) => fn(s)); }
  }
});
