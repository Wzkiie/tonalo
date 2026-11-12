// Fernbedienung am PC/Mac: Fernseher (und andere Computer) im Heimnetz finden, einmal mit Code koppeln und sehen,
// was dort läuft, und es steuern – so wie es das iPhone kann. Der Gegenpart ist der Dienst (tv/service/service.js),
// der dieselbe Kopplung, Signatur und Befehle auch für iPhones nutzt: hier wird nur die Sender-Seite nachgebaut.
//
// Läuft im Hauptprozess. Die Schlüssel aus der Kopplung verlassen ihn nie: die Oberfläche sieht nur Namen, Stand
// und schickt „Befehl X an Gerät Y“. Gespeichert werden sie je Konto, verschlüsselt (Windows: DPAPI, macOS: Schlüsselbund).
'use strict';
const http = require('http');
const dgram = require('dgram');
const crypto = require('crypto');
const os = require('os');

const TYPE = '_tonalo._tcp.local';
const DEFAULT_PORT = 47913;

// Nur Adressen im Heimnetz: ein signierter Befehl geht nie ins Internet
function isLocal(addr) {
  const a = String(addr || '').toLowerCase().replace(/^::ffff:/, '');
  const m = /^(\d+)\.(\d+)\.\d+\.\d+$/.exec(a);
  if (m) {
    const x = +m[1], y = +m[2];
    return x === 10 || x === 127 || (x === 192 && y === 168) || (x === 172 && y >= 16 && y < 32) || (x === 169 && y === 254);
  }
  return a === '::1' || /^f[cd]/.test(a) || /^fe[89ab]/.test(a);
}

// ---------- Suchen (mDNS): eine Frage nach _tonalo._tcp, die Antworten kommen direkt zurück
function encodeName(name) {
  return Buffer.concat(name.split('.').filter(Boolean).map((l) => {
    const b = Buffer.from(l, 'utf8');
    return Buffer.concat([Buffer.from([b.length]), b]);
  }).concat([Buffer.from([0])]));
}

function question() {
  const head = Buffer.alloc(12);
  head.writeUInt16BE(1, 4); // eine Frage
  const tail = Buffer.alloc(4);
  tail.writeUInt16BE(12, 0); tail.writeUInt16BE(1, 2); // PTR, IN
  return Buffer.concat([head, encodeName(TYPE), tail]);
}

function readName(buf, off) {
  const labels = [];
  let jumped = false, end = off, guard = 0;
  while (off < buf.length && guard++ < 64) {
    const len = buf[off];
    if (len === 0) { if (!jumped) end = off + 1; break; }
    if ((len & 0xc0) === 0xc0) { if (!jumped) end = off + 2; off = ((len & 0x3f) << 8) | buf[off + 1]; jumped = true; continue; }
    labels.push(buf.toString('utf8', off + 1, off + 1 + len));
    off += len + 1;
  }
  return { name: labels.join('.'), end };
}

// Liefert { ptr: [Instanz], srv: {Instanz: {port, host}}, txt: {Instanz: {id, kind}}, a: {Host: ip} }
function parseAnswer(buf) {
  const out = { ptr: [], srv: {}, txt: {}, a: {} };
  if (buf.length < 12 || !(buf.readUInt16BE(2) & 0x8000)) return out; // nur Antworten
  let off = 12;
  const questions = buf.readUInt16BE(4);
  const records = buf.readUInt16BE(6) + buf.readUInt16BE(8) + buf.readUInt16BE(10);
  try {
    for (let i = 0; i < questions; i++) off = readName(buf, off).end + 4;
    for (let i = 0; i < records && off + 10 <= buf.length; i++) {
      const n = readName(buf, off);
      off = n.end;
      const type = buf.readUInt16BE(off), len = buf.readUInt16BE(off + 8), data = off + 10;
      off = data + len;
      if (off > buf.length) break;
      const key = n.name.toLowerCase();
      if (type === 12 && key === TYPE) out.ptr.push(readName(buf, data).name);
      else if (type === 33) out.srv[n.name] = { port: buf.readUInt16BE(data + 4), host: readName(buf, data + 6).name.toLowerCase() };
      else if (type === 16) {
        const txt = {};
        for (let p = data; p < data + len;) {
          const l = buf[p];
          const kv = buf.toString('utf8', p + 1, p + 1 + l).split('=');
          if (kv.length >= 2) txt[kv[0]] = kv.slice(1).join('=');
          p += l + 1;
        }
        out.txt[n.name] = txt;
      } else if (type === 1 && len === 4) out.a[key] = Array.from(buf.slice(data, data + 4)).join('.');
    }
  } catch (e) { /* halbe Antwort: was bis hier gelesen ist, reicht */ }
  return out;
}

