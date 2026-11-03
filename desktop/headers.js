// Eigene HTTP-Header (Cloudflare Access, Authelia …) je Server. Die Werte bleiben im Hauptprozess: verschlüsselt auf der
// Platte (Windows: DPAPI), und die Oberfläche bekommt nur die Namen zurück. Gesetzt werden sie erst hier beim Absenden –
// so gehen sie auch mit Musik und Covern mit, und nie an eine andere Adresse, auch nicht nach einer Umleitung.
const fs = require('fs'), path = require('path');

const MAX_HEADERS = 10, MAX_NAME = 128, MAX_VALUE = 4096;
const TOKEN = /^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/;
const BAD_VALUE = /[^\t\x20-\x7e\x80-\xff]/;
// Die bestimmt der Browser selbst; falsch gesetzt zerlegen sie die Anfrage
const RESERVED = /^(host|content-length|content-type|transfer-encoding|connection|keep-alive|upgrade|te|trailer|origin|referer|cookie|range)$/i;

// Adressen, die es nur im Heimnetz gibt: nur dorthin darf ein Geheimnis auch ohne https
function isPrivateHost(host) {
  host = String(host || '').toLowerCase();
  if (host.startsWith('[')) return host === '[::1]' || /^\[(f[cd]|fe[89ab])/.test(host);
  if (host === 'localhost' || host.indexOf('.') < 0) return true;
  if (/\.(local|lan|home|home\.arpa|internal|fritz\.box|localhost)$/.test(host)) return true;
  const p = host.split('.').map(Number);
  if (p.length !== 4 || p.some(isNaN)) return false;
  return p[0] === 10 || p[0] === 127 || (p[0] === 192 && p[1] === 168) || (p[0] === 172 && p[1] >= 16 && p[1] <= 31) ||
    (p[0] === 169 && p[1] === 254) || (p[0] === 100 && p[1] >= 64 && p[1] <= 127);
}

function parse(url) {
  try {
    const u = new URL(url);
    return /^https?:$/.test(u.protocol) ? u : null;
  } catch (e) { return null; }
}

function originOf(url) {
  const u = parse(url);
  return u ? u.origin : null;
}

function allowed(url) {
  const u = parse(url);
  return !!u && (u.protocol === 'https:' || isPrivateHost(u.hostname));
}

// file: wo es liegt, crypto: Electrons safeStorage
function create(file, crypto) {
  let store = load();
  let pending = null; // { origin, headers } – wird nur für den Anmeldeversuch benutzt, gespeichert erst, wenn er klappt

  function load() {
    try {
      const data = JSON.parse(crypto.decryptString(fs.readFileSync(file)));
      return data && typeof data === 'object' ? data : {};
    } catch (e) { return {}; } // keine Datei, oder von einem anderen Windows-Konto: dann muss man sie neu eintragen
  }

  function persist() {
    if (!Object.keys(store).length) { fs.rmSync(file, { force: true }); return; }
    fs.mkdirSync(path.dirname(file), { recursive: true });
    const tmp = file + '.tmp';
    fs.writeFileSync(tmp, crypto.encryptString(JSON.stringify(store)), { mode: 0o600 });
    fs.renameSync(tmp, file);
  }

  function names(url) {
    return (store[originOf(url)] || []).map((h) => h.name);
  }

  // Prüft die Eingabe und benutzt sie ab jetzt für diesen Server. Ein leerer Wert behält den gespeicherten.
  function attempt(url, rows) {
    pending = null;
    const origin = originOf(url);
    if (!origin) return { error: 'url' };
    const old = store[origin] || [], headers = [], seen = new Set();
    for (const row of Array.isArray(rows) ? rows : []) {
      const name = String((row && row.name) || '').trim();
      let value = String((row && row.value) || '').trim();
      if (!name) { if (value) return { error: 'name', name: '' }; continue; }
      if (name.length > MAX_NAME || !TOKEN.test(name) || RESERVED.test(name) || seen.has(name.toLowerCase())) return { error: 'name', name };
      if (!value) {
        const kept = old.find((h) => h.name.toLowerCase() === name.toLowerCase());
        if (!kept) return { error: 'empty', name };
        value = kept.value;
      }
      if (value.length > MAX_VALUE || BAD_VALUE.test(value)) return { error: 'value', name };
      seen.add(name.toLowerCase());
      headers.push({ name, value });
    }
    if (headers.length > MAX_HEADERS) return { error: 'many' };
    if (headers.length && !allowed(url)) return { error: 'https' };
    if (headers.length && !crypto.isEncryptionAvailable()) return { error: 'crypto' };
    pending = { origin, headers };
    return {};
  }

  function commit() {
    if (!pending) return;
    if (pending.headers.length) store[pending.origin] = pending.headers;
    else delete store[pending.origin];
    pending = null;
    persist();
  }

  function discard() { pending = null; }

  // Nur noch Server behalten, zu denen es ein Konto gibt
  function keepOnly(urls) {
    const keep = new Set((Array.isArray(urls) ? urls : []).map(originOf));
    let changed = false;
    Object.keys(store).forEach((origin) => { if (!keep.has(origin)) { delete store[origin]; changed = true; } });
    if (changed) persist();
  }

  // Der einzige Weg nach draußen: exakt derselbe Server (Schema, Host, Port) und eine erlaubte Verbindung
  function apply(url, requestHeaders) {
    const origin = originOf(url);
    if (!origin || !allowed(url)) return requestHeaders;
    const list = pending && pending.origin === origin ? pending.headers : store[origin];
    (list || []).forEach((h) => { requestHeaders[h.name] = h.value; });
    return requestHeaders;
  }

  return { names, attempt, commit, discard, keepOnly, apply };
}

module.exports = { create, isPrivateHost };
