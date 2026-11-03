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
    if (code === 32 && !typing() && mainOpen()) { Player.toggle(); return true; }
    if (!(e.ctrlKey || e.metaKey) || !mainOpen()) return false;
    if (code === 70) { App.go('search', null, { root: true }); return true; }
    if (code === Nav.KEY.RIGHT && !typing()) { Player.next(); return true; }
    if (code === Nav.KEY.LEFT && !typing()) { Player.prev(); return true; }
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
    if (!bar || Player.station() || !Player.duration()) return;
    e.preventDefault(); e.stopPropagation();
    var r = (U.$('.np-bar', bar) || bar).getBoundingClientRect();
    Player.seek(Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)) * Player.duration());
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
  function mediaState() { if (ms) ms.playbackState = Player.current() || Player.station() ? (Player.paused() ? 'paused' : 'playing') : 'none'; }
  if (ms) {
    ms.setActionHandler('play', function () { Player.play(); });
    ms.setActionHandler('pause', function () { Player.pause(); });
    ms.setActionHandler('stop', function () { Player.pause(); });
    ms.setActionHandler('previoustrack', function () { Player.prev(); });
    ms.setActionHandler('nexttrack', function () { Player.next(); });
    ms.setActionHandler('seekto', function (d) { if (!Player.station()) Player.seek(d.seekTime || 0); });
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
    ['track', 'state'].forEach(function (evt) { Player.on(evt, function () { media(); mediaState(); }); });
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
    keepHeaders: function (list) { N.headers.keepOnly(list.map(function (a) { return a.url; })); },
    headerProblem: headerProblem,
    updateSetting: updateSetting, volume: function () { return volumeControl(true); }, linked: linked };
})();
