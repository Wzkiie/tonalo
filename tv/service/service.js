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
var tv = { id: '', name: 'TV', keys: [] }; // keys: [{ id, device, key }], gespeichert macht sie die App
var state = { active: false };
var clients = [];      // offene Live-Verbindungen der iPhones: { res, entry }
var pairing = null;    // { code, until, tries }
var server = null;

function send(msg) { if (app) app.respond(Object.assign({ returnValue: true }, msg)); }

// ---------- TV-App
service.register('attach', function (msg) {
  var p = msg.payload || {};
  tv.id = String(p.id || tv.id);
  tv.name = String(p.name || tv.name);
  tv.keys = Array.isArray(p.keys) ? p.keys : [];
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
  if (guest) delete s.user;
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

// Was Gäste dürfen: Songs hinzufügen und überspringen
var GUEST = ['enqueue', 'playNext', 'next'];

// ---------- Anmeldung der iPhones: HMAC über Methode, Pfad, Zeit und Inhalt mit dem Schlüssel aus der Kopplung
function authorized(req, body) {
  var m = /^Tonalo ([^:]+):(\d+):([0-9a-f]{64})$/.exec(req.headers.authorization || '');
  if (!m || Math.abs(Date.now() / 1000 - +m[2]) > 120) return null;
  var entry = tv.keys.filter(function (k) { return k.id === m[1]; })[0];
  if (!entry) return null;
  var want = crypto.createHmac('sha256', Buffer.from(entry.key, 'hex'))
    .update(req.method + '\n' + req.url + '\n' + m[2] + '\n' + body).digest();
  var got = Buffer.from(m[3], 'hex');
  return got.length === want.length && crypto.timingSafeEqual(got, want) ? entry : null;
}

function reply(res, code, obj) {
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(obj));
}

function handle(req, res, body) {
  var path = req.url.split('?')[0];
  if (req.method === 'GET' && path === '/info') return reply(res, 200, { app: 'tonalo', id: tv.id, name: tv.name });

  // Kopplung: der TV zeigt einen Code, das iPhone schickt ihn zurück und bekommt einen eigenen Schlüssel
  if (req.method === 'POST' && path === '/pair/start') {
    if (!app) return reply(res, 503, { error: 'not running' });
    var ask = parse(body);
    pairing = { code: String(crypto.randomBytes(4).readUInt32BE(0) % 1000000 + 1000000).slice(1), until: Date.now() + 120000, tries: 0 };
    send({ pairCode: pairing.code, pairName: String(ask.device || '').slice(0, 60), guest: !!ask.guest });
    return reply(res, 200, { ok: true });
  }
  if (req.method === 'POST' && path === '/pair/finish') {
    var p = parse(body);
    if (!pairing || Date.now() > pairing.until) return reply(res, 410, { error: 'expired' });
    if (String(p.code) !== pairing.code) {
      // Raten lohnt nicht: nach fünf Fehlversuchen gilt der Code nicht mehr
      if (++pairing.tries >= 5) { pairing = null; send({ pairCode: null }); }
      return reply(res, 403, { error: 'wrong code' });
    }
    pairing = null;
    var entry = { id: crypto.randomBytes(8).toString('hex'), device: String(p.device || 'iPhone').slice(0, 60), key: crypto.randomBytes(32).toString('hex'), guest: !!p.guest };
    tv.keys = tv.keys.concat([entry]);
    send({ pairCode: null, keys: tv.keys, paired: entry.device, guest: entry.guest });
    return reply(res, 200, { id: entry.id, key: entry.key, tv: tv.id, name: tv.name });
  }

  var who = authorized(req, body);
  if (!who) return reply(res, 401, { error: 'not paired' });

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
  var parts = name.split('.').filter(Boolean).map(function (l) { var b = Buffer.from(l, 'utf8'); return Buffer.concat([Buffer.from([b.length]), b]); });
  return Buffer.concat(parts.concat([Buffer.from([0])]));
}

function record(name, type, cls, ttl, data) {
  var head = Buffer.alloc(10);
  head.writeUInt16BE(type, 0); head.writeUInt16BE(cls, 2); head.writeUInt32BE(ttl, 4); head.writeUInt16BE(data.length, 8);
  return Buffer.concat([encodeName(name), head, data]);
}

function answer() {
  var ip = lanIp();
  if (!ip || !tv.id) return null;
  var instance = tv.name.replace(/\./g, ' ') + '.' + TYPE;
  var host = 'tonalo-' + tv.id.slice(0, 8) + '.local';
  var srv = Buffer.alloc(6); srv.writeUInt16BE(0, 0); srv.writeUInt16BE(0, 2); srv.writeUInt16BE(PORT, 4);
  var txt = Buffer.from('id=' + tv.id, 'utf8');
  var records = [
    record(TYPE, 12, 1, 120, encodeName(instance)),
    record(instance, 33, 0x8001, 120, Buffer.concat([srv, encodeName(host)])),
    record(instance, 16, 0x8001, 120, Buffer.concat([Buffer.from([txt.length]), txt])),
    record(host, 1, 0x8001, 120, Buffer.from(ip.split('.').map(Number)))
  ];
  var header = Buffer.alloc(12);
  header.writeUInt16BE(0x8400, 2); header.writeUInt16BE(records.length, 6);
  return Buffer.concat([header].concat(records));
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

function asksForUs(buf) {
  if (buf.length < 12 || (buf.readUInt16BE(2) & 0x8000)) return false; // nur Fragen, keine Antworten
  var count = buf.readUInt16BE(4), off = 12;
  for (var i = 0; i < count; i++) {
    var q = readName(buf, off);
    off = q.end + 4;
    if (q.name === TYPE || q.name === '_services._dns-sd._udp.local') return true;
  }
  return false;
}

function announce(to) {
  var packet = answer();
  if (packet && mdns) mdns.send(packet, 0, packet.length, to ? to.port : 5353, to ? to.address : '224.0.0.251');
}

function startMdns() {
  if (mdns) { announce(); return; }
  mdns = dgram.createSocket({ type: 'udp4', reuseAddr: true });
  mdns.on('message', function (buf, from) {
    // Fragen von einem anderen Port als 5353 wollen die Antwort direkt zurück
    if (asksForUs(buf)) announce(from.port !== 5353 ? from : null);
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
