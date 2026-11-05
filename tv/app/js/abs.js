/* Audiobookshelf: Hörbücher und Podcasts. Gehört zu einem Navidrome-Konto (wie in der iPhone-App) – die Anmeldung
   liegt im Konto, aber nur die Token, nie das Passwort.
   Anfragen gehen über den Hintergrunddienst (service.js, "http"): Audiobookshelf erlaubt fremde Web-Apps nicht, und
   der Dienst folgt keiner Weiterleitung, die Anmeldung geht also nie an einen anderen Server. */
var ABS = (function () {
  'use strict';
  var A = U.asArray;
  var CLIENT = U.desktop ? 'Tonalo Windows' : 'Tonalo TV';
  var cfg = null;          // {url, user, accessToken, refreshToken, deviceId}
  var refreshing = null;
  var progress = {};       // 'itemId' oder 'itemId/episodeId' -> {currentTime, duration, progress, isFinished, lastUpdate}
  var libs = null;
  var listeners = [];

  function on(fn) { listeners.push(fn); }
  function emit() { listeners.forEach(function (fn) { try { fn(); } catch (e) { console.error(e); } }); }

  function viaService() { return typeof PalmServiceBridge !== 'undefined'; }

  function randomId() {
    var s = '', c = '0123456789abcdef';
    for (var i = 0; i < 32; i++) s += c.charAt(Math.floor(Math.random() * 16));
    return s;
  }

  function setConfig(c) {
    cfg = c || null;
    progress = {};
    libs = null;
    clearCovers();
  }
  function connected() { return !!(cfg && cfg.accessToken); }
  function server() { return cfg ? cfg.url : ''; }
  function user() { return cfg ? cfg.user : ''; }
  function deviceId() { return cfg ? cfg.deviceId : ''; }

  // ---------- Anfrage (über den Dienst; im Browser-Test direkt)
  function raw(method, url, headers, body, o) {
    o = o || {};
    return new Promise(function (resolve, reject) {
      if (!viaService()) {
        var ctrl = typeof AbortController !== 'undefined' ? new AbortController() : null;
        var timer = setTimeout(function () { if (ctrl) ctrl.abort(); }, o.timeout || 20000);
        fetch(url, { method: method, headers: headers, body: body, signal: ctrl ? ctrl.signal : undefined, redirect: 'manual' })
          .then(function (r) {
            return (o.binary ? r.arrayBuffer() : r.text()).then(function (b) {
              clearTimeout(timer);
              if (o.binary) {
                var bytes = new Uint8Array(b), s = '';
                for (var i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
                b = btoa(s);
              }
              resolve({ status: r.status, type: r.headers.get('content-type') || '', body: b });
            });
          })
          .catch(function (e) { clearTimeout(timer); reject(new Error(e && e.name === 'AbortError' ? 'timeout' : 'network')); });
        return;
      }
      var b = new PalmServiceBridge(), done = false;
      var timer2 = setTimeout(function () { if (!done) { done = true; try { b.cancel(); } catch (e) { /* egal */ } reject(new Error('timeout')); } }, (o.timeout || 20000) + 5000);
      b.onservicecallback = function (msg) {
        if (done) return;
        done = true;
        clearTimeout(timer2);
        try { b.cancel(); } catch (e) { /* egal */ }
        var m;
        try { m = JSON.parse(msg); } catch (e) { return reject(new Error('network')); }
        if (!m.returnValue) return reject(new Error(m.errorText || 'network'));
        resolve({ status: m.status, type: m.type, body: m.body });
      };
      b.call('luna://tonalo.service/http', JSON.stringify({ url: url, method: method, headers: headers, body: body, binary: !!o.binary, slim: !!o.slim, timeout: o.timeout || 20000 }));
    });
  }

  function failure(e) {
    var msg = String((e && e.message) || e);
    if (msg === 'timeout') return new Error(T('Zeitüberschreitung – Server nicht erreichbar'));
    return new Error(T('Verbindung fehlgeschlagen: {msg}', { msg: msg }));
  }

  // Der Zugriffstoken gilt nur kurz: bei 401 einmal erneuern (mehrere Anfragen teilen sich eine Erneuerung)
  function renew() {
    if (refreshing) return refreshing;
    if (!cfg || !cfg.refreshToken) return Promise.resolve(false);
    var saved = cfg.url, mine = cfg;
    refreshing = raw('POST', cfg.url + '/auth/refresh', { 'x-refresh-token': cfg.refreshToken, 'x-return-tokens': 'true' }, null)
      .then(function (r) {
        refreshing = null;
        if (r.status !== 200 || cfg !== mine || cfg.url !== saved) return false;
        var u;
        try { u = JSON.parse(r.body).user; } catch (e) { return false; }
        if (!u || !u.accessToken) return false;
        cfg.accessToken = u.accessToken;
        cfg.refreshToken = u.refreshToken || cfg.refreshToken;
        App.saveAbs(cfg);
        return true;
      }, function () { refreshing = null; return false; });
    return refreshing;
  }

  function authHeaders(extra) {
    var h = { Authorization: 'Bearer ' + cfg.accessToken };
    if (extra) Object.keys(extra).forEach(function (k) { h[k] = extra[k]; });
    return h;
  }

  // JSON-Anfrage mit Anmeldung
  function req(path, o) {
    o = o || {};
    if (!connected()) return Promise.reject(new Error(T('Audiobookshelf ist nicht verbunden.')));
    function attempt() {
      var headers = authHeaders(o.body != null ? { 'Content-Type': 'application/json' } : null);
      return raw(o.method || 'GET', cfg.url + path, headers, o.body != null ? JSON.stringify(o.body) : null, o);
    }
    return attempt().catch(function (e) { throw failure(e); }).then(function (r) {
      if (r.status !== 401) return r;
      return renew().then(function (ok) { return ok ? attempt().catch(function (e) { throw failure(e); }) : r; });
    }).then(function (r) {
      if (r.status === 401) { var e = new Error(T('Anmeldung bei Audiobookshelf abgelaufen – bitte in den Einstellungen neu verbinden.')); e.code = 401; throw e; }
      if (r.status < 200 || r.status >= 300) { var e2 = new Error(T('Der Server antwortete mit Fehler {n}.', { n: r.status })); e2.status = r.status; throw e2; }
      if (o.binary) return r;
      if (!r.body) return null;
      try { return JSON.parse(r.body); } catch (e3) { throw new Error(T('Das sieht nicht nach einem Audiobookshelf-Server aus.')); }
    });
  }

  // ---------- Anmeldung: gibt die Verbindung zurück, gespeichert wird sie erst vom Aufrufer
  function login(url, username, password) {
    url = API.normalizeUrl(url);
    // Ohne http(s) im Eingabefeld normalisiert API: im Heimnetz http, sonst https
    return raw('POST', url + '/login', { 'Content-Type': 'application/json', 'x-return-tokens': 'true' },
      JSON.stringify({ username: username, password: password })).catch(function (e) { throw failure(e); }).then(function (r) {
      if (r.status === 401) throw new Error(T('Benutzername oder Passwort falsch.'));
      var j = null;
      try { j = JSON.parse(r.body); } catch (e) { /* unten */ }
      var u = j && j.user;
      var token = u && (u.accessToken || u.token);
      // Am PC kann ein Proxy davor sitzen (Cloudflare Access …), dort gibt es eigene Header
      if (r.status !== 200 || !token) throw new Error(U.desktop ? T('Das sieht nicht nach einem Audiobookshelf-Server aus. Liegt er hinter Cloudflare Access oder einem anderen Proxy, prüfe die eigenen Header.') : T('Das sieht nicht nach einem Audiobookshelf-Server aus.'));
      return { url: url, user: username, accessToken: token, refreshToken: u.refreshToken || null, deviceId: randomId() };
    });
  }

  function logout(c) {
    if (!c || !c.refreshToken) return;
    raw('POST', c.url + '/logout', { 'x-refresh-token': c.refreshToken, 'x-return-tokens': 'true', Authorization: 'Bearer ' + c.accessToken }, null).catch(function () { });
  }

  // ---------- Bibliothek
  function libraries() {
    if (libs) return Promise.resolve(libs);
    return req('/api/libraries').then(function (r) { libs = A(r && r.libraries); return libs; });
  }

  function noteProgress(list) {
    A(list).forEach(function (p) {
      if (!p || !p.libraryItemId) return;
      progress[p.libraryItemId + (p.episodeId ? '/' + p.episodeId : '')] = p;
    });
  }

  // Startseite: Regale aller Bibliotheken, dazu der Stand der Fortschritte
  function shelfTitle(id, label) {
    switch (id) {
      case 'continue-listening': return T('Weiterhören');
      case 'continue-series': return T('Die Serie fortsetzen');
      case 'recently-added': return T('Neu bei Hörbüchern & Podcasts');
      case 'episodes-recently-added': return T('Neue Folgen');
      case 'recommended': return T('Für dich empfohlen');
      case 'listen-again': return T('Nochmal hören');
      case 'discover': return T('Hörbücher entdecken');
    }
    return label || id;
  }

  // Nebenabfragen dürfen ausfallen, nur eine abgelaufene Anmeldung ist ein echter Fehler
  function soft(promise, fallback) { return promise.catch(function (e) { if (e && e.code === 401) throw e; return fallback; }); }

  function home() {
    return Promise.all([
      libraries(),
      soft(req('/api/me'), null)
    ]).then(function (r) {
      if (r[1]) noteProgress(r[1].mediaProgress);
      return Promise.all(r[0].map(function (lib) {
        return soft(req('/api/libraries/' + lib.id + '/personalized?limit=12&minified=1'), []);
      })).then(function (answers) {
        var shelves = [];
        answers.forEach(function (list) {
          A(list).forEach(function (sh) {
            if (['book', 'podcast', 'episode'].indexOf(sh.type) < 0) return;
            var items = A(sh.entities).filter(function (x) { return x && x.id; });
            if (!items.length) return;
            var have = shelves.filter(function (x) { return x.id === sh.id; })[0];
            if (have) have.items = have.items.concat(items);
            else shelves.push({ id: sh.id, title: shelfTitle(sh.id, sh.label), items: items });
          });
        });
        emit();
        return { libraries: r[0], shelves: shelves };
      });
    });
  }

  // Eine Seite einer Bibliothek
  function items(lib, page, size, sort, desc, filter) {
    return req('/api/libraries/' + lib + '/items?limit=' + size + '&page=' + page + '&sort=' + encodeURIComponent(sort || 'media.metadata.title') +
      '&desc=' + (desc ? 1 : 0) + '&minified=1' + (filter ? '&filter=' + encodeURIComponent(filter[0] + '.' + btoa(filter[1])) : '')).then(function (r) { return { items: A(r && r.results), total: (r && r.total) || 0 }; });
  }

  // Die Serien einer Bibliothek, jede mit ihren Büchern (das erste liefert das Cover)
  function series(lib, page, size) {
    return req('/api/libraries/' + lib + '/series?limit=' + size + '&page=' + page + '&sort=name&minified=1', { slim: true, timeout: 40000 }).then(function (r) {
      return { items: A(r && r.results), total: (r && r.total) || 0 };
    });
  }

  // Ein Autor mit seinen Büchern und Serien
  function author(id) {
    return req('/api/authors/' + encodeURIComponent(id) + '?include=items,series', { slim: true, timeout: 40000 });
  }

  function item(id) { return req('/api/items/' + encodeURIComponent(id) + '?expanded=1'); }

  function search(q) {
    return libraries().then(function (list) {
      return Promise.all(list.map(function (lib) {
        return req('/api/libraries/' + lib.id + '/search?q=' + encodeURIComponent(q) + '&limit=12', { slim: true, timeout: 40000 }).then(function (a) { return a && { lib: lib.id, a: a }; }, function () { return null; });
      }));
    }).then(function (answers) {
      // Bücher und Podcasts, dazu Serien: bei einer Serie wie „Die drei ???“ trifft der Suchbegriff oft nur den Serien-Namen
      var out = { items: [], series: [], authors: [] }, seen = {};
      answers.forEach(function (w) {
        if (!w) return;
        A(w.a.book).concat(A(w.a.podcast)).forEach(function (m) { if (m && m.libraryItem && !seen[m.libraryItem.id]) { seen[m.libraryItem.id] = 1; out.items.push(m.libraryItem); } });
        A(w.a.authors).forEach(function (m) { if (m && m.id && m.name) out.authors.push({ id: m.id, name: m.name, numBooks: m.numBooks, lib: w.lib }); });
        // Bei Serien liefert die Suche nur die Treffer, nicht alle Bücher: darum noCount
        A(w.a.series).forEach(function (m) { if (m && m.series) out.series.push({ id: m.series.id, name: m.series.name, books: A(m.books).slice(0, 1), lib: w.lib, noCount: true }); });
      });
      return out;
    });
  }

  // ---------- Fortschritt
  function key(itemId, episodeId) { return itemId + (episodeId ? '/' + episodeId : ''); }
  function progressOf(itemId, episodeId) { return progress[key(itemId, episodeId)] || null; }
  function finished(itemId, episodeId) { var p = progressOf(itemId, episodeId); return !!(p && p.isFinished); }

  // Was gerade läuft, steht sofort in den Fortschrittsbalken – der Server erfährt es über die Sitzung
  function noteListening(itemId, episodeId, currentTime, duration) {
    var k = key(itemId, episodeId);
    var p = progress[k] || { libraryItemId: itemId, episodeId: episodeId || null };
    p.currentTime = currentTime;
    p.duration = duration;
    p.progress = duration > 0 ? Math.min(1, currentTime / duration) : 0;
    p.isFinished = duration > 0 && currentTime >= duration - 5;
    p.lastUpdate = Date.now();
    progress[k] = p;
  }

  function setFinished(itemId, episodeId, on) {
    return req('/api/me/progress/' + itemId + (episodeId ? '/' + episodeId : ''), { method: 'PATCH', body: { isFinished: !!on } }).then(function () {
      var p = progressOf(itemId, episodeId) || { libraryItemId: itemId, episodeId: episodeId || null };
      p.isFinished = !!on;
      if (!on) { p.progress = 0; p.currentTime = 0; }
      progress[key(itemId, episodeId)] = p;
      emit();
    });
  }

  // ---------- Hörsitzungen
  function startSession(itemId, episodeId) {
    return req('/api/items/' + itemId + '/play' + (episodeId ? '/' + episodeId : ''), {
      method: 'POST',
      body: {
        forceDirectPlay: true, forceTranscode: false, mediaPlayer: 'tonalo',
        supportedMimeTypes: ['audio/mpeg', 'audio/mp4', 'audio/aac', 'audio/flac', 'audio/x-aiff'],
        deviceInfo: { clientName: CLIENT, deviceId: cfg.deviceId }
      }
    });
  }

  function syncSession(id, currentTime, listened, duration, close) {
    return req('/api/session/' + id + (close ? '/close' : '/sync'), {
      method: 'POST', timeout: 10000, body: { currentTime: currentTime, timeListened: listened, duration: duration }
    });
  }

  // Ohne Sitzung (z. B. wenn der Server sie vergessen hat): nur die Position melden
  function saveProgress(itemId, episodeId, currentTime, duration) {
    return req('/api/me/progress/' + itemId + (episodeId ? '/' + episodeId : ''), {
      method: 'PATCH', timeout: 10000,
      body: { currentTime: currentTime, duration: duration, progress: duration > 0 ? Math.min(1, currentTime / duration) : 0, isFinished: duration > 0 && currentTime >= duration - 5 }
    });
  }

  // Der Server schickt die Datei einer Sitzung ohne Anmeldung aus – die Sitzungsnummer ist die Berechtigung
  function trackUrl(sessionId, index) { return cfg.url + '/public/session/' + sessionId + '/track/' + index; }

  // ---------- Cover: brauchen die Anmeldung, also über den Dienst geholt und als Bild-Daten eingesetzt
  var covers = {}, coverOrder = [], queue = [], busy = 0, jobs = {};
  var MAX_COVERS = 120;
  function clearCovers() { covers = {}; coverOrder = []; queue = []; jobs = {}; }

  function pump() {
    while (busy < 4 && queue.length) {
      (function (job) {
        busy++;
        req((job.kind === 'author' ? '/api/authors/' : '/api/items/') + encodeURIComponent(job.id) + (job.kind === 'author' ? '/image?width=' : '/cover?width=') + job.width + '&format=jpeg', { binary: true, timeout: 20000 })
          .then(function (r) {
            if (!/^image\//.test(r.type || 'image/jpeg')) throw new Error('type');
            return 'data:' + (r.type || 'image/jpeg').split(';')[0] + ';base64,' + r.body;
          })
          .then(function (url) {
            covers[job.k] = url;
            coverOrder.push(job.k);
            if (coverOrder.length > MAX_COVERS) delete covers[coverOrder.shift()];
            job.done.forEach(function (d) { d.resolve(url); });
          }, function (e) { job.done.forEach(function (d) { d.reject(e); }); })
          .then(function () { delete jobs[job.k]; busy--; pump(); });
      })(queue.shift());
    }
  }

  function cover(id, width, kind) {
    width = width || 400;
    var k = (kind ? kind + ':' : '') + id + '@' + width;
    if (covers[k]) return Promise.resolve(covers[k]);
    return new Promise(function (resolve, reject) {
      var job = jobs[k];
      if (!job) { job = jobs[k] = { k: k, id: id, width: width, kind: kind || '', done: [] }; queue.push(job); }
      job.done.push({ resolve: resolve, reject: reject });
      pump();
    });
  }

  return {
    on: on, emit: emit, setConfig: setConfig, connected: connected, server: server, user: user, deviceId: deviceId,
    config: function () { return cfg; },
    // Nummern der Bibliotheken (nur Zahlen, ohne Namen): daran erkennt das iPhone, dass es derselbe Server ist, auch unter anderer Adresse
    libraryIds: function () { return (libs || []).map(function (l) { return l.id; }).slice(0, 8); },
    login: login, logout: logout, libraries: libraries, home: home, items: items, series: series, author: author, item: item, search: search,
    progressOf: progressOf, finished: finished, noteListening: noteListening, noteProgress: noteProgress, setFinished: setFinished,
    startSession: startSession, syncSession: syncSession, saveProgress: saveProgress, trackUrl: trackUrl, cover: cover,
    req: req, shelfTitle: shelfTitle
  };
})();
