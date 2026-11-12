// Tonalo für Windows: ein Fenster mit der TV-Oberfläche (web/), dazu der Dienst fürs iPhone und Updates von GitHub
const { app, BrowserWindow, ipcMain, shell, session, safeStorage, Menu } = require('electron');
const path = require('path'), fs = require('fs'), os = require('os'), Module = require('module'), { pathToFileURL } = require('url');

// tv/service/service.js verlangt webOS' "webos-service" – hier bekommt es den Ersatz
const resolve = Module._resolveFilename;
Module._resolveFilename = function (request, ...rest) {
  return resolve.call(this, request === 'webos-service' ? path.join(__dirname, 'webos-service.js') : request, ...rest);
};

const ZOOM = 0.6;              // die TV-Oberfläche ist für 3 m Abstand gebaut – am Schreibtisch reicht gut die Hälfte
const MAC = process.platform === 'darwin';
let win = null;

// ---------------- Fenster merken (Größe, Position, Zoom)
const stateFile = () => path.join(app.getPath('userData'), 'window.json');
function loadState() { try { return JSON.parse(fs.readFileSync(stateFile(), 'utf8')); } catch (e) { return {}; } }
function saveState() {
  if (!win) return;
  const s = { bounds: win.getNormalBounds(), maximized: win.isMaximized(), zoom: win.webContents.getZoomFactor() };
  try { fs.writeFileSync(stateFile(), JSON.stringify(s)); } catch (e) { /* egal */ }
}

function createWindow() {
  const st = loadState();
  win = new BrowserWindow({
    ...(st.bounds || { width: 1360, height: 860 }),
    minWidth: 980, minHeight: 640,
    title: 'Tonalo',
    backgroundColor: '#000000',
    show: false,
    titleBarStyle: 'hidden',
    ...(MAC ? { trafficLightPosition: { x: 12, y: 8 } } : { titleBarOverlay: { color: '#000000', symbolColor: '#ffffff', height: 34 } }),
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false,
      spellcheck: false,
      backgroundThrottling: false, // Überblenden und Warteschlange laufen über Timer – auch im Hintergrund
      zoomFactor: st.zoom || ZOOM
    }
  });
  if (st.maximized) win.maximize();
  win.once('ready-to-show', () => win.show());

  // Nur die eigene Seite – Links (Hilfe, GitHub) gehen in den Browser
  win.webContents.on('will-navigate', (e) => e.preventDefault());
  win.webContents.on('will-attach-webview', (e) => e.preventDefault());
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https:\/\//.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });

  // Strg + Plus / Minus / 0: Größe der Oberfläche, F11: Vollbild
  win.webContents.on('before-input-event', (e, input) => {
    if (input.type !== 'keyDown') return;
    if (input.key === 'F11') { win.setFullScreen(!win.isFullScreen()); e.preventDefault(); return; }
    if (!(input.control || input.meta)) return;
    const wc = win.webContents, z = wc.getZoomFactor();
    if (input.key === '+' || input.key === '=') wc.setZoomFactor(Math.min(1.2, z * 1.1));
    else if (input.key === '-') wc.setZoomFactor(Math.max(0.4, z / 1.1));
    else if (input.key === '0') wc.setZoomFactor(ZOOM);
    else return;
    e.preventDefault();
  });

  // Seite neu geladen oder abgestürzt: das iPhone sieht sofort, dass hier nichts mehr läuft
  win.webContents.on('did-start-loading', cancelAll);
  win.webContents.on('render-process-gone', cancelAll);
  win.on('close', saveState);
  win.on('closed', () => { win = null; });

  win.loadFile(path.join(__dirname, 'web', 'index.html'));
}

// Nachrichten an den Hauptprozess nimmt nur die eigene Oberfläche an – nie eine fremde Seite oder ein Unterrahmen
const WEB = pathToFileURL(path.join(__dirname, 'web') + path.sep).href;
function fromUs(e) {
  const f = e.senderFrame;
  return !!f && !!win && e.sender === win.webContents && f === e.sender.mainFrame && f.url.startsWith(WEB);
}

// ---------------- Dienst fürs iPhone (tv/service/service.js)
let Service = null;
const subs = new Map(); // offene Abos der Oberfläche: id -> { msg, h }

function startService() {
  Service = require('./webos-service.js');
  require('./service/service.js');
}

