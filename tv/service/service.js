/* Hintergrunddienst: Das iPhone sieht im Heimnetz, was der TV spielt, und kann dort Musik starten.
   Nur gekoppelte Geräte (einmal Code vom TV eingeben) dürfen etwas sehen oder schicken.
   Die TV-App meldet ihren Stand hierher und bekommt die Befehle über ein Abo (attach). */
var Service = require('webos-service');
var http = require('http');
var crypto = require('crypto');
var dgram = require('dgram');
var os = require('os');

var NAME = require('./package.json').name;
var PORT = 47913;
var service = new Service(NAME);

var app = null;        // Abo der TV-App – darüber gehen Befehle und Kopplungscodes raus
var tv = { id: '', name: 'TV', kind: 'tv', keys: [], others: [], account: '' }; // keys: [{ id, device, key }], gespeichert macht sie die App
                                                        // others: die iPhones der anderen Konten – hier nur Gäste
var state = { active: false };
var clients = [];      // offene Live-Verbindungen der iPhones: { res, entry }
var pairing = null;    // { code, until, tries, guest }
var failures = 0, lockedUntil = 0, lockouts = 0; // falsche Codes über alle Kopplungen – nach 15 Fehlern ist Pause, jedes Mal doppelt so lang
var lastStart = 0;     // wann zuletzt ein Code verlangt wurde – niemand im WLAN soll den Bildschirm mit Codes zuschütten
var nonces = {};       // schon benutzte Anfragen: eine mitgeschnittene Anfrage geht kein zweites Mal durch
var server = null;

function send(msg) { if (app) app.respond(Object.assign({ returnValue: true }, msg)); }

// ---------- TV-App
service.register('attach', function (msg) {
  var p = msg.payload || {};
  tv.id = String(p.id || tv.id);
  tv.name = String(p.name || tv.name);
  tv.kind = p.kind === 'pc' ? 'pc' : 'tv'; // die Windows-App: das iPhone zeigt dann einen Computer statt eines TVs
  tv.keys = Array.isArray(p.keys) ? p.keys : [];
  tv.others = Array.isArray(p.others) ? p.others : [];
  tv.account = String(p.account || '').slice(0, 80);
  // Am PC liegt die DJ-Einrichtung verschlüsselt im Hauptprozess, am TV hält sie die App (wie die Kopplungsschlüssel)
  djCfg = djStore() ? djStore().get(tv.account) : djClean(p.dj);
  // Getrennte Geräte sehen ab sofort nichts mehr, auch nicht über eine schon offene Verbindung – und wer mit dem
  // Kontowechsel nur noch Gast ist (oder wieder mehr), verbindet sich neu und bekommt seine neue Rolle
  var gone = clients.filter(function (c) { var k = keyFor(c.entry.id); return !k || !!k.guest !== !!c.entry.guest; });
  // Sofort aus der Liste, nicht erst wenn die Verbindung zu ist – sonst schreibt der nächste Stand noch hinein
  clients = clients.filter(function (c) { return gone.indexOf(c) < 0; });
  gone.forEach(function (c) { c.res.end(); });
  if (app && app !== msg) { try { app.cancel(); } catch (e) { /* schon weg */ } }
  app = msg;
  wantNet = true;
  startServer();
  startMdns();
  msg.respond({ returnValue: true, port: PORT, djInfo: djPublic() });
  report();
}, function (msg) {
  // App geschlossen: es läuft nichts mehr, das iPhone spielt wieder selbst
  if (app !== msg) return;
  app = null;
  setState({ active: false });
});

// Am PC abschaltbar („Im Netzwerk sichtbar: Aus“, z. B. im Hotel-WLAN): niemand findet ihn, niemand erreicht ihn
service.register('stop', function (msg) {
  if (app) { try { app.cancel(); } catch (e) { /* schon weg */ } app = null; }
  clients.forEach(function (c) { c.res.end(); });
  clients = [];
  pairing = null;
  if (server) { server.close(); server = null; }
  wantNet = false;
  clearTimeout(netRetry);
  // „Ich bin weg“ (TTL 0): iPhones im Netz nehmen den Eintrag sofort aus der Liste, statt bis zu 2 Minuten zu warten
  if (mdns) { try { announce(null, null, 0); announce(null, null, 0); } catch (e) { /* egal */ } var m = mdns; setTimeout(function () { try { m.close(); } catch (e) { /* egal */ } }, 100); mdns = null; }
  clearInterval(announcer);
  msg.respond({ returnValue: true });
});

service.register('state', function (msg) {
  setState((msg.payload && msg.payload.state) || { active: false });
  msg.respond({ returnValue: true });
});

function setState(s) {
  state = s;
  broadcast();
}

// Gäste der Jukebox sehen nicht, wessen Konto das ist – nur was läuft und wer gerade mit dabei ist
function line(guest) {
  var s = Object.assign({}, state, { guests: guestNames() });
  if (guest) { delete s.user; delete s.book; delete s.abs; s.jukebox = true; } // so weiß ein iPhone, dass es hier nur Gast sein kann
  s.sent = Date.now(); // mit „at“ zusammen rechnet das iPhone die Position aus, ohne dass beide Uhren stimmen müssen
  return 'data: ' + JSON.stringify(s) + '\n\n';
}

