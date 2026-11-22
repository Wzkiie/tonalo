// Lokale Schnittstelle fürs Stream-Deck-Plugin (streamdeck/). Standardmäßig aus, in den Einstellungen einschaltbar.
// Sie lauscht nur auf 127.0.0.1, verlangt einen Schlüssel und weist Anfragen aus Browsern ab (kein Origin-Header,
// Host muss stimmen). Das Plugin liest Port und Schlüssel aus streamdeck.json im Datenordner dieses Benutzers.
const http = require('http'), crypto = require('crypto'), fs = require('fs'), path = require('path');
const { app, net } = require('electron');

const CMDS = new Set(['toggle', 'play', 'pause', 'next', 'prev', 'favorite', 'mix', 'radio', 'dj', 'shuffle', 'volumeUp', 'volumeDown', 'volume']);
const KINDS = new Set(['none', 'song', 'station', 'book']);
const MAX_COVER = 2 * 1024 * 1024;

function setupStreamDeck(getWin, fromUs, ipcMain) {
  const file = path.join(app.getPath('userData'), 'streamdeck.json');
  let cfg = { enabled: false, token: '', port: 0 };
  let server = null;
  const clients = new Set();
  let state = { kind: 'none', playing: false, title: '', artist: '', album: '', starred: false, shuffle: false, smart: false, volume: 1, dj: false, cover: '' };
  let coverUrl = '', coverSeq = 0;

  try { Object.assign(cfg, JSON.parse(fs.readFileSync(file, 'utf8'))); } catch (_) { /* erster Start */ }
  cfg.enabled = cfg.enabled === true;
  if (typeof cfg.token !== 'string' || cfg.token.length < 32) cfg.token = crypto.randomBytes(32).toString('hex');
  function save() { try { fs.writeFileSync(file, JSON.stringify(cfg), { mode: 0o600 }); } catch (_) { /* Plugin findet dann nichts und bleibt grau */ } }

  function publicState() { return JSON.stringify(state); }
  function broadcast() {
    const data = 'data: ' + publicState() + '\n\n';
    for (const res of clients) res.write(data);
  }

  function ok(req) {
    if (req.headers.origin) return false; // Browser-Anfragen (auch fremde Seiten) nie
    if (req.headers.host !== '127.0.0.1:' + cfg.port) return false; // gegen DNS-Rebinding
    const m = /^Bearer (.+)$/.exec(req.headers.authorization || '');
    if (!m) return false;
    const a = Buffer.from(m[1]), b = Buffer.from(cfg.token);
    return a.length === b.length && crypto.timingSafeEqual(a, b);
  }

  function handle(req, res) {
    if (!ok(req)) { res.writeHead(403); res.end(); return; }
    if (req.method === 'GET' && req.url === '/events') {
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store', Connection: 'keep-alive' });
      res.write('data: ' + publicState() + '\n\n');
      clients.add(res);
      const ka = setInterval(() => res.write(': ka\n\n'), 20000);
      req.on('close', () => { clearInterval(ka); clients.delete(res); });
      return;
    }
    if (req.method === 'POST' && req.url === '/cmd') {
      let body = '';
      req.on('data', (c) => { body += c; if (body.length > 1024) req.destroy(); });
      req.on('end', () => {
        let j = null;
        try { j = JSON.parse(body); } catch (_) { /* fällt unten raus */ }
        const w = getWin();
        if (!j || !CMDS.has(j.cmd) || !w || w.isDestroyed()) { res.writeHead(400); res.end(); return; }
        const value = j.cmd === 'volume' ? Math.max(0, Math.min(1, Number(j.value) || 0)) : 0;
        w.webContents.send('sd-cmd', j.cmd, value);
        res.writeHead(204); res.end();
      });
      return;
    }
    res.writeHead(404); res.end();
  }

  function start() {
    if (server) return Promise.resolve();
    return new Promise((resolve) => {
      const s = http.createServer(handle);
      s.on('error', () => { server = null; resolve(); });
      s.listen(0, '127.0.0.1', () => {
        server = s;
        cfg.port = s.address().port;
        save();
        resolve();
      });
    });
  }

  function stop() {
    for (const res of clients) res.end();
    clients.clear();
    if (server) { server.close(); server = null; }
    cfg.port = 0;
    save();
  }

  // Umwandeln übernimmt die Oberfläche (Chromium kann WebP): Bytes hin, kleines JPEG zurück
  const waiting = new Map();
  let convSeq = 0;
  function convert(buf, mime) {
    const w = getWin();
    if (!w || w.isDestroyed()) return Promise.resolve('');
    return new Promise((resolve) => {
      const id = ++convSeq;
      const t = setTimeout(() => { waiting.delete(id); resolve(''); }, 5000);
      waiting.set(id, (d) => { clearTimeout(t); resolve(d); });
      w.webContents.send('sd-conv', id, buf, mime);
    });
  }
  ipcMain.on('sd-conv-result', (e, id, d) => {
    if (!fromUs(e)) return;
    const cb = waiting.get(id);
    if (!cb) return;
    waiting.delete(id);
    cb(typeof d === 'string' && d.startsWith('data:image/jpeg;base64,') && d.length <= MAX_COVER * 1.4 ? d : '');
  });

  // Cover holt der Hauptprozess selbst (mit denselben Headern wie die App) und gibt es nur als kleines Bild weiter,
  // nie die Adresse – sie enthält die Zugangsdaten für den Server
  async function loadCover(url) {
    const seq = ++coverSeq;
    let data = '';
    try {
      if (/^https?:\/\//i.test(url)) {
        const r = await net.fetch(url);
        const type = r.headers.get('content-type') || '';
        if (r.ok && /^image\//.test(type)) {
          const buf = Buffer.from(await r.arrayBuffer());
          const mime = type.split(';')[0];
          if (buf.length <= MAX_COVER) {
            if (mime === 'image/jpeg' || mime === 'image/png') data = 'data:' + mime + ';base64,' + buf.toString('base64');
            else data = await convert(buf, mime); // z. B. WebP: das Stream Deck zeigt nur JPEG/PNG sicher an
          }
        }
      }
    } catch (_) { /* ohne Cover geht es auch */ }
    if (seq !== coverSeq) return;
    state.cover = data;
    if (clients.size) broadcast();
  }

  ipcMain.on('sd-state', (e, s) => {
    if (!fromUs(e) || !s || typeof s !== 'object') return;
    const str = (v) => String(v || '').slice(0, 200);
    const next = {
      kind: KINDS.has(s.kind) ? s.kind : 'none',
      playing: s.playing === true,
      title: str(s.title), artist: str(s.artist), album: str(s.album),
      starred: s.starred === true,
      shuffle: s.shuffle === true,
      smart: s.smart === true,
      volume: Math.max(0, Math.min(1, Number(s.volume) || 0)),
      dj: s.dj === true,
      cover: state.cover
    };
    const url = typeof s.coverUrl === 'string' ? s.coverUrl.slice(0, 2000) : '';
    if (url !== coverUrl) { coverUrl = url; if (url) loadCover(url); else { coverSeq++; next.cover = ''; } }
    const same = JSON.stringify(next) === JSON.stringify(state);
    state = next;
    if (!same && clients.size) broadcast();
  });

  ipcMain.handle('sd-get', (e) => (fromUs(e) ? cfg.enabled : false));
  ipcMain.handle('sd-set', async (e, on) => {
    if (!fromUs(e)) return false;
    cfg.enabled = on === true;
    if (cfg.enabled) await start(); else stop();
    save();
    return cfg.enabled;
  });

  if (cfg.enabled) start(); else { cfg.port = 0; save(); }
  app.on('before-quit', () => { if (server) { cfg.port = 0; save(); } });
}

module.exports = { setupStreamDeck };