ipcMain.on('svc-call', (e, id, uri, params) => {
  if (!fromUs(e)) return;
  const m = /^luna:\/\/([^/]+)\/(.+)$/.exec(uri);
  if (!m) return;
  const reply = (obj) => { if (!e.sender.isDestroyed()) e.sender.send('svc-msg', id, JSON.stringify(obj)); };
  let payload = {};
  try { payload = JSON.parse(params); } catch (err) { return; }
  if (m[1] === 'tonalo.service') {
    const h = Service && Service.handlers[m[2]];
    if (!h) return;
    const msg = { payload, respond: reply, cancel: () => { subs.delete(id); } };
    if (payload.subscribe) subs.set(id, { msg, h });
    h.fn(msg);
  } else if (m[1] === 'com.webos.service.settings') {
    // Der Name, den das iPhone beim Koppeln zeigt – Windows' Standardnamen (DESKTOP-7F3K2Q1) sagen niemandem etwas
    const host = os.hostname().replace(/\.local$/, '');
    reply({ returnValue: true, settings: { deviceName: /^(DESKTOP|LAPTOP)-[A-Z0-9]+$/i.test(host) ? 'PC' : host } });
  }
  // Alles andere (Bildschirmschoner des TVs …) gibt es am PC nicht
});

ipcMain.on('svc-cancel', (e, id) => {
  if (!fromUs(e)) return;
  const s = subs.get(id);
  if (!s) return;
  subs.delete(id);
  if (s.h.cancel) s.h.cancel(s.msg);
});

function cancelAll() {
  const all = [...subs.values()];
  subs.clear();
  all.forEach((s) => { if (s.h.cancel) s.h.cancel(s.msg); });
}

// ---------------- Eigene Header (Cloudflare Access …): siehe headers.js. Die Oberfläche kann Werte setzen, aber nie lesen.
let headers = null;

function setupHeaders() {
  headers = require('./headers.js').create(path.join(app.getPath('userData'), 'headers.bin'), safeStorage);
  session.defaultSession.webRequest.onBeforeSendHeaders({ urls: ['http://*/*', 'https://*/*'] }, (details, cb) => {
    cb({ requestHeaders: headers.apply(details.url, details.requestHeaders) });
  });
}

ipcMain.handle('hdr-names', (e, url) => (fromUs(e) ? headers.names(String(url)) : []));
ipcMain.handle('hdr-try', (e, url, rows) => (fromUs(e) ? headers.attempt(String(url), rows) : { error: 'url' }));
ipcMain.handle('hdr-commit', (e) => { if (fromUs(e)) headers.commit(); });
ipcMain.handle('hdr-discard', (e) => { if (fromUs(e)) headers.discard(); });
ipcMain.handle('hdr-keep', (e, urls) => { if (fromUs(e)) headers.keepOnly(urls); });

// ---------------- Netz: die eigenen IPv4-Adressen mit Maske. Ändert sich, wenn der PC in ein anderes Netz kommt;
// same: ob die gefragte Adresse im selben Netz liegt (null bei Namen, die sich so nicht prüfen lassen).
function netState(host) {
  const num = (ip) => { const p = String(ip).split('.').map(Number); return p.length === 4 && p.every((x) => x >= 0 && x <= 255) ? ((p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]) >>> 0 : null; };
  const own = [];
  Object.values(os.networkInterfaces()).forEach((list) => (list || []).forEach((a) => {
    if (a.internal || a.family !== 'IPv4') return;
    const ip = num(a.address), mask = num(a.netmask);
    if (ip != null && mask) own.push({ ip, mask });
  }));
  const target = num(host);
  return {
    print: own.map((a) => a.ip + '/' + a.mask).sort().join(','),
    same: target == null ? null : own.some((a) => ((a.ip & a.mask) >>> 0) === ((target & a.mask) >>> 0))
  };
}
ipcMain.handle('net-state', (e, host) => (fromUs(e) ? netState(String(host)) : { print: '', same: false }));

// ---------------- DJ: Anbieter, Modell und Schlüssel, die das eigene iPhone übergeben hat. Je Konto, verschlüsselt auf der
// Platte (Windows: DPAPI, macOS: Schlüsselbund). Nur der Dienst im Hauptprozess liest sie – die Oberfläche bekommt den
// Schlüssel nie zu sehen. Ohne Verschlüsselung des Systems wird nichts gespeichert: dann gilt die Übergabe bis zum Beenden.
function setupDJ() {
  const file = path.join(app.getPath('userData'), 'dj.bin');
  let all = {};
  try {
    const data = JSON.parse(safeStorage.decryptString(fs.readFileSync(file)));
    if (data && typeof data === 'object') all = data;
  } catch (e) { /* keine Datei, oder von einem anderen Benutzerkonto: dann übergibt das iPhone sie neu */ }
  global.tonaloDJ = {
    get: (account) => all[String(account)] || null,
    set: (account, cfg) => {
      if (!account) return;
      if (cfg) all[String(account)] = cfg; else delete all[String(account)];
      try {
        if (!Object.keys(all).length) fs.rmSync(file, { force: true });
        else if (safeStorage.isEncryptionAvailable()) fs.writeFileSync(file, safeStorage.encryptString(JSON.stringify(all)), { mode: 0o600 });
      } catch (e) { /* bleibt bis zum Beenden im Speicher */ }
    }
  };
}