function broadcast() {
  var forHost = line(false), forGuest = line(true);
  clients.forEach(function (c) {
    // Ein Gerät, das nichts mehr annimmt (Verbindung tot, aber noch nicht erkannt), staut Daten auf: dann trennen
    if (c.res.writableLength > 1000000) { try { c.res.destroy(); } catch (e) { /* egal */ } return; }
    c.res.write(c.entry.guest ? forGuest : forHost);
  });
}

// ---------- Anfragen der App an Audiobookshelf. Aus der Oberfläche geht das nicht (der Server erlaubt fremde Web-Apps nicht),
// also stellt der Dienst sie. Keine Weiterleitungen (die Anmeldung geht nie an einen anderen Server), nur http(s), begrenzte Größe.
var https = require('https');
var URL_ = require('url').URL;
var HTTP_MAX = 12 * 1024 * 1024;
var HTTP_MAX_SLIM = 48 * 1024 * 1024; // nur mit "slim": die Antwort wird hier verkleinert, bevor sie zur App geht

// Audiobookshelf liefert bei Suche und Serien jedes Buch mit allen Dateien und Kapiteln, eine Serie mit hunderten Folgen sind
// dann Dutzende MB. Die Übersicht braucht davon nur Titel, Autor und das erste Buch einer Serie fürs Cover.
function slimItem(o) {
  var m = (o.media && o.media.metadata) || {}, e = o.recentEpisode;
  return {
    id: o.id, libraryId: o.libraryId, mediaType: o.mediaType, addedAt: o.addedAt,
    recentEpisode: e ? { id: e.id, title: e.title, subtitle: e.subtitle, season: e.season, episode: e.episode, publishedAt: e.publishedAt, duration: e.duration, audioFile: e.audioFile && { duration: e.audioFile.duration } } : undefined,
    media: { duration: o.media && o.media.duration, numEpisodes: o.media && o.media.numEpisodes,
      metadata: { title: m.title, subtitle: m.subtitle, authorName: m.authorName, narratorName: m.narratorName, seriesName: m.seriesName } }
  };
}
function slimWalk(v, depth) {
  if (!v || typeof v !== 'object' || depth > 6) return v;
  if (Array.isArray(v)) return v.map(function (x) { return slimWalk(x, depth + 1); });
  if (v.mediaType && v.media) return slimItem(v);
  var out = {};
  Object.keys(v).forEach(function (k) { out[k] = slimWalk(v[k], depth + 1); });
  if (Array.isArray(out.books) && out.books.length > 1) { out.numBooks = out.books.length; out.books = out.books.slice(0, 1); }
  return out;
}
service.register('http', function (msg) {
  var p = msg.payload || {}, u;
  function fail(text) { msg.respond({ returnValue: false, errorText: text }); }
  try { u = new URL_(String(p.url)); } catch (e) { return fail('url'); }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return fail('url');
  var method = ['GET', 'POST', 'PATCH', 'DELETE'].indexOf(p.method) >= 0 ? p.method : 'GET';
  var headers = {};
  if (p.headers && typeof p.headers === 'object') {
    Object.keys(p.headers).slice(0, 30).forEach(function (k) { if (typeof p.headers[k] === 'string') headers[k] = p.headers[k].slice(0, 4096); });
  }
  // Der PC ergänzt hier seine eigenen Header (Cloudflare Access …), die die Oberfläche nie zu sehen bekommt
  if (global.tonaloHeaders) { try { headers = global.tonaloHeaders(u.href, headers); } catch (e) { /* ohne */ } }
  var body = typeof p.body === 'string' ? Buffer.from(p.body, 'utf8') : null;
  if (body) headers['Content-Length'] = body.length;
  headers['User-Agent'] = 'Tonalo';
  var done = false;
  var req;
  try {
  req = (u.protocol === 'https:' ? https : http).request({
    hostname: u.hostname.replace(/^\[|\]$/g, ''), port: u.port || undefined, path: u.pathname + u.search, method: method, headers: headers
  }, function (res) {
    var chunks = [], size = 0;
    res.on('data', function (c) {
      size += c.length;
      if (size > (p.slim ? HTTP_MAX_SLIM : HTTP_MAX)) { if (!done) { done = true; fail('size'); } req.abort(); return; }
      chunks.push(c);
    });
    res.on('end', function () {
      if (done) return;
      done = true;
      var buf = Buffer.concat(chunks), text = p.binary ? buf.toString('base64') : buf.toString('utf8');
      if (p.slim && !p.binary) {
        try { text = JSON.stringify(slimWalk(JSON.parse(text), 0)); } catch (e) { /* kein JSON: unverändert */ }
        if (text.length > HTTP_MAX) return fail('size');
      }
      msg.respond({ returnValue: true, status: res.statusCode, type: String(res.headers['content-type'] || ''), body: text });
    });
    res.on('error', function () { if (!done) { done = true; fail('read'); } });
  });
  } catch (e) { return fail('header'); } // z. B. ein Header-Wert mit Zeilenumbruch: Node wirft sofort
  req.setTimeout(Math.min(+p.timeout || 20000, 60000), function () { if (!done) { done = true; fail('timeout'); } req.abort(); });
  req.on('error', function (e) { if (!done) { done = true; fail(e && e.code ? String(e.code) : 'network'); } });
  if (body) req.write(body);
  req.end();
});

