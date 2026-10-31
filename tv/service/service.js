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
var tv = { id: '', name: 'TV', keys: [], others: [] }; // keys: [{ id, device, key }], gespeichert macht sie die App
                                                        // others: die iPhones der anderen Konten – hier nur Gäste
var state = { active: false };
var clients = [];      // offene Live-Verbindungen der iPhones: { res, entry }
var pairing = null;    // { code, until, tries, guest }
var failures = 0, lockedUntil = 0; // falsche Codes über alle Kopplungen – Raten wird nach 15 Fehlern 10 min gesperrt
var nonces = {};       // schon benutzte Anfragen: eine mitgeschnittene Anfrage geht kein zweites Mal durch
var server = null;

function send(msg) { if (app) app.respond(Object.assign({ returnValue: true }, msg)); }

// ---------- TV-App
service.register('attach', function (msg) {
  var p = msg.payload || {};
  tv.id = String(p.id || tv.id);
  tv.name = String(p.name || tv.name);
  tv.keys = Array.isArray(p.keys) ? p.keys : [];
  tv.others = Array.isArray(p.others) ? p.others : [];
  // Getrennte Geräte sehen ab sofort nichts mehr, auch nicht über eine schon offene Verbindung – und wer mit dem
  // Kontowechsel nur noch Gast ist (oder wieder mehr), verbindet sich neu und bekommt seine neue Rolle
  var gone = clients.filter(function (c) { var k = keyFor(c.entry.id); return !k || !!k.guest !== !!c.entry.guest; });
  // Sofort aus der Liste, nicht erst wenn die Verbindung zu ist – sonst schreibt der nächste Stand noch hinein
  clients = clients.filter(function (c) { return gone.indexOf(c) < 0; });
  gone.forEach(function (c) { c.res.end(); });
  if (app && app !== msg) { try { app.cancel(); } catch (e) { /* schon weg */ } }
  app = msg;
  startServer();
  startMdns();
  msg.respond({ returnValue: true, port: PORT });
}, function (msg) {
  // App geschlossen: es läuft nichts mehr, das iPhone spielt wieder selbst
  if (app !== msg) return;
  app = null;
  setState({ active: false });
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
  if (guest) { delete s.user; s.jukebox = true; } // so weiß ein iPhone, dass es hier nur Gast sein kann
  return 'data: ' + JSON.stringify(s) + '\n\n';
}

function broadcast() {
  var forHost = line(false), forGuest = line(true);
  clients.forEach(function (c) { c.res.write(c.entry.guest ? forGuest : forHost); });
}

function guestNames() {
  var names = [];
  clients.forEach(function (c) { if (c.entry.guest && names.indexOf(c.entry.device) < 0) names.push(c.entry.device); });
  return names;
}

// Was Gäste dürfen: Songs hinzufügen (höchstens 20 auf einmal) und überspringen
var GUEST = ['enqueue', 'playNext', 'next'];
var GUEST_SONGS = 20;

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
    if (Date.now() < lockedUntil) return reply(res, 429, { error: 'too many tries' });
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
      if (++failures >= 15) { lockedUntil = Date.now() + 600000; failures = 0; pairing.tries = 5; }
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
    tv.keys = tv.keys.concat([entry]);
    send({ pairCode: null, keys: tv.keys, paired: entry.device, guest: entry.guest });
    return reply(res, 200, { id: entry.id, pub: ecdh.getPublicKey('hex'), tv: tv.id, name: tv.name });
  }

  var who = authorized(req, body);
  if (typeof who === 'string') return reply(res, 401, { error: who });

  if (req.method === 'GET' && path === '/events') {
    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' });
    var client = { res: res, entry: who };
    clients.push(client);
    if (who.guest) broadcast(); else res.write(line(false)); // ein neuer Gast: alle sehen, wer dabei ist
    var ping = setInterval(function () { res.write(': ping\n\n'); }, 20000);
    // Am Antwort-Objekt, nicht an der Anfrage: neuere Node-Versionen melden dort schon das Ende der Anfrage selbst
    res.on('close', function () {
      clearInterval(ping);
      clients = clients.filter(function (c) { return c !== client; });
      if (who.guest) broadcast();
    });
    return;
  }
  if (req.method === 'POST' && path === '/command') {
    if (!app) return reply(res, 503, { error: 'not running' });
    var cmd = parse(body);
    if (who.guest) {
      if (GUEST.indexOf(cmd.cmd) < 0) return reply(res, 403, { error: 'host only' });
      if (Array.isArray(cmd.songs)) cmd.songs = cmd.songs.slice(0, GUEST_SONGS);
      cmd.by = who.device; // der TV zeigt kurz, wer etwas hinzugefügt hat
    }
    send({ command: cmd });
    return reply(res, 200, { ok: true });
  }
  reply(res, 404, { error: 'not found' });
}