// ---------------- Fernbedienung: andere Geräte im Heimnetz (TV, PC) finden, koppeln und steuern (remote.js).
// Die Schlüssel aus den Kopplungen liegen verschlüsselt auf der Platte (wie dj.bin) und nur dieser Prozess liest sie.
let remote = null;
function setupRemote() {
  const file = path.join(app.getPath('userData'), 'remote.bin');
  const host = os.hostname().replace(/\.local$/, '');
  remote = require('./remote.js')(Service, {
    get: () => { try { return JSON.parse(safeStorage.decryptString(fs.readFileSync(file))); } catch (e) { return {}; } },
    set: (all) => {
      try {
        if (!Object.keys(all).some((a) => Object.keys(all[a] || {}).length)) fs.rmSync(file, { force: true });
        else if (safeStorage.isEncryptionAvailable()) fs.writeFileSync(file, safeStorage.encryptString(JSON.stringify(all)), { mode: 0o600 });
      } catch (e) { /* bleibt bis zum Beenden im Speicher */ }
    }
  }, { deviceName: /^(DESKTOP|LAPTOP)-[A-Z0-9]+$/i.test(host) ? 'PC' : host });
}

// ---------------- Updates: neue Releases auf GitHub (latest.yml), geladen und installiert erst auf Wunsch
let status = { state: 'idle' };
let updater = null;

function setStatus(s) {
  status = s;
  if (win && !win.webContents.isDestroyed()) win.webContents.send('upd-status', s);
}

// Das neueste Release hat (noch) keinen Windows-Installer, z. B. ein reines TV-Release: dann gibt es nichts Neues
function noWindowsBuild(err) { return /latest\.yml/.test(String(err && err.message)) && /404/.test(String(err && err.message)); }

function shortError(err) {
  const text = String((err && err.message) || err || '').split('\n')[0].replace(/\s*\(https?:[^)]*\)/g, '');
  return text.length > 140 ? text.slice(0, 137) + '…' : text;
}

function setupUpdater() {
  if (!app.isPackaged) return; // aus dem Quellcode gestartet: nichts zu aktualisieren
  if (MAC) return; // die Mac-App ist nicht notarisiert, macOS erlaubt ihr kein stilles Update: neue Version von Hand laden
  updater = require('electron-updater').autoUpdater;
  updater.autoDownload = false;
  updater.autoInstallOnAppQuit = true;
  updater.on('checking-for-update', () => setStatus({ state: 'checking' }));
  updater.on('update-available', (info) => setStatus({ state: 'available', version: info.version }));
  updater.on('update-not-available', () => setStatus({ state: 'none' }));
  updater.on('download-progress', (p) => setStatus({ state: 'downloading', version: status.version, percent: p.percent }));
  updater.on('update-downloaded', (info) => setStatus({ state: 'ready', version: info.version }));
  updater.on('error', (err) => setStatus(noWindowsBuild(err) ? { state: 'none' } : { state: 'error', version: status.version, error: shortError(err) }));
  setTimeout(check, 5000);
  setInterval(check, 6 * 60 * 60 * 1000);
}

function check() {
  if (!updater) { setStatus({ state: 'none' }); return; }
  if (status.state === 'downloading' || status.state === 'ready') return;
  updater.checkForUpdates().catch((err) => setStatus(noWindowsBuild(err) ? { state: 'none' } : { state: 'error', error: shortError(err) }));
}

ipcMain.on('upd-ready', (e) => { if (fromUs(e)) setStatus(status); });
ipcMain.on('upd-check', (e) => { if (fromUs(e)) check(); });
ipcMain.on('upd-download', (e) => {
  if (fromUs(e) && updater && status.state === 'available') updater.downloadUpdate().catch((err) => setStatus({ state: 'error', error: shortError(err) }));
});
// Still installieren und Tonalo danach wieder starten
ipcMain.on('upd-install', (e) => { if (fromUs(e) && updater && status.state === 'ready') setImmediate(() => updater.quitAndInstall(true, true)); });

// ---------------- Start
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => {
    if (!win) return;
    if (win.isMinimized()) win.restore();
    win.focus();
  });
  app.whenReady().then(() => {
    if (!MAC) Menu.setApplicationMenu(null);
    // Die App braucht keine Kamera, kein Mikrofon, keinen Standort …
    session.defaultSession.setPermissionRequestHandler((_wc, _perm, cb) => cb(false));
    setupHeaders();
    global.tonaloHeaders = (url, h) => headers.apply(url, h); // der Dienst stellt Anfragen an Audiobookshelf mit denselben Headern
    setupDJ();
    startService();
    setupRemote();
    createWindow();
    setupUpdater();
  });
  app.on('window-all-closed', () => app.quit());
}