// Der App sagen, welche iPhones gerade verbunden sind – die Windows-App zeigt das unten an
function report() {
  var seen = {};
  send({ connected: clients.filter(function (c) {
    var k = c.entry.id;
    return seen[k] ? false : (seen[k] = true);
  }).map(function (c) { return { device: c.entry.device, guest: !!c.entry.guest }; }) });
}

function guestNames() {
  var names = [];
  clients.forEach(function (c) { if (c.entry.guest && names.indexOf(c.entry.device) < 0) names.push(c.entry.device); });
  return names;
}

// Was Gäste dürfen: Songs hinzufügen (höchstens 20 auf einmal) und überspringen
var GUEST = ['enqueue', 'playNext', 'next'];
var GUEST_SONGS = 20;

// Von einem Gast kommt nur, was ein Song braucht: einfache Werte, kurz gehalten – keine Sender-Adressen, keine Objekte
function guestSong(s) {
  var out = {};
  if (!s || typeof s !== 'object') return null;
  Object.keys(s).slice(0, 40).forEach(function (k) {
    var v = s[k];
    if (k === 'streamUrl' || k === 'url') return;
    if (typeof v === 'string') out[k] = v.slice(0, 300);
    else if ((typeof v === 'number' && isFinite(v)) || typeof v === 'boolean') out[k] = v;
  });
  return typeof out.id === 'string' && out.id ? out : null;
}

// Ein iPhone, das mit einem anderen Konto auf diesem TV gekoppelt ist, kommt als Gast der Jukebox herein
function keyFor(id) {
  var own = tv.keys.filter(function (k) { return k.id === id; })[0];
  if (own) return own;
  var other = tv.others.filter(function (k) { return k.id === id; })[0];
  return other && Object.assign({}, other, { guest: true });
}

// ---------- Anmeldung der iPhones: HMAC über Methode, Pfad, Zeit, Einmalwert und Inhalt mit dem Schlüssel aus der Kopplung
// Liefert das Gerät oder den Grund der Ablehnung: 'clock' (Uhr daneben – die Kopplung gilt weiter) oder 'not paired'
function authorized(req, body) {
  var m = /^Tonalo ([^:]+):(\d+):([0-9a-f]{16,64}):([0-9a-f]{64})$/.exec(req.headers.authorization || '');
  if (!m) return 'not paired';
  var entry = keyFor(m[1]);
  if (!entry) return 'not paired';
  var want = crypto.createHmac('sha256', Buffer.from(entry.key, 'hex'))
    .update(req.method + '\n' + req.url + '\n' + m[2] + '\n' + m[3] + '\n' + body).digest();
  var got = Buffer.from(m[4], 'hex');
  if (got.length !== want.length || !crypto.timingSafeEqual(got, want)) return 'not paired';
  var now = Date.now();
  if (Math.abs(now / 1000 - +m[2]) > 120) return 'clock';
  Object.keys(nonces).forEach(function (n) { if (nonces[n] < now) delete nonces[n]; });
  if (nonces[m[3]]) return 'not paired';
  nonces[m[3]] = now + 250000;
  return entry;
}

function reply(res, code, obj) {
  var body = Buffer.from(JSON.stringify(obj), 'utf8');
  res.writeHead(code, { 'Content-Type': 'application/json', 'Content-Length': body.length });
  res.end(body);
}