function parse(body) { try { return JSON.parse(body) || {}; } catch (e) { return {}; } }

function startServer() {
  if (server) return;
  server = http.createServer(function (req, res) {
    var chunks = [], size = 0;
    req.on('data', function (c) { size += c.length; if (size > 2000000) req.destroy(); else chunks.push(c); });
    req.on('end', function () { handle(req, res, Buffer.concat(chunks).toString('utf8')); });
  });
  server.on('error', function (e) { console.error('server', e); server = null; });
  server.listen(PORT);
  // Läuft weiter, auch wenn gerade keine Anfrage kommt
  service.activityManager.create('keepAlive', function () {});
}

// ---------- Im WLAN auffindbar (mDNS / Bonjour): _tonalo._tcp
var mdns = null;
var TYPE = '_tonalo._tcp.local';

function lanIp() {
  var all = os.networkInterfaces(), out = null;
  Object.keys(all).forEach(function (n) {
    all[n].forEach(function (a) { if (!out && a.family === 'IPv4' && !a.internal) out = a.address; });
  });
  return out;
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

function answer(query) {
  var ip = lanIp();
  if (!ip || !tv.id) return null;
  var instance = instanceName();
  var host = hostName();
  var srv = Buffer.alloc(6); srv.writeUInt16BE(0, 0); srv.writeUInt16BE(0, 2); srv.writeUInt16BE(PORT, 4);
  var txt = Buffer.from('id=' + tv.id, 'utf8');
  var only = query ? 1 : 0x8001; // „nur dieser Eintrag gilt“ – nicht bei direkten Antworten
  var records = [
    record(TYPE, 12, 1, 120, encodeName(instance)),
    record(instance, 33, only, 120, Buffer.concat([srv, encodeName(host)])),
    record(instance, 16, only, 120, Buffer.concat([Buffer.from([txt.length]), txt])),
    record(host, 1, only, 120, Buffer.from(ip.split('.').map(Number)))
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

function announce(to) {
  var packet = answer(to && to.query);
  if (packet && mdns) mdns.send(packet, 0, packet.length, to ? to.port : 5353, to ? to.address : '224.0.0.251');
}

function startMdns() {
  if (mdns) { announce(); return; }
  mdns = dgram.createSocket({ type: 'udp4', reuseAddr: true });
  mdns.on('message', function (buf, from) {
    // Fragen von einem anderen Port als 5353 wollen die Antwort direkt zurück, mit ihrer Nummer und Frage
    var asked = asksForUs(buf);
    if (asked) announce(from.port !== 5353 ? { port: from.port, address: from.address, query: buf.slice(0, asked) } : null);
  });
  mdns.on('error', function (e) { console.error('mdns', e); try { mdns.close(); } catch (x) { /* egal */ } mdns = null; });
  mdns.bind(5353, function () {
    try { mdns.addMembership('224.0.0.251'); mdns.setMulticastTTL(255); } catch (e) { console.error('mdns join', e); }
    announce();
    setTimeout(announce, 1000);
    // Zur Sicherheit regelmäßig von selbst melden – manche Router reichen Suchanfragen nicht zuverlässig weiter
    setInterval(function () { if (app) announce(); }, 60000);
  });
}
