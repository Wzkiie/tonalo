/* Tonalo für Windows: was die App am PC anders macht als am TV – Maus, Tastatur, Lautstärke, Medientasten
   und Updates. Am TV gibt es TonaloNative nicht, dann tut diese Datei nichts. */
var Desktop = (function () {
  'use strict';
  if (!U.desktop) return null;
  var N = window.TonaloNative;
  var h = U.h, root = document.documentElement;
  root.classList.add('desktop');

  // ---------------- Dienst fürs iPhone: dieselbe Schnittstelle wie auf webOS, nur über Electron
  var bridges = {}, seq = 0;
  window.PalmServiceBridge = function () { this.id = ++seq; this.onservicecallback = null; };
  window.PalmServiceBridge.prototype.call = function (uri, params) { bridges[this.id] = this; N.service.call(this.id, uri, params); };
  window.PalmServiceBridge.prototype.cancel = function () { delete bridges[this.id]; N.service.cancel(this.id); };
  N.service.onMessage(function (id, msg) { var b = bridges[id]; if (b && b.onservicecallback) b.onservicecallback(msg); });

  // ---------------- Maus und Tastatur
  // Mit der Maus kein weißer Fokusring, mit den Pfeiltasten schon
  document.addEventListener('mousemove', function () { root.classList.add('mouse'); }, true);
  document.addEventListener('keydown', function () { root.classList.remove('mouse'); }, true);

  function mainOpen() { return !U.$('#main').classList.contains('hidden') && !UI.modalOpen(); }
  function typing() { var a = document.activeElement; return !!a && (a.tagName === 'INPUT' || a.tagName === 'TEXTAREA'); }

  Nav.onKey(function (e, code) {
    if (code === 32 && !typing() && mainOpen()) { if (App.bookMode()) Book.toggle(); else Player.toggle(); return true; }
    if (!(e.ctrlKey || e.metaKey) || !mainOpen()) return false;
    if (code === 70) { App.go('search', null, { root: true }); return true; }
    // Bei einem Hörbuch springen die Pfeile: Kapitel statt Song
    if (code === Nav.KEY.RIGHT && !typing()) { if (App.bookMode()) Book.nextChapter(); else Player.next(); return true; }
    if (code === Nav.KEY.LEFT && !typing()) { if (App.bookMode()) Book.prevChapter(); else Player.prev(); return true; }
    return false;
  });

  // Rechtsklick = Optionen (am TV die gelbe Taste)
  document.addEventListener('contextmenu', function (e) {
    e.preventDefault();
    var el = e.target.closest && e.target.closest('.focusable');
    if (!el || typing()) return;
    Nav.focus(el, { noScroll: true, noInputFocus: true });
    el.dispatchEvent(new CustomEvent('options', { bubbles: true }));
  });

  // Zurück-Taste der Maus
  document.addEventListener('mouseup', function (e) { if (e.button === 3) { e.preventDefault(); App.back(); } });

  // Klick in den Fortschrittsbalken springt dorthin
  document.addEventListener('click', function (e) {
    var bar = e.target.closest && e.target.closest('.mp-progress, .np-progress');
    var book = App.bookMode();
    if (!bar || (book ? !Book.duration() : (Player.station() || !Player.duration()))) return;
    e.preventDefault(); e.stopPropagation();
    var r = (U.$('.np-bar', bar) || bar).getBoundingClientRect();
    var f = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width));
    if (book) Book.seek(f * Book.duration()); else Player.seek(f * Player.duration());
  }, true);

  // ---------------- Lautstärke: im Mini-Player und in der Vollbildansicht (dort ist der Mini-Player weg)
  var volumeSyncs = [], lastVolume = Player.volume() || 1;
  Player.on('volume', function () {
    volumeSyncs = volumeSyncs.filter(function (v) { return v.box === mini || document.body.contains(v.box); });
    volumeSyncs.forEach(function (v) { v.sync(); });
  });
  var mini = null;

  function volumeControl(big) {
    var btn = big ? h('button.icon-btn.focusable', { title: T('Lautstärke') }) : h('button.mp-btn.focusable.nav-fallback', { title: T('Lautstärke') });
    var range = h('input.mp-volume', { type: 'range', min: 0, max: 100, step: 1 });
    function sync() {
      var v = Player.volume();
      range.value = Math.round(v * 100);
      range.style.setProperty('--fill', Math.round(v * 100) + '%');
      btn.innerHTML = Icon.svg(v ? 'volume' : 'mute');
    }
    btn.addEventListener('click', function () {
      if (Player.volume()) { lastVolume = Player.volume(); Player.setVolume(0); } else Player.setVolume(lastVolume || 1);
    });
    range.addEventListener('input', function () { Player.setVolume(range.value / 100); });
    var box = h('div.mp-volbox' + (big ? '.np-volume' : ''), null, btn, range);
    box.addEventListener('wheel', function (e) {
      e.preventDefault();
      Player.setVolume(Player.volume() + (e.deltaY < 0 ? 0.05 : -0.05));
    }, { passive: false });
    volumeSyncs.push({ box: box, sync: sync });
    sync();
    return box;
  }

  // ---------------- Medientasten und Windows-Medienanzeige
  var ms = navigator.mediaSession;
  function media() {
    if (App.bookMode()) {
      document.title = Book.title() ? Book.title() + ' · Tonalo' : 'Tonalo';
      if (!ms) return;
      var bid = Book.itemId();
      ms.metadata = new MediaMetadata({ title: Book.title(), artist: Book.author(), album: T('Hörbuch'), artwork: [] });
      if (bid) ABS.cover(bid, 512).then(function (url) { if (Book.itemId() === bid) ms.metadata = new MediaMetadata({ title: Book.title(), artist: Book.author(), album: T('Hörbuch'), artwork: [{ src: url, sizes: '512x512' }] }); }).catch(function () { });
      return;
    }
    var s = Player.current(), st = Player.station();
    document.title = st ? st.name + ' · Tonalo' : s ? s.title + (s.artist ? ' · ' + s.artist : '') : 'Tonalo';
    if (!ms) return;
    if (!s && !st) { ms.metadata = null; return; }
    var art = s ? API.cover(s.coverArt || s.albumId, 512) : '';
    ms.metadata = new MediaMetadata({
      title: st ? st.name : s.title || '',
      artist: st ? T('Radio') : s.artist || '',
      album: st ? '' : s.album || '',
      artwork: art ? [{ src: art, sizes: '512x512' }] : []
    });
  }
  function mediaState() {
    if (!ms) return;
    if (App.bookMode()) { ms.playbackState = Book.playing() ? 'playing' : 'paused'; return; }
    ms.playbackState = Player.current() || Player.station() ? (Player.paused() ? 'paused' : 'playing') : 'none';
  }
  if (ms) {
    ms.setActionHandler('play', function () { if (App.bookMode()) Book.play(); else Player.play(); });
    ms.setActionHandler('pause', function () { if (App.bookMode()) Book.pause(); else Player.pause(); });
    ms.setActionHandler('stop', function () { if (App.bookMode()) Book.pause(); else Player.pause(); });
    ms.setActionHandler('previoustrack', function () { if (App.bookMode()) Book.prevChapter(); else Player.prev(); });
    ms.setActionHandler('nexttrack', function () { if (App.bookMode()) Book.nextChapter(); else Player.next(); });
    ms.setActionHandler('seekto', function (d) { if (App.bookMode()) Book.seek(d.seekTime || 0); else if (!Player.station()) Player.seek(d.seekTime || 0); });
    ms.setActionHandler('seekbackward', function () { if (App.bookMode()) Book.skipBack(); });
    ms.setActionHandler('seekforward', function () { if (App.bookMode()) Book.skipForward(); });
  }

  // ---------------- Updates: kommen als neues Release auf GitHub, geladen und installiert wird in der App
  var upd = { state: 'idle' };
  var settingRow = null, offered = {}, wantInstall = false;

  function statusText() {
    switch (upd.state) {
      case 'checking': return T('Suche nach Updates …');
      case 'none': return T('Tonalo ist aktuell');
      case 'available': return T('Tonalo {version} ist da', { version: upd.version });
      case 'downloading': return T('Update wird geladen … {n} %', { n: Math.round(upd.percent || 0) });
      case 'ready': return T('Das Update wird geladen, danach startet Tonalo neu.');
      case 'error': return T('Fehler: {msg}', { msg: upd.error || '?' });
      default: return 'v' + APP_VERSION;
    }
  }

  function install() { wantInstall = true; N.updates.download(); }

  function offer() {
    if (offered[upd.version] || UI.modalOpen()) return;
    offered[upd.version] = true;
    UI.modal(null, [
      { icon: 'play', label: T('Jetzt installieren'), action: install },
      { icon: 'close', label: T('Später') }
    ], { head: { title: T('Tonalo {version} ist da', { version: upd.version }), sub: T('Das Update wird geladen, danach startet Tonalo neu.') } });
  }

  N.updates.onStatus(function (s) {
    upd = s || { state: 'idle' };
    if (upd.state === 'available' && !wantInstall) offer();
    if (upd.state === 'downloading') U.toast(statusText(), 4000);
    if (upd.state === 'ready' && wantInstall) N.updates.install();
    if (upd.state === 'error') wantInstall = false;
    if (settingRow && document.body.contains(settingRow)) fillSetting();
  });

  function fillSetting() {
    var label = U.$('.setting-label', settingRow), actions = U.$('.nav-container', settingRow);
    label.textContent = statusText();
    actions.innerHTML = '';
    var busy = upd.state === 'checking' || upd.state === 'downloading' || upd.state === 'ready';
    if (upd.state === 'available') actions.appendChild(UI.button(T('Jetzt installieren'), install, 'primary', 'play'));
    else if (!busy) actions.appendChild(UI.button(T('Nach Updates suchen'), function () { N.updates.check(); }, 'outline', 'refresh'));
  }

  function updateSetting() {
    var frag = document.createDocumentFragment();
    frag.appendChild(h('div.settings-section', { text: T('Updates') }));
    settingRow = h('div.setting', null,
      h('div', null, h('div.setting-label'), h('div.setting-desc', { text: T('Updates kommen direkt von GitHub und werden in der App installiert.') })),
      h('div.nav-container'));
    fillSetting();
    frag.appendChild(settingRow);
    return frag;
  }

  // ---------------- Eigene Header bei der Anmeldung (Cloudflare Access …). Die Werte kennt nur der Hauptprozess.
  var hdrBox = null, hdrRows = null;

  function headerRow(name, stored) {
    var nameIn = h('input.focusable.hdr-name', { type: 'text', placeholder: T('Name'), autocomplete: 'off', spellcheck: 'false' });
    var valueIn = h('input.focusable.hdr-value', { type: 'password', autocomplete: 'off', placeholder: stored ? T('Gespeichert') : T('Wert') });
    nameIn.value = name || '';
    var del = h('button.icon-btn.focusable', { title: T('Header entfernen') }, Icon.el('close'));
    var row = h('div.hdr-row', null, nameIn, valueIn, del);
    del.addEventListener('click', function () { row.remove(); Nav.focus(U.$('#btn-hdr-add')); });
    hdrRows.appendChild(row);
    return nameIn;
  }

  function fillHeaders(url) {
    hdrRows.innerHTML = '';
    if (!url) return Promise.resolve();
    return N.headers.names(API.normalizeUrl(url)).then(function (names) {
      hdrRows.innerHTML = '';
      names.forEach(function (n) { headerRow(n, true); });
      if (names.length) hdrBox.classList.remove('hidden');
    });
  }

  function typedValue() { return U.$$('.hdr-value', hdrRows).some(function (v) { return v.value; }); }

  function buildHeaders() {
    hdrRows = h('div#hdr-rows');
    hdrBox = h('div#hdr-box.hidden', null,
      hdrRows,
      h('div.hdr-actions', null,
        h('button#btn-hdr-add.btn.outline.focusable', { text: T('Header hinzufügen'), onclick: function () { Nav.focus(headerRow(''), { noInputFocus: true }); } }),
        h('button#btn-hdr-cf.btn.outline.focusable', { text: T('Cloudflare-Access-Header'), onclick: function () {
          var have = U.$$('.hdr-name', hdrRows).map(function (n) { return n.value.toLowerCase(); }), first = null;
          ['CF-Access-Client-Id', 'CF-Access-Client-Secret'].forEach(function (n) {
            if (have.indexOf(n.toLowerCase()) < 0) { var el = headerRow(n); first = first || el; }
          });
          if (first) Nav.focus(first.parentNode.querySelector('.hdr-value'), { noInputFocus: true });
        } })),
      h('p.hdr-hint.muted', { text: T('Wird bei jeder Anfrage an diesen Server mitgeschickt, auch für Musik und Cover. Für Cloudflare Access: in Zero Trust ein Service-Token anlegen und Client-ID und Client-Secret eintragen. Die Werte liegen verschlüsselt auf diesem PC.') }));
    var toggle = h('button#btn-hdr.btn.outline.focusable', { text: T('Eigene Header'), onclick: function () { hdrBox.classList.toggle('hidden'); } });
    var login = U.$('#btn-login');
    login.parentNode.insertBefore(toggle, login);
    login.parentNode.insertBefore(hdrBox, login);
    // Andere Adresse: deren gespeicherte Header zeigen – aber nichts wegwerfen, was gerade eingetippt wurde
    U.$('#in-url').addEventListener('change', function () { if (!typedValue()) fillHeaders(U.$('#in-url').value); });
  }

  function showHeaders(url) {
    if (!hdrBox) buildHeaders(); // der Start zeigt die Anmeldung vor unserem DOMContentLoaded
    hdrBox.classList.add('hidden');
    fillHeaders(url);
  }

  function headerError(r) {
    switch (r.error) {
      case 'name': return T('Ungültiger Header-Name: {name}', { name: r.name || '?' });
      case 'empty': return T('Header „{name}“ hat keinen Wert.', { name: r.name });
      case 'value': return T('Ungültiger Wert für Header „{name}“.', { name: r.name });
      case 'many': return T('Zu viele Header.');
      case 'https': return T('Header gehen nur über https, im Heimnetz auch über http.');
      case 'crypto': return T('Die Header können auf diesem PC nicht verschlüsselt gespeichert werden.');
      default: return T('Ungültige Server-URL.');
    }
  }

  function tryHeaders(url) {
    var rows = U.$$('.hdr-row', hdrRows).map(function (r) {
      return { name: U.$('.hdr-name', r).value, value: U.$('.hdr-value', r).value };
    });
    return N.headers.attempt(url, rows).then(function (r) {
      if (r && r.error) { var e = new Error(headerError(r)); e.headers = true; throw e; }
    });
  }

  // ---------------- Eigene Header nachträglich ändern (Einstellungen), ohne sich neu anzumelden.
  // Die neuen Header gelten erst nur zur Probe: antwortet der Server damit, werden sie gespeichert – sonst bleibt alles beim Alten.
  // check: eine Anfrage an genau diesen Server, die nur mit richtigen Headern gelingt.
  function editHeaders(title, url, check, done) {
    var m = UI.modal(title, [{ label: T('Abbrechen'), icon: 'prev', action: function () { N.headers.discard(); } }]);
    m.box.classList.add('hdr-modal');
    var rows = h('div.hdr-rows');
    var msg = h('div.msg');
    function row(name, stored) {
      var nameIn = h('input.focusable.hdr-name', { type: 'text', placeholder: T('Name'), autocomplete: 'off', spellcheck: 'false' });
      var valueIn = h('input.focusable.hdr-value', { type: 'password', autocomplete: 'off', placeholder: stored ? T('Gespeichert') : T('Wert') });
      nameIn.value = name || '';
      var del = h('button.icon-btn.focusable', { title: T('Header entfernen') }, Icon.el('close'));
      var el = h('div.hdr-row', null, nameIn, valueIn, del);
      del.addEventListener('click', function () { rows.removeChild(el); Nav.focus(add); });
      // Enter im Feld speichert
      [nameIn, valueIn].forEach(function (i) { i.addEventListener('keydown', function (e) { if (e.keyCode === 13) { e.preventDefault(); e.stopPropagation(); save(); } }); });
      rows.appendChild(el);
      return el;
    }
    var add = h('button.btn.outline.focusable', { text: T('Header hinzufügen'), onclick: function () { Nav.focus(U.$('.hdr-name', row('')), { noInputFocus: true }); } });
    var cf = h('button.btn.outline.focusable', { text: T('Cloudflare-Access-Header'), onclick: function () {
      var have = U.$$('.hdr-name', rows).map(function (n) { return n.value.toLowerCase(); }), first = null;
      ['CF-Access-Client-Id', 'CF-Access-Client-Secret'].forEach(function (n) {
        if (have.indexOf(n.toLowerCase()) < 0) { var el = row(n); first = first || el; }
      });
      if (first) Nav.focus(U.$('.hdr-value', first), { noInputFocus: true });
    } });
    var busy = false;
    function save() {
      if (busy) return;
      var list = U.$$('.hdr-row', rows).map(function (r) { return { name: U.$('.hdr-name', r).value, value: U.$('.hdr-value', r).value }; });
      busy = true;
      msg.className = 'msg';
      msg.textContent = T('Verbinde …');
      N.headers.attempt(url, list).then(function (r) {
        if (r && r.error) { var e = new Error(headerError(r)); e.headers = true; throw e; }
        return check();
      }).then(function () {
        return N.headers.commit();
      }).then(function () {
        busy = false;
        m.close();
        U.toast(T('Header gespeichert'));
        if (done) done();
      }, function (e) {
        busy = false;
        N.headers.discard();
        msg.className = 'msg error';
        msg.textContent = e && e.headers ? e.message : T('Mit diesen Headern antwortet der Server nicht. Es wurde nichts geändert.');
      });
    }
    var ok = h('button.modal-item.focusable', { onclick: save }, Icon.el('edit'), h('span', { text: T('Prüfen und speichern') }));
    var list = U.$('.modal-list', m.box);
    var body = h('div.hdr-body.nav-container', null, rows, h('div.hdr-actions', null, add, cf),
      h('p.hdr-hint.muted', { text: T('Wird bei jeder Anfrage an diesen Server mitgeschickt, auch für Musik und Cover. Ein leerer Wert behält den gespeicherten. Die Werte liegen verschlüsselt auf diesem PC.') }), msg);
    list.insertBefore(ok, list.firstChild);
    list.insertBefore(body, ok);
    N.headers.names(url).then(function (names) {
      names.forEach(function (n) { row(n, true); });
      Nav.focus(names.length ? U.$('.hdr-value', rows) : add, { noInputFocus: true });
    });
    return m;
  }

  // Die Zeile in den Einstellungen: welche Header für den Server gespeichert sind, und der Weg, sie zu ändern
  function headerSetting(label, url, check) {
    var desc = h('div.setting-desc', { text: url });
    function refresh() {
      N.headers.names(url).then(function (names) {
        desc.textContent = names.length ? url + ' • ' + names.join(', ') : url + ' • ' + T('Keine eigenen Header');
      });
    }
    refresh();
    return h('div.setting', null, h('div', null, h('div.setting-label', { text: label }), desc),
      h('div.nav-container', null, UI.button(T('Ändern'), function () { editHeaders(label, url, check, refresh); }, 'outline', 'edit')));
  }

  // ---------------- Zwei Adressen für einen Server: zu Hause die im Heimnetz, unterwegs die von außen.
  // Wie am iPhone: die Heimadresse gilt erst, wenn dort derselbe Server antwortet wie außen, und nur in dem Netz, in dem das
  // geprüft wurde. In einem fremden Netz mit denselben Adressen bekäme sonst irgendein Gerät die Anmeldung, unverschlüsselt.
  var routeSeq = 0, homePrint = null, lastPrint = null, lastCheck = 0, routeShown = null;
  function hostOf(u) { return String(u || '').replace(/^https?:\/\//i, '').split(/[\/:?#]/)[0]; }
  function setHome(v) {
    var was = API.atHome();
    API.setHome(v);
    if (!v) homePrint = null;
    if (was && !v) Player.addressChanged();
    if (routeShown) routeShown();
  }
  function checkRoute() {
    var acc = App.account(), r = API.routes(), seq = ++routeSeq;
    lastCheck = Date.now();
    if (!acc || !r) { setHome(false); return; }
    var host = hostOf(r.home);
    N.net.state(host).then(function (n) {
      if (seq !== routeSeq) return;
      lastPrint = n.print;
      if (API.atHome() && n.print !== homePrint) setHome(false);
      if (n.same === false || !navigator.onLine) { setHome(false); return; }
      return Promise.all([API.identity(r.home), API.identity(r.outside)]).then(function (v) {
        var key = 'ident.' + acc.id, ok = false;
        if (v[0]) {
          if (v[1]) U.store.set(key, v[1]);
          // Von innen ist die Adresse von außen nicht immer erreichbar: dann zählt, was sie zuletzt geantwortet hat.
          // Noch nie von außen gesehen: kein Vertrauen.
          ok = U.store.get(key) === v[0];
        }
        return N.net.state(host).then(function (n2) {
          if (seq !== routeSeq || App.account() !== acc) return;
          ok = ok && n2.print === n.print; // das Netz darf beim Fragen nicht gewechselt haben
          homePrint = ok ? n.print : null;
          setHome(ok);
        });
      });
    });
  }
  API.onRouteLost(function () { homePrint = null; Player.addressChanged(); if (routeShown) routeShown(); checkRoute(); });
  window.addEventListener('online', checkRoute);
  window.addEventListener('offline', checkRoute);
  setInterval(function () {
    var r = API.routes();
    if (!r) return;
    N.net.state(hostOf(r.home)).then(function (n) {
      if (n.print !== lastPrint || Date.now() - lastCheck > 5 * 60 * 1000) checkRoute();
    });
  }, 20000);

  function editAlt(done) {
    var cfg = API.getConfig();
    var m = UI.modal(T('Zweite Adresse'), [{ label: T('Abbrechen'), icon: 'prev' }]);
    m.box.classList.add('hdr-modal');
    var input = h('input.modal-input.focusable', { type: 'text', autocomplete: 'off', spellcheck: 'false', placeholder: T('z. B. 192.168.1.10:4533') });
    input.value = cfg.alt || '';
    var msg = h('div.msg');
    var RULE = T('Eine der beiden Adressen muss im Heimnetz liegen, die andere von außen erreichbar sein.');
    function save() {
      var u = API.normalizeUrl(input.value);
      msg.className = 'msg error';
      if (!u) { msg.textContent = RULE; return; }
      if (u === cfg.url) { msg.textContent = T('Mit dieser Adresse bist du schon angemeldet.'); return; }
      if (API.isLocal(u) === API.isLocal(cfg.url)) { msg.textContent = RULE; return; }
      m.close();
      App.setAlt(u);
      U.toast(T('Zweite Adresse gespeichert'));
      done();
    }
    input.addEventListener('keydown', function (e) { if (e.keyCode === 13) { e.preventDefault(); e.stopPropagation(); save(); } });
    var list = U.$('.modal-list', m.box);
    var ok = h('button.modal-item.focusable', { onclick: save }, Icon.el('edit'), h('span', { text: T('Speichern') }));
    var body = h('div.hdr-body.nav-container', null, input,
      h('p.hdr-hint.muted', { text: RULE + ' ' + T('Zu Hause nimmt Tonalo die Adresse im Heimnetz, sobald dort derselbe Server antwortet, unterwegs die andere. Eigene Header gehen nur an die Adresse von außen.') }), msg);
    list.insertBefore(ok, list.firstChild);
    list.insertBefore(body, ok);
    if (cfg.alt) {
      var del = h('button.modal-item.focusable.danger', { onclick: function () { m.close(); App.setAlt(''); U.toast(T('Zweite Adresse entfernt')); done(); } },
        Icon.el('trash'), h('span', { text: T('Zweite Adresse entfernen') }));
      list.insertBefore(del, ok.nextSibling);
    }
    Nav.focus(input, { noInputFocus: true });
  }

  // Die Zeile in den Einstellungen: die zweite Adresse und welche der beiden gerade benutzt wird
  function altSetting(changed) {
    var desc = h('div.setting-desc');
    function paint() {
      var cfg = API.getConfig();
      if (!cfg || !document.body.contains(desc)) return;
      desc.textContent = !cfg.alt ? T('Keine zweite Adresse')
        : cfg.alt + ' • ' + T('Gerade benutzt: {url}', { url: API.base() });
    }
    var row = h('div.setting', null, h('div', null, h('div.setting-label', { text: T('Zweite Adresse') }), desc),
      h('div.nav-container', null, UI.button(T('Ändern'), function () { editAlt(changed); }, 'outline', 'edit')));
    routeShown = function () { setTimeout(paint, 0); };
    setTimeout(paint, 0);
    return row;
  }

  function commitHeaders() {
    U.$$('.hdr-value', hdrRows).forEach(function (v) { v.value = ''; });
    return N.headers.commit();
  }

  // Antwortet ein Proxy statt Navidrome (Login-Seite, 403, keine CORS-Freigabe), sagt "Failed to fetch" niemandem etwas
  function headerProblem(e, msg) {
    if (e.headers) { msg.textContent = e.message; return true; }
    if (e.code != null || !/TypeError|SyntaxError/.test(e.name) && !/^HTTP 4/.test(e.message)) return false;
    msg.textContent = T('Keine Antwort von Navidrome. Liegt der Server hinter Cloudflare Access oder einem anderen Proxy, prüfe die eigenen Header.');
    return true;
  }

  // ---------------- Fenster
  document.addEventListener('DOMContentLoaded', function () {
    var bar = h('div#titlebar');
    document.body.appendChild(bar);
    function size() { bar.style.height = N.titleBar() + 'px'; }
    size();
    window.addEventListener('resize', size);
    var hint = U.$('.users-hint');
    if (hint) hint.textContent = T('Rechtsklick: Konto verwalten');
    linkbar = h('div#linkbar', null, Icon.el('phone'), h('span.lb-text'));
    U.$('#main').appendChild(linkbar);
    mini = volumeControl(false);
    U.$('.mp-right').insertBefore(mini, U.$('.mp-right').firstChild);
    ['track', 'state'].forEach(function (evt) { Player.on(evt, function () { media(); mediaState(); }); Book.on(evt, function () { media(); mediaState(); }); });
    N.updates.ready();
  });

  // ---------------- Unten: welche iPhones gerade verbunden sind
  var linkbar = null;
  function linked(list) {
    if (!linkbar) return;
    var own = [], guests = [];
    (list || []).forEach(function (p) { (p.guest ? guests : own).push(p.device); });
    var parts = [];
    if (own.length) parts.push(T('Verbunden mit {name}', { name: own.join(', ') }));
    if (guests.length) parts.push(T('Jukebox-Gäste: {names}', { names: guests.join(', ') }));
    U.$('.lb-text', linkbar).textContent = parts.join(' · ');
    document.documentElement.classList.toggle('linked', parts.length > 0);
  }

  return { showHeaders: showHeaders, tryHeaders: tryHeaders, commitHeaders: commitHeaders,
    dropHeaders: function () { N.headers.discard(); },
    // Auch die Adressen von Audiobookshelf: ihre Header bleiben, solange das Konto da ist
    keepHeaders: function (list) { var urls = []; list.forEach(function (a) { urls.push(a.url); if (a.alt) urls.push(a.alt); if (a.abs && a.abs.url) urls.push(a.abs.url); }); N.headers.keepOnly(urls); },
    headerProblem: headerProblem, headerSetting: headerSetting, altSetting: altSetting, checkRoute: checkRoute,
    updateSetting: updateSetting, volume: function () { return volumeControl(true); }, linked: linked };
})();