function handle(req, res, body) {
  var path = req.url.split('?')[0];
  if (req.method === 'GET' && path === '/info') return reply(res, 200, { app: 'tonalo', id: tv.id, name: tv.name });

  // Kopplung: der TV zeigt einen Code, das iPhone schickt ihn zurück und bekommt einen eigenen Schlüssel
  if (req.method === 'POST' && path === '/pair/start') {
    if (!app) return reply(res, 503, { error: 'not running' });
    var now = Date.now();
    if (now < lockedUntil || now - lastStart < 3000) return reply(res, 429, { error: 'too many tries' });
    lastStart = now;
    var ask = parse(body);
    // Ob Gast oder eigenes iPhone, steht hier fest – und damit auch auf dem Bildschirm, den der TV zeigt
    pairing = { code: String(crypto.randomBytes(4).readUInt32BE(0) % 1000000 + 1000000).slice(1), until: Date.now() + 120000, tries: 0, guest: !!ask.guest };
    send({ pairCode: pairing.code, pairName: String(ask.device || '').slice(0, 60), guest: !!ask.guest });
    return reply(res, 200, { ok: true });
  }
  if (req.method === 'POST' && path === '/pair/finish') {
    var p = parse(body);
    if (!pairing || Date.now() > pairing.until) return reply(res, 410, { error: 'expired' });
    // Der Code selbst geht nie übers Netz – nur ein Nachweis, dass das iPhone ihn kennt, über seinen öffentlichen Schlüssel
    var pub = /^[0-9a-f]{130}$/.test(p.pub || '') ? Buffer.from(p.pub, 'hex') : null;
    var proof = /^[0-9a-f]{64}$/.test(p.proof || '') ? Buffer.from(p.proof, 'hex') : null;
    var expect = pub && crypto.createHmac('sha256', pairing.code).update(pub).digest();
    if (!proof || !expect || !crypto.timingSafeEqual(proof, expect)) {
      // Raten lohnt nicht: nach fünf Fehlversuchen gilt der Code nicht mehr, nach 15 ist für 10 min Schluss
      // Wer weiterrät, wartet jedes Mal doppelt so lange: 10 min, 20 min, 40 min … höchstens einen Tag
      if (++failures >= 15) { lockedUntil = Date.now() + Math.min(600000 * Math.pow(2, lockouts++), 86400000); failures = 0; pairing.tries = 5; }
      if (++pairing.tries >= 5) { pairing = null; send({ pairCode: null }); }
      return reply(res, 403, { error: 'wrong code' });
    }
    // Beide Seiten errechnen denselben Schlüssel (ECDH) – wer im WLAN mitliest, bekommt ihn nicht zu sehen
    var ecdh = crypto.createECDH('prime256v1'), secret;
    ecdh.generateKeys();
    try { secret = ecdh.computeSecret(pub); } catch (e) { return reply(res, 400, { error: 'bad key' }); }
    var key = crypto.createHmac('sha256', secret).update('tonalo-pair\n' + pairing.code).digest('hex');
    var entry = { id: crypto.randomBytes(8).toString('hex'), device: String(p.device || 'iPhone').slice(0, 60), key: key, guest: pairing.guest };
    pairing = null;
    failures = 0;
    lockouts = 0;
    tv.keys = tv.keys.concat([entry]);
    send({ pairCode: null, keys: tv.keys, paired: entry.device, guest: entry.guest });
    return reply(res, 200, { id: entry.id, pub: ecdh.getPublicKey('hex'), tv: tv.id, name: tv.name });
  }

  // Noch keine Oberfläche da, die die Schlüssel hält (App eben gestartet, Profilauswahl): nicht „unbekannt“ antworten,
  // sonst vergisst das iPhone die Kopplung. Es versucht es später wieder.
  if (!app && (path === '/events' || path === '/command')) return reply(res, 503, { error: 'not running' });
  var who = authorized(req, body);
  // Geht nur die Uhr falsch, erfährt das iPhone die Zeit hier und rechnet ab dann damit
  if (typeof who === 'string') return reply(res, 401, who === 'clock' ? { error: who, now: Math.floor(Date.now() / 1000) } : { error: who });

  if (req.method === 'GET' && path === '/events') {
    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' });
    var client = { res: res, entry: who };
    clients.push(client);
    if (who.guest) broadcast(); else res.write(line(false)); // ein neuer Gast: alle sehen, wer dabei ist
    report();
    var ping = setInterval(function () { res.write(': ping\n\n'); }, 20000);
    // Am Antwort-Objekt, nicht an der Anfrage: neuere Node-Versionen melden dort schon das Ende der Anfrage selbst
    res.on('close', function () {
      clearInterval(ping);
      clients = clients.filter(function (c) { return c !== client; });
      if (who.guest) broadcast();
      report();
    });
    return;
  }
  // Das eigene iPhone übergibt die DJ-Einrichtung (Anbieter, Modell, Schlüssel) oder nimmt sie wieder weg.
  // Gäste der Jukebox dürfen das nie. Der Inhalt ist mit dem Schlüssel aus der Kopplung verschlüsselt:
  // die Verbindung selbst ist nur signiert, und ein API-Schlüssel darf im WLAN nicht mitzulesen sein.
  if (req.method === 'POST' && path === '/dj') {
    if (!app) return reply(res, 503, { error: 'not running' });
    if (who.guest) return reply(res, 403, { error: 'host only' });
    var given = djOpen(parse(body).box, who);
    if (!given) return reply(res, 400, { error: 'bad box' });
    djSave(given.off ? null : djClean(given), true);
    return reply(res, 200, { ok: true, dj: !!djCfg });
  }
  if (req.method === 'POST' && path === '/command') {
    if (!app) return reply(res, 503, { error: 'not running' });
    var cmd = parse(body);
    if (who.guest) {
      if (GUEST.indexOf(cmd.cmd) < 0) return reply(res, 403, { error: 'host only' });
      cmd = { cmd: cmd.cmd, songs: Array.isArray(cmd.songs) ? cmd.songs.slice(0, GUEST_SONGS).map(guestSong).filter(Boolean) : undefined };
      cmd.by = who.device; // der TV zeigt kurz, wer etwas hinzugefügt hat
    }
    send({ command: cmd });
    return reply(res, 200, { ok: true });
  }
  reply(res, 404, { error: 'not found' });
}

// ---------- DJ: ein KI-Modell stellt Sets aus der Bibliothek zusammen. Die Einrichtung kommt vom eigenen iPhone.
// Der Schlüssel geht nur von hier aus an die feste Adresse seines Anbieters – nie an eine andere, auch nicht nach
// einer Weiterleitung (denen folgt Node nicht), und nie in einer Adresse, immer in einem Header.
var djCfg = null;      // { provider, model, key, address }
var djSent = [];       // wann Anfragen rausgingen: höchstens 20 pro Stunde, damit keine Schleife Kosten auftürmt
var DJ_HOSTS = { anthropic: 'api.anthropic.com', gemini: 'generativelanguage.googleapis.com', ollamaCloud: 'ollama.com' };
var DJ_SCHEMA = { type: 'object', properties: { line: { type: 'string' }, songs: { type: 'array', items: { type: 'integer' } } }, required: ['line', 'songs'], additionalProperties: false };