function lanAddrs() {
  const out = [];
  const all = os.networkInterfaces();
  Object.keys(all).forEach((n) => all[n].forEach((a) => {
    if (a.family === 'IPv4' && !a.internal && !/^169\.254\./.test(a.address)) out.push(a.address);
  }));
  return out;
}

module.exports = function setupRemote(Service, store, opts) {
  opts = opts || {};
  const deviceName = opts.deviceName || os.hostname().replace(/\.local$/, '');
  const mdnsPort = opts.mdnsPort || 5353; // nur für Tests ein anderer
  const mdnsGroup = opts.mdnsGroup || '224.0.0.251';

  // ----- gespeicherte Kopplungen: { [Konto]: { [Gerät]: { name, kind, keyId, key, ip, port } } }
  let saved = null;
  function load() { if (!saved) { try { saved = store.get() || {}; } catch (e) { saved = {}; } } return saved; }
  function persist() { try { store.set(saved); } catch (e) { /* bleibt im Speicher */ } }
  function paired(account) { return (load()[account] = load()[account] || {}); }

  // ----- gefundene Geräte
  let found = {};        // Gerät-ID -> { id, name, kind, ip, port, seen }
  let browsing = [];     // offene Abos der Oberfläche
  let socket = null, ticker = null, selfIds = {};

  function summary(account) {
    const mine = paired(account);
    const list = {};
    Object.keys(found).forEach((id) => {
      if (selfIds[id]) return;
      const d = found[id];
      list[id] = { id, name: d.name, kind: d.kind, paired: !!mine[id], here: true };
    });
    // Gekoppelte, die gerade niemand sieht, bleiben in der Liste (aus, oder in einem anderen Netz)
    Object.keys(mine).forEach((id) => { if (!list[id]) list[id] = { id, name: mine[id].name, kind: mine[id].kind, paired: true, here: false }; });
    return Object.keys(list).map((id) => list[id]).sort((a, b) => (b.paired - a.paired) || a.name.localeCompare(b.name));
  }

  function notifyBrowsers() {
    browsing.forEach((b) => b.respond({ returnValue: true, devices: summary(b.payload.account || '') }));
  }

  function onPacket(buf, from) {
    if (!isLocal(from.address)) return;
    const r = parseAnswer(buf);
    let changed = false;
    r.ptr.forEach((instance) => {
      const srv = r.srv[instance], txt = r.txt[instance];
      if (!srv || !txt || !txt.id) return;
      const ip = r.a[srv.host] || from.address;
      if (!isLocal(ip)) return;
      const name = instance.slice(0, instance.length - TYPE.length - 1);
      const old = found[txt.id];
      const next = { id: txt.id, name, kind: txt.kind === 'pc' ? 'pc' : txt.kind === 'phone' ? 'phone' : 'tv', ip, port: srv.port, seen: Date.now() };
      if (!old || old.ip !== ip || old.port !== srv.port || old.name !== name) changed = true;
      found[txt.id] = next;
      // Die Adresse merken: beim nächsten Mal geht es auch, wenn die Suche gerade nichts findet
      Object.keys(load()).forEach((acc) => {
        const p = saved[acc][txt.id];
        if (p && (p.ip !== ip || p.port !== srv.port)) { p.ip = ip; p.port = srv.port; persist(); }
      });
    });
    if (changed) notifyBrowsers();
  }

  function ask() {
    if (!socket) return;
    const q = question();
    const mine = socket;
    // In jedes Netz fragen: ein PC hat oft mehrere, und nur in einem davon steht der Fernseher. Nacheinander, denn
    // die Netzwahl gilt für den Moment des Sendens – ein zweites setMulticastInterface davor würde das erste überholen.
    const queue = lanAddrs();
    if (!queue.length) queue.push(null);
    (function next() {
      if (socket !== mine || !queue.length) return;
      const a = queue.shift();
      try {
        if (a) mine.setMulticastInterface(a);
        mine.send(q, 0, q.length, mdnsPort, mdnsGroup, next);
      } catch (e) { next(); /* dieses Netz nicht */ }
    })();
  }

  function startBrowse() {
    if (socket) { ask(); return; }
    socket = dgram.createSocket({ type: 'udp4', reuseAddr: true });
    const mine = socket;
    socket.on('message', onPacket);
    socket.on('error', () => { try { mine.close(); } catch (e) { /* egal */ } if (socket === mine) socket = null; });
    // Ein freier Port, nicht 5353: die Antworten kommen dann direkt zu uns, ohne dass wir im Netz mithören müssen
    socket.bind(0, () => {
      try { socket.setMulticastTTL(255); } catch (e) { /* egal */ }
      ask();
      clearInterval(ticker);
      let n = 0;
      // Anfangs öfter fragen (Pakete gehen verloren), danach nur noch gelegentlich, solange die Liste offen ist
      ticker = setInterval(() => {
        // Wer sich länger als zwei Minuten nicht gemeldet hat, ist weg
        Object.keys(found).forEach((id) => { if (Date.now() - found[id].seen > 150000) { delete found[id]; notifyBrowsers(); } });
        if (++n < 3 || n % 6 === 0) ask();
      }, 2000);
    });
  }

  function stopBrowse() {
    clearInterval(ticker);
    ticker = null;
    if (socket) { try { socket.close(); } catch (e) { /* egal */ } socket = null; }
  }

  // ----- Anfragen an ein Gerät (signiert wie beim iPhone)
  const clockOffset = {};

  function sign(method, path, body, entry, offset) {
    const time = String(Math.floor(Date.now() / 1000 + (offset || 0)));
    const nonce = crypto.randomBytes(8).toString('hex');
    const mac = crypto.createHmac('sha256', Buffer.from(entry.key, 'hex'))
      .update(method + '\n' + path + '\n' + time + '\n' + nonce + '\n' + body).digest('hex');
    return 'Tonalo ' + entry.keyId + ':' + time + ':' + nonce + ':' + mac;
  }

  function endpoint(id, entry) {
    const f = found[id];
    if (f) return { ip: f.ip, port: f.port };
    return entry && entry.ip ? { ip: entry.ip, port: entry.port || DEFAULT_PORT } : null;
  }

  // Eine Anfrage: { status, body } oder null, wenn nichts antwortet
  function request(ep, method, path, body, headers, timeout) {
    return new Promise((resolve) => {
      if (!ep || !isLocal(ep.ip)) { resolve(null); return; }
      const data = Buffer.from(body || '', 'utf8');
      const req = http.request({ host: ep.ip, port: ep.port, method, path, timeout: timeout || 6000,
        headers: Object.assign({ 'Content-Type': 'application/json', 'Content-Length': data.length }, headers || {}) }, (res) => {
        const chunks = [];
        res.on('data', (c) => { if (chunks.length < 500) chunks.push(c); });
        res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
        res.on('error', () => resolve(null));
      });
      req.on('timeout', () => { req.destroy(); resolve(null); });
      req.on('error', () => resolve(null));
      req.end(data);
    });
  }

  // Signiert, und einmal wiederholt, wenn nur die Uhr des anderen Geräts abweicht
  async function signed(account, id, method, path, body) {
    const entry = paired(account)[id];
    if (!entry) return { status: 401, body: '{"error":"not paired"}' };
    let answer = null;
    for (let i = 0; i < 2; i++) {
      const auth = sign(method, path, body || '', entry, clockOffset[id] || 0);
      answer = await request(endpoint(id, entry), method, path, body, { Authorization: auth });
      if (!answer || answer.status !== 401) break;
      let parsed = {};
      try { parsed = JSON.parse(answer.body); } catch (e) { /* egal */ }
      if (parsed.error !== 'clock' || typeof parsed.now !== 'number') break;
      clockOffset[id] = parsed.now - Date.now() / 1000;
    }
    return answer;
  }

  // ----- Kopplung: das Gerät zeigt einen Code, hier wird er eingegeben
  // Dieselbe Tabelle, aus der main.js die Anfragen der Oberfläche beantwortet (wie beim Dienst fürs iPhone)
  const reg = (name, fn, cancel) => { Service.handlers[name] = { fn, cancel }; };

  // Welche Geräte gibt es? Solange die Liste offen ist, wird im Netz gesucht
  reg('remoteDevices', (msg) => {
    const p = msg.payload || {};
    if (p.self) selfIds[String(p.self)] = true;
    browsing.push(msg);
    startBrowse();
    msg.respond({ returnValue: true, devices: summary(p.account || '') });
  }, (msg) => {
    browsing = browsing.filter((b) => b !== msg);
    if (!browsing.length) stopBrowse();
  });

  // Schritt 1: das Gerät zeigt den Code an. Schritt 2: der Code geht (nur als Nachweis) zurück, beide errechnen denselben Schlüssel
  reg('remotePair', async (msg) => {
    const p = msg.payload || {};
    const id = String(p.id || ''), account = String(p.account || '');
    const f = found[id];
    if (!f || !account) { msg.respond({ returnValue: true, result: 'gone' }); return; }
    const ep = { ip: f.ip, port: f.port };
    if (p.step === 'start') {
      const a = await request(ep, 'POST', '/pair/start', JSON.stringify({ guest: false, device: deviceName, via: 'pc' }));
      // 503: dort ist noch kein Konto gewählt; 429: zu viele Versuche
      msg.respond({ returnValue: true, result: !a ? 'gone' : a.status === 200 ? 'ok' : a.status === 503 ? 'not ready' : a.status === 429 ? 'expired' : 'failed' });
      return;
    }
    const code = String(p.code || '').replace(/\D/g, '');
    if (code.length !== 6) { msg.respond({ returnValue: true, result: 'wrong code' }); return; }
    const mine = crypto.createECDH('prime256v1');
    mine.generateKeys();
    const pub = mine.getPublicKey();
    const proof = crypto.createHmac('sha256', code).update(pub).digest('hex');
    const a = await request(ep, 'POST', '/pair/finish', JSON.stringify({ device: deviceName, uid: opts.installId || '', guest: false, pub: pub.toString('hex'), proof }));
    if (!a) { msg.respond({ returnValue: true, result: 'gone' }); return; }
    if (a.status === 403) { msg.respond({ returnValue: true, result: 'wrong code' }); return; }
    if (a.status === 410 || a.status === 429) { msg.respond({ returnValue: true, result: 'expired' }); return; }
    if (a.status !== 200) { msg.respond({ returnValue: true, result: 'failed' }); return; }
    try {
      const r = JSON.parse(a.body);
      const secret = mine.computeSecret(Buffer.from(r.pub, 'hex'));
      const key = crypto.createHmac('sha256', secret).update('tonalo-pair\n' + code).digest('hex');
      // Dieselbe Kennung wie im Dienst: ist das Gerät schon gekoppelt, ersetzt die neue Kopplung die alte
      paired(account)[id] = { name: f.name, kind: f.kind, keyId: String(r.id), key, ip: f.ip, port: f.port };
      persist();
      msg.respond({ returnValue: true, result: 'ok', device: { id, name: f.name, kind: f.kind } });
      notifyBrowsers();
    } catch (e) { msg.respond({ returnValue: true, result: 'failed' }); }
  });

  reg('remoteForget', (msg) => {
    const p = msg.payload || {};
    const mine = paired(String(p.account || ''));
    delete mine[String(p.id || '')];
    persist();
    notifyBrowsers();
    msg.respond({ returnValue: true });
  });

  // ----- Live: was läuft dort? Ein offener Strom von Ständen, bis die Oberfläche aufhört oder das Gerät weg ist
  const streams = new Map(); // msg -> { req, stop }
  reg('remoteWatch', (msg) => {
    const p = msg.payload || {};
    const id = String(p.id || ''), account = String(p.account || '');
    let stopped = false, req = null, misses = 0, retry = null;
    const stop = () => { stopped = true; clearTimeout(retry); if (req) { try { req.destroy(); } catch (e) { /* egal */ } } };
    streams.set(msg, { stop });

    function open() {
      if (stopped) return;
      const entry = paired(account)[id];
      if (!entry) { msg.respond({ returnValue: true, lost: 'not paired' }); return; }
      const ep = endpoint(id, entry);
      if (!ep || !isLocal(ep.ip)) { gone(); return; }
      const auth = sign('GET', '/events', '', entry, clockOffset[id] || 0);
      let got = false;
      req = http.request({ host: ep.ip, port: ep.port, method: 'GET', path: '/events', headers: { Authorization: auth, Accept: 'text/event-stream' } }, (res) => {
        if (res.statusCode === 401) {
          // Nur die Uhr? Dann merken und gleich noch einmal. Sonst kennt das Gerät uns nicht mehr.
          let text = '';
          res.on('data', (c) => { text += c; });
          res.on('end', () => {
            let parsed = {};
            try { parsed = JSON.parse(text); } catch (e) { /* egal */ }
            if (parsed.error === 'clock' && typeof parsed.now === 'number') { clockOffset[id] = parsed.now - Date.now() / 1000; open(); return; }
            // Die Kopplung gilt dort nicht mehr (getrennt): hier auch vergessen
            delete paired(account)[id]; persist();
            msg.respond({ returnValue: true, lost: 'not paired' });
            notifyBrowsers();
          });
          return;
        }
        if (res.statusCode !== 200) { res.resume(); gone(); return; }
        misses = 0;
        let buf = '';
        res.setEncoding('utf8');
        res.on('data', (chunk) => {
          buf += chunk;
          if (buf.length > 4000000) { req.destroy(); return; }
          let i;
          while ((i = buf.indexOf('\n\n')) >= 0) {
            const block = buf.slice(0, i); buf = buf.slice(i + 2);
            if (!block.startsWith('data: ')) continue; // „: ping“
            try { got = true; msg.respond({ returnValue: true, state: JSON.parse(block.slice(6)), received: Date.now() }); } catch (e) { /* halber Block */ }
          }
        });
        res.on('end', () => gone());
        res.on('error', () => gone());
      });
      req.on('error', () => gone());
      req.setTimeout(45000, () => req.destroy()); // alle 20 s kommt ein Ping: bleibt er aus, ist die Verbindung tot
      req.end();
    }

    // Verbindung weg: ein paar Versuche (Gerät startet neu, WLAN wackelt), dann gilt es als nicht erreichbar
    function gone() {
      if (stopped) return;
      if (++misses >= 3) { msg.respond({ returnValue: true, lost: 'gone' }); return; }
      retry = setTimeout(open, 2000);
    }
    open();
  }, (msg) => {
    const s = streams.get(msg);
    if (s) { s.stop(); streams.delete(msg); }
  });

  // ----- Befehle: { cmd: 'play-pause', playing: true } usw. – dieselben wie vom iPhone
  const ALLOWED = ['toggle', 'play-pause', 'next', 'prev', 'seek', 'jump', 'shuffle', 'repeat', 'play', 'playNext', 'enqueue', 'star'];
  reg('remoteSend', async (msg) => {
    const p = msg.payload || {};
    const cmd = p.cmd && typeof p.cmd === 'object' ? p.cmd : null;
    if (!cmd || ALLOWED.indexOf(cmd.cmd) < 0) { msg.respond({ returnValue: true, ok: false, error: 'bad command' }); return; }
    const a = await signed(String(p.account || ''), String(p.id || ''), 'POST', '/command', JSON.stringify(cmd));
    msg.respond({ returnValue: true, ok: !!a && a.status === 200, status: a ? a.status : 0 });
  });

  return { stop() { stopBrowse(); streams.forEach((s) => s.stop()); streams.clear(); } };
};
