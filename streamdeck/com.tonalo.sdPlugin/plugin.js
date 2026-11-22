// Tonalo für das Stream Deck. Spricht mit Elgatos Programm (WebSocket) und mit Tonalo auf diesem PC (lokale Schnittstelle,
// 127.0.0.1, Schlüssel aus streamdeck.json). Tonalo muss dafür in den Einstellungen "Stream-Deck-Plugin zulassen" an haben.
const fs = require('fs'), os = require('os'), path = require('path'), http = require('http');
const WebSocket = require('./vendor/ws');

// ---- Start durch Stream Deck: -port N -pluginUUID X -registerEvent Y -info {...}
const arg = (n) => { const i = process.argv.indexOf('-' + n); return i > 0 ? process.argv[i + 1] : ''; };
const sdPort = arg('port'), sdUUID = arg('pluginUUID'), sdRegister = arg('registerEvent');

// ---- Tonalo
function cfgFile() {
  if (process.platform === 'darwin') return path.join(os.homedir(), 'Library', 'Application Support', 'Tonalo', 'streamdeck.json');
  return path.join(process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'), 'Tonalo', 'streamdeck.json');
}
function cfg() {
  try {
    const c = JSON.parse(fs.readFileSync(cfgFile(), 'utf8'));
    return c.enabled && c.port && c.token ? c : null;
  } catch (_) { return null; }
}

let state = null;        // null = keine Verbindung zu Tonalo
let req = null;
let retry = null;

function connect() {
  clearTimeout(retry);
  const c = cfg();
  if (!c) return later();
  req = http.get({ host: '127.0.0.1', port: c.port, path: '/events', headers: { Authorization: 'Bearer ' + c.token } }, (res) => {
    if (res.statusCode !== 200) { res.resume(); return lost(); }
    let buf = '';
    res.setEncoding('utf8');
    res.on('data', (d) => {
      buf += d;
      let i;
      while ((i = buf.indexOf('\n\n')) >= 0) {
        const block = buf.slice(0, i); buf = buf.slice(i + 2);
        if (block.startsWith('data: ')) { try { state = JSON.parse(block.slice(6)); renderAll(); } catch (_) { /* ignorieren */ } }
      }
    });
    res.on('end', lost);
    res.on('error', lost);
  });
  req.on('error', lost);
}
function lost() { state = null; renderAll(); later(); }
function later() { clearTimeout(retry); retry = setTimeout(connect, 3000); }

function send(cmd, value) {
  const c = cfg();
  if (!c) return;
  const body = JSON.stringify({ cmd, value });
  const r = http.request({ host: '127.0.0.1', port: c.port, path: '/cmd', method: 'POST', headers: { Authorization: 'Bearer ' + c.token, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } }, (res) => res.resume());
  r.on('error', () => { /* Tonalo läuft nicht: Taste bleibt grau */ });
  r.end(body);
}

// ---- Bilder (SVG, 144 x 144)
const ICON = {
  play: 'M8 5v14l11-7z',
  pause: 'M6 5h4v14H6zM14 5h4v14h-4z',
  next: 'M6 18l8.5-6L6 6v12zM16 6v12h2V6h-2z',
  prev: 'M6 6h2v12H6zM9.5 12l8.5 6V6z',
  heart: 'M16.5 3c-1.74 0-3.41.81-4.5 2.09C10.91 3.81 9.24 3 7.5 3 4.42 3 2 5.42 2 8.5c0 3.78 3.4 6.86 8.55 11.54L12 21.35l1.45-1.32C18.6 15.36 22 12.28 22 8.5 22 5.42 19.58 3 16.5 3z',
  shuffle: 'M10.59 9.17L5.41 4 4 5.41l5.17 5.17 1.42-1.41zM14.5 4l2.04 2.04L4 18.59 5.41 20 17.96 7.46 20 9.5V4h-5.5zm.33 9.41l-1.41 1.41 3.13 3.13L14.5 20H20v-5.5l-2.04 2.04-3.13-3.13z'
};
function svg(inner, bg) {
  const s = '<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" viewBox="0 0 144 144"><rect width="144" height="144" rx="14" fill="' + bg + '"/>' + inner + '</svg>';
  return 'data:image/svg+xml;charset=utf8,' + encodeURIComponent(s);
}
function glyph(name, color, label) {
  return '<g transform="translate(36 28) scale(3)" fill="' + color + '"><path d="' + ICON[name] + '"/></g>' + (label ? '<text x="72" y="130" font-family="Arial" font-size="18" font-weight="700" fill="' + color + '" text-anchor="middle">' + label + '</text>' : '');
}
const OFF = svg('<text x="72" y="82" font-family="Arial" font-size="20" fill="#6b7280" text-anchor="middle">Tonalo</text>', '#111827');
const BG = '#1f2937', ON = '#2563eb', WHITE = '#ffffff', DIM = '#9ca3af';

// Was jede Taste zeigt und tut
const ACTIONS = {
  'com.tonalo.nowplaying': { press: 'toggle', image: (s) => s.cover || svg(glyph(s.playing ? 'pause' : 'play', WHITE), BG), title: (s) => s.title },
  'com.tonalo.favorite': { press: 'favorite', image: (s) => svg('<g transform="translate(36 28) scale(3)"><path d="' + ICON.heart + '" fill="' + (s.starred ? '#ef4444' : 'none') + '" stroke="' + (s.starred ? '#ef4444' : WHITE) + '" stroke-width="1.6"/></g>', BG) },
  'com.tonalo.dj': { press: 'dj', image: (s) => svg('<text x="72" y="92" font-family="Arial" font-size="56" font-weight="800" fill="' + WHITE + '" text-anchor="middle">DJ</text>', s.dj ? ON : BG) },
  'com.tonalo.mix': { press: 'mix', image: () => svg(glyph('shuffle', WHITE, 'Mix'), BG) },
  'com.tonalo.radio': { press: 'radio', image: () => svg(glyph('heart', WHITE, 'Radio'), BG) },
  'com.tonalo.shuffle': { press: 'shuffle', image: (s) => svg(glyph('shuffle', WHITE, s.smart ? 'Smart' : ''), s.shuffle ? ON : BG) },
  'com.tonalo.next': { press: 'next', image: () => svg(glyph('next', WHITE), BG) },
  'com.tonalo.prev': { press: 'prev', image: () => svg(glyph('prev', WHITE), BG) },
  'com.tonalo.volume': { press: 'toggle', dial: true }
};

// ---- Stream Deck
const ctxs = new Map(); // context -> { action, encoder }
let ws = null;
const out = (o) => { if (ws && ws.readyState === 1) ws.send(JSON.stringify(o)); };

function render(context) {
  const c = ctxs.get(context), a = c && ACTIONS[c.action];
  if (!a) return;
  if (a.dial) {
    const pct = state ? Math.round(state.volume * 100) : 0;
    out({ event: 'setFeedback', context, payload: { title: state ? 'Tonalo' : 'Tonalo (aus)', value: state ? pct + ' %' : '-', indicator: { value: pct } } });
    return;
  }
  out({ event: 'setImage', context, payload: { image: state ? a.image(state) : OFF, target: 0 } });
  out({ event: 'setTitle', context, payload: { title: state && a.title ? a.title(state) : '', target: 0 } });
}
function renderAll() { for (const k of ctxs.keys()) render(k); }

if (sdPort) {
  ws = new WebSocket('ws://127.0.0.1:' + sdPort);
  ws.on('open', () => { out({ event: sdRegister, uuid: sdUUID }); connect(); });
  ws.on('close', () => process.exit(0));
  ws.on('error', () => process.exit(1));
  ws.on('message', (raw) => {
    let m; try { m = JSON.parse(raw); } catch (_) { return; }
    const a = ACTIONS[m.action];
    switch (m.event) {
      case 'willAppear': ctxs.set(m.context, { action: m.action }); render(m.context); break;
      case 'willDisappear': ctxs.delete(m.context); break;
      case 'keyDown': case 'dialDown': case 'touchTap': if (a && a.press) send(a.press); break;
      case 'dialRotate': if (a && a.dial && m.payload && m.payload.ticks) for (let i = Math.min(Math.abs(m.payload.ticks), 5); i > 0; i--) send(m.payload.ticks > 0 ? 'volumeUp' : 'volumeDown'); break;
    }
  });
}

module.exports = { ACTIONS, svg };