function djStore() { return global.tonaloDJ || null; }

// Nur was eine Einrichtung braucht, in engen Grenzen – der Inhalt kam übers Netz
function djClean(c) {
  if (!c || typeof c !== 'object') return null;
  var provider = String(c.provider || '');
  if (provider !== 'ollama' && !DJ_HOSTS[provider]) return null;
  var model = String(c.model || '');
  if (!/^[A-Za-z0-9._:\-]{1,99}$/.test(model)) return null;
  var out = { provider: provider, model: model };
  if (provider === 'ollama') {
    out.address = String(c.address || '').slice(0, 200);
    if (!djOllama(out.address)) return null;
  } else {
    out.key = String(c.key || '');
    if (!out.key || out.key.length > 500 || /[^\x21-\x7e]/.test(out.key)) return null;
  }
  return out;
}

// Was die Oberfläche wissen darf: wer auswählt und wohin es geht – nie der Schlüssel
function djPublic() {
  if (!djCfg) return null;
  var o = djCfg.provider === 'ollama' ? djOllama(djCfg.address) : null;
  return { provider: djCfg.provider, model: djCfg.model, host: o ? o.hostname : DJ_HOSTS[djCfg.provider] || '' };
}

function djSave(cfg, given) {
  djCfg = cfg;
  var note = { djInfo: djPublic(), djGiven: !!(given && cfg) }; // djGiven: eben vom iPhone gekommen – die App sagt kurz Bescheid
  if (!djStore()) note.dj = cfg; // die TV-App legt sie zum Konto ab und gibt sie beim nächsten Start wieder her
  else djStore().set(tv.account, cfg);
  send(note);
}

// AES-256-GCM mit einem Schlüssel, der aus dem der Kopplung abgeleitet ist. Aufbau: 12 Bytes Einmalwert, Inhalt, 16 Bytes Siegel.
function djOpen(box, who) {
  if (typeof box !== 'string' || !/^([0-9a-f]{2}){29,4000}$/.test(box)) return null;
  try {
    var raw = Buffer.from(box, 'hex');
    var key = crypto.createHmac('sha256', Buffer.from(who.key, 'hex')).update('tonalo-dj').digest();
    var d = crypto.createDecipheriv('aes-256-gcm', key, raw.slice(0, 12));
    d.setAAD(Buffer.from(String(who.id), 'utf8'));
    d.setAuthTag(raw.slice(raw.length - 16));
    var text = Buffer.concat([d.update(raw.slice(12, raw.length - 16)), d.final()]).toString('utf8');
    var v = JSON.parse(text);
    return v && typeof v === 'object' ? v : null;
  } catch (e) { return null; }
}

function djLocalHost(host) {
  host = String(host || '').toLowerCase().replace(/^\[|\]$/g, '');
  // Nur echte Adressen durch local(): ein Name wie „fd-server.example“ sähe dort sonst wie eine private IPv6-Adresse aus
  if (/^\d+\.\d+\.\d+\.\d+$/.test(host) || host.indexOf(':') >= 0) return local(host);
  return host === 'localhost' || host.indexOf('.') < 0 || /\.(local|lan|home|home\.arpa|internal|fritz\.box|localhost)$/.test(host);
}

