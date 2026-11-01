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
  updates: {
    ready: () => ipcRenderer.send('upd-ready'),
    check: () => ipcRenderer.send('upd-check'),
    download: () => ipcRenderer.send('upd-download'),
    install: () => ipcRenderer.send('upd-install'),
    onStatus: (fn) => { ipcRenderer.on('upd-status', (_e, s) => fn(s)); }
  }
});
