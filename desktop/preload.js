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
  updates: {
    ready: () => ipcRenderer.send('upd-ready'),
    check: () => ipcRenderer.send('upd-check'),
    download: () => ipcRenderer.send('upd-download'),
    install: () => ipcRenderer.send('upd-install'),
    onStatus: (fn) => { ipcRenderer.on('upd-status', (_e, s) => fn(s)); }
  }
});