// Ohne http(s) davor: im Heimnetz http, sonst https. Unverschlüsselt geht die Songliste nur im Heimnetz raus.
function djOllama(address) {
  var s = String(address || '').trim().replace(/\/+$/, '');
  if (!s) return null;
  if (!/^[a-z]+:\/\//i.test(s)) s = (djLocalHost(s.split('/')[0].replace(/:\d+$/, '')) ? 'http://' : 'https://') + s;
  var u;
  try { u = new URL_(s); } catch (e) { return null; }
  if (u.protocol === 'https:') return u;
  return u.protocol === 'http:' && djLocalHost(u.hostname) ? u : null;
}

// Eine Anfrage an den Anbieter. cb(fehler, status, text)
function djPost(u, path, headers, body, cb) {
  var data = Buffer.from(JSON.stringify(body), 'utf8'), done = false, req;
  function end(err, status, text) { if (!done) { done = true; cb(err, status, text); } }
  headers = Object.assign({ 'Content-Type': 'application/json', 'Content-Length': data.length, 'User-Agent': 'Tonalo' }, headers);
  try {
    req = (u.protocol === 'https:' ? https : http).request({
      hostname: u.hostname.replace(/^\[|\]$/g, ''), port: u.port || undefined, path: path, method: 'POST', headers: headers
    }, function (res) {
      var chunks = [], size = 0;
      res.on('data', function (c) { size += c.length; if (size > 2000000) { end('size'); req.abort(); } else chunks.push(c); });
      res.on('end', function () { end(null, res.statusCode, Buffer.concat(chunks).toString('utf8')); });
      res.on('error', function () { end('read'); });
    });
  } catch (e) { return end('header'); }
  req.setTimeout(120000, function () { end('timeout'); req.abort(); });
  req.on('error', function (e) { end(e && e.code ? String(e.code) : 'network'); });
  req.write(data);
  req.end();
}

// Schickt Anweisung und Songliste los, liefert den rohen Text der Antwort. cb(fehler, text)
function djAsk(system, user, cb) {
  var c = djCfg, u, json;
  function parsed(status, text) {
    if (status === 401 || status === 403) { cb('key'); return null; }
    if (status !== 200) { cb('status:' + status); return null; } // der Inhalt wird nie gezeigt: er könnte wiederholen, was gesendet wurde
    try { return JSON.parse(text); } catch (e) { cb('answer'); return null; }
  }
  if (c.provider === 'anthropic') {
    u = new URL_('https://' + DJ_HOSTS.anthropic);
    var body = { model: c.model, max_tokens: 8000, system: system, messages: [{ role: 'user', content: user }],
      output_config: { effort: 'low', format: { type: 'json_schema', schema: DJ_SCHEMA } } };
    var headers = { 'x-api-key': c.key, 'anthropic-version': '2026-10-21' };
    // Lehnt eine Sicherheitsprüfung fälschlich ab, versucht es der Anbieter im selben Aufruf mit einem anderen seiner Modelle
    if (c.model.indexOf('claude-haiku') !== 0) { body.fallbacks = 'default'; headers['anthropic-beta'] = 'server-side-fallback-2026-07-01'; }
    return djPost(u, '/v1/messages', headers, body, function (err, status, text) {
      if (err) return cb(err);
      if (!(json = parsed(status, text))) return;
      if (json.stop_reason === 'refusal') return cb('refused');
      cb(null, (json.content || []).filter(function (b) { return b && b.type === 'text'; }).map(function (b) { return b.text || ''; }).join(''));
    });
  }
  if (c.provider === 'gemini') {
    u = new URL_('https://' + DJ_HOSTS.gemini);
    return djPost(u, '/v1beta/models/' + c.model + ':generateContent', { 'x-goog-api-key': c.key }, {
      systemInstruction: { parts: [{ text: system }] }, contents: [{ role: 'user', parts: [{ text: user }] }],
      generationConfig: { responseMimeType: 'application/json', responseJsonSchema: DJ_SCHEMA }
    }, function (err, status, text) {
      if (err) return cb(err);
      if (!(json = parsed(status, text))) return;
      var parts = json.candidates && json.candidates[0] && json.candidates[0].content && json.candidates[0].content.parts;
      if (!parts) return cb('refused');
      cb(null, parts.map(function (x) { return (x && x.text) || ''; }).join(''));
    });
  }
  // Ollama, zu Hause oder in der Cloud. Denkende Modelle verbrauchen sonst die ganze Antwort fürs Nachdenken: das wird
  // abgeschaltet. Kennt ein Server den Schalter nicht, geht es ohne; bleibt die Antwort leer, noch einmal ohne festes Format.
  u = c.provider === 'ollama' ? djOllama(c.address) : new URL_('https://' + DJ_HOSTS.ollamaCloud);
  if (!u) return cb('address');
  var auth = c.provider === 'ollamaCloud' ? { Authorization: 'Bearer ' + c.key } : {};
  var think = true, last = '';
  function round(format) {
    var b = { model: c.model, messages: [{ role: 'system', content: system }, { role: 'user', content: user }], stream: false, options: { num_ctx: 16384 } };
    if (format) b.format = DJ_SCHEMA;
    if (think) b.think = false;
    djPost(u, '/api/chat', auth, b, function (err, status, text) {
      if (err) return cb(err);
      if (status === 400 && think) { think = false; return round(format); }
      if (!(json = parsed(status, text))) return;
      var m = json.message || {}, content = typeof m.content === 'string' ? m.content : '';
      if (content.indexOf('{') >= 0 || content.indexOf('[') >= 0) return cb(null, content);
      last = content || (typeof m.thinking === 'string' ? m.thinking : '');
      if (format) round(false); else cb(null, last);
    });
  }
  round(true);
}

service.register('dj', function (msg) {
  var p = msg.payload || {};
  function fail(text) { msg.respond({ returnValue: false, errorText: text }); }
  if (!djCfg) return fail('notReady');
  if (typeof p.system !== 'string' || typeof p.user !== 'string' || p.system.length > 8000 || p.user.length > 60000) return fail('notReady');
  var now = Date.now();
  djSent = djSent.filter(function (t) { return now - t < 3600000; });
  if (djSent.length >= 20) return fail('limit');
  djSent.push(now);
  try {
    djAsk(p.system, p.user, function (err, text) {
      if (err) fail(err); else msg.respond({ returnValue: true, text: String(text || '').slice(0, 20000) });
    });
  } catch (e) { fail('network'); }
});

// Von diesem Gerät entfernen (Einstellungen, oder alle iPhones getrennt)
service.register('djClear', function (msg) {
  // Ein anderes Konto als das laufende wird entfernt (am PC liegt seine Einrichtung im Hauptprozess)
  var account = String((msg.payload && msg.payload.account) || '');
  if (account && account !== tv.account) { if (djStore()) djStore().set(account, null); }
  else djSave(null);
  msg.respond({ returnValue: true });
});

function parse(body) { try { var v = JSON.parse(body); return v && typeof v === 'object' ? v : {}; } catch (e) { return {}; } }

// Nur aus dem eigenen Netz: private Adressen (IPv4 und IPv6). Hat der PC oder TV eine öffentliche IPv6-Adresse,
// kommt von außen trotzdem niemand bis zur Kopplung
function local(addr) {
  var a = String(addr || '').toLowerCase().replace(/^::ffff:/, '');
  var m = /^(\d+)\.(\d+)\.\d+\.\d+$/.exec(a);
  if (m) {
    var x = +m[1], y = +m[2];
    return x === 10 || x === 127 || (x === 192 && y === 168) || (x === 172 && y >= 16 && y < 32) || (x === 169 && y === 254);
  }
  return a === '::1' || /^f[cd]/.test(a) || /^fe[89ab]/.test(a);
}

function startServer() {
  if (server) return;
  server = http.createServer(function (req, res) {
    if (!local(req.socket.remoteAddress)) { req.socket.destroy(); return; }
    // Ein iPhone, das ohne Abschied verschwindet (WLAN weg, Gerät aus), soll nicht ewig als verbunden gelten
    req.socket.setKeepAlive(true, 10000);
    var chunks = [], size = 0;
    req.on('data', function (c) { size += c.length; if (size > 2000000) req.destroy(); else chunks.push(c); });
    req.on('end', function () { handle(req, res, Buffer.concat(chunks).toString('utf8')); });
  });
  server.on('error', function (e) {
    console.error('server', e); server = null;
    // Der Port war kurz belegt oder das Netz wurde gewechselt: nach ein paar Sekunden neu versuchen
    if (wantNet) { clearTimeout(netRetry); netRetry = setTimeout(function () { if (wantNet) startServer(); }, 3000); }
  });
  server.listen(PORT);
  // Läuft weiter, auch wenn gerade keine Anfrage kommt
  service.activityManager.create('keepAlive', function () {});
}

// ---------- Im WLAN auffindbar (mDNS / Bonjour): _tonalo._tcp
var mdns = null, announcer = null, wantNet = false, netRetry = null, netSig = '';
var TYPE = '_tonalo._tcp.local';

// Adressen im Heimnetz, die beste zuerst. Ein Windows-PC hat oft virtuelle Netze (WSL, Hyper-V, VPN …),
// deren Adresse das iPhone nie erreicht – die kommen ans Ende.
var VIRTUAL = /vethernet|wsl|hyper-v|virtualbox|vmware|vbox|docker|tailscale|zerotier|wireguard|vpn|tap|tun|bluetooth|bridge|loopback/i;
function lanAddrs() {
  var all = os.networkInterfaces(), out = [];
  Object.keys(all).forEach(function (n) {
    all[n].forEach(function (a) {
      if (a.family === 'IPv4' && !a.internal && !/^169\.254\./.test(a.address)) out.push({ ip: a.address, mask: a.netmask, virtual: VIRTUAL.test(n) });
    });
  });
  function rank(a) {
    var p = a.ip.split('.').map(Number);
    var home = p[0] === 192 && p[1] === 168 ? 0 : p[0] === 10 ? 1 : p[0] === 172 && p[1] >= 16 && p[1] < 32 ? 2 : 3;
    return (a.virtual ? 10 : 0) + home;
  }
  return out.sort(function (a, b) { return rank(a) - rank(b); });
}

function sameNet(a, peer) {
  var x = a.ip.split('.').map(Number), y = peer.split('.').map(Number), m = String(a.mask || '255.255.255.0').split('.').map(Number);
  for (var i = 0; i < 4; i++) if ((x[i] & m[i]) !== (y[i] & m[i])) return false;
  return true;
}

// Die Adresse, unter der uns der Fragende erreicht: im selben Netz wie er, sonst die beste
function lanIp(peer) {
  var list = lanAddrs();
  if (peer && /^\d+\.\d+\.\d+\.\d+$/.test(peer)) {
    for (var i = 0; i < list.length; i++) if (sameNet(list[i], peer)) return list[i].ip;
  }
  return list.length ? list[0].ip : null;
}

function encodeName(name) {
  var parts = name.split('.').filter(Boolean).map(function (l) {
    while (Buffer.byteLength(l, 'utf8') > 63) l = l.slice(0, -1); // ein Teil eines Namens hat höchstens 63 Bytes
    var b = Buffer.from(l, 'utf8');
    return Buffer.concat([Buffer.from([b.length]), b]);
  });
  return Buffer.concat(parts.concat([Buffer.from([0])]));
}

function record(name, type, cls, ttl, data) {
  var head = Buffer.alloc(10);
  head.writeUInt16BE(type, 0); head.writeUInt16BE(cls, 2); head.writeUInt32BE(ttl, 4); head.writeUInt16BE(data.length, 8);
  return Buffer.concat([encodeName(name), head, data]);
}

function instanceName() { return tv.name.replace(/\./g, ' ') + '.' + TYPE; }
function hostName() { return 'tonalo-' + tv.id.slice(0, 8) + '.local'; }

function answer(query, peer, ttl) {
  if (ttl === undefined) ttl = 120;
  var ip = lanIp(peer);
  if (!ip || !tv.id) return null;
  var instance = instanceName();
  var host = hostName();
  var srv = Buffer.alloc(6); srv.writeUInt16BE(0, 0); srv.writeUInt16BE(0, 2); srv.writeUInt16BE(PORT, 4);
  var txt = Buffer.concat(['id=' + tv.id, 'kind=' + tv.kind].map(function (t) {
    var b = Buffer.from(t, 'utf8');
    return Buffer.concat([Buffer.from([b.length]), b]);
  }));
  var only = query ? 1 : 0x8001; // „nur dieser Eintrag gilt“ – nicht bei direkten Antworten
  var records = [
    record(TYPE, 12, 1, ttl, encodeName(instance)),
    record(instance, 33, only, ttl, Buffer.concat([srv, encodeName(host)])),
    record(instance, 16, only, ttl, txt),
    record(host, 1, only, ttl, Buffer.from(ip.split('.').map(Number)))
  ];
  var header = Buffer.alloc(12);
  header.writeUInt16BE(0x8400, 2); header.writeUInt16BE(records.length, 6);
  if (!query) return Buffer.concat([header].concat(records));
  // Direkte Antwort: dieselbe Nummer und die Frage dazu, sonst verwirft der Fragende sie
  header.writeUInt16BE(query.readUInt16BE(0), 0); header.writeUInt16BE(query.readUInt16BE(4), 4);
  return Buffer.concat([header, query.slice(12)].concat(records));
}

function readName(buf, off) {
  var labels = [], jumped = false, end = off, guard = 0;
  while (off < buf.length && guard++ < 64) {
    var len = buf[off];
    if (len === 0) { if (!jumped) end = off + 1; break; }
    if ((len & 0xc0) === 0xc0) { if (!jumped) end = off + 2; off = ((len & 0x3f) << 8) | buf[off + 1]; jumped = true; continue; }
    labels.push(buf.toString('utf8', off + 1, off + 1 + len));
    off += len + 1;
  }
  return { name: labels.join('.').toLowerCase(), end: end };
}

// Fragt jemand nach uns – nach dem Dienst, nach diesem TV (Port) oder nach seiner Adresse? Liefert dann das Ende der Fragen
function asksForUs(buf) {
  if (buf.length < 12 || (buf.readUInt16BE(2) & 0x8000) || !tv.id) return 0; // nur Fragen, keine Antworten
  var names = [TYPE, '_services._dns-sd._udp.local', instanceName().toLowerCase(), hostName()];
  var count = buf.readUInt16BE(4), off = 12, ours = false;
  for (var i = 0; i < count; i++) {
    var q = readName(buf, off);
    off = q.end + 4;
    if (names.indexOf(q.name) >= 0) ours = true;
  }
  return ours && off <= buf.length ? off : 0;
}

function announce(to, peer, ttl) {
  var packet = answer(to && to.query, peer || (to && to.address), ttl);
  if (packet && mdns) mdns.send(packet, 0, packet.length, to ? to.port : 5353, to ? to.address : '224.0.0.251');
}

function startMdns() {
  if (mdns) { announce(); return; }
  mdns = dgram.createSocket({ type: 'udp4', reuseAddr: true });
  mdns.on('message', function (buf, from) {
    // Fragen von einem anderen Port als 5353 wollen die Antwort direkt zurück, mit ihrer Nummer und Frage
    var asked = asksForUs(buf);
    if (asked && local(from.address)) announce(from.port !== 5353 ? { port: from.port, address: from.address, query: buf.slice(0, asked) } : null, from.address);
  });
  var mine = mdns;
  mdns.on('error', function (e) {
    console.error('mdns', e); try { mine.close(); } catch (x) { /* egal */ }
    if (mdns !== mine) return;
    mdns = null;
    // Der Socket ist weg (Netz gewechselt, Ruhezustand): neu aufbauen, solange die App läuft
    if (wantNet) { clearTimeout(netRetry); netRetry = setTimeout(function () { if (wantNet) startMdns(); }, 3000); }
  });
  mdns.bind(5353, function () {
    // In jedem Netz zuhören, gesendet wird ins beste (sonst landet es am PC womöglich im virtuellen Netz)
    var joined = 0, list = lanAddrs();
    list.forEach(function (a) { try { mdns.addMembership('224.0.0.251', a.ip); joined++; } catch (e) { /* dieses Netz nicht */ } });
    if (!joined) { try { mdns.addMembership('224.0.0.251'); } catch (e) { console.error('mdns join', e); } }
    try { if (list.length) mdns.setMulticastInterface(list[0].ip); mdns.setMulticastTTL(255); } catch (e) { console.error('mdns if', e); }
    announce();
    setTimeout(announce, 1000);
    // Zur Sicherheit regelmäßig von selbst melden – manche Router reichen Suchanfragen nicht zuverlässig weiter
    clearInterval(announcer);
    netSig = lanAddrs().map(function (a) { return a.ip; }).join(',');
    announcer = setInterval(function () {
      if (!app) return;
      // Anderes Netz oder andere Adresse (WLAN gewechselt, VPN an/aus): neu verbinden, sonst findet das iPhone uns nicht mehr
      var sig = lanAddrs().map(function (a) { return a.ip; }).join(',');
      if (sig !== netSig && mdns) { var old = mdns; mdns = null; try { old.close(); } catch (e) { /* egal */ } startMdns(); return; }
      announce();
    }, 60000);
  });
}
