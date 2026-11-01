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

  // ---------------- Lautstärke im Mini-Player
  function volumeControl() {
    var last = Player.volume() || 1;
    var btn = h('button#mp-volume.mp-btn.focusable.nav-fallback', { title: T('Lautstärke') });
    var range = h('input.mp-volume', { type: 'range', min: 0, max: 100, step: 1 });
    function sync() {
      var v = Player.volume();
      range.value = Math.round(v * 100);
      range.style.setProperty('--fill', Math.round(v * 100) + '%');
      btn.innerHTML = Icon.svg(v ? 'volume' : 'mute');
    }
    btn.addEventListener('click', function () {
      if (Player.volume()) { last = Player.volume(); Player.setVolume(0); } else Player.setVolume(last || 1);
    });
    range.addEventListener('input', function () { Player.setVolume(range.value / 100); });
    var box = h('div.mp-volbox', null, btn, range);
    box.addEventListener('wheel', function (e) {
      e.preventDefault();
      Player.setVolume(Player.volume() + (e.deltaY < 0 ? 0.05 : -0.05));
    }, { passive: false });
    Player.on('volume', sync);
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

  // ---------------- Fenster
  document.addEventListener('DOMContentLoaded', function () {
    var bar = h('div#titlebar');
    document.body.appendChild(bar);
    function size() { bar.style.height = N.titleBar() + 'px'; }
    size();
    window.addEventListener('resize', size);
    var hint = U.$('.users-hint');
    if (hint) hint.textContent = T('Rechtsklick: Konto verwalten');
    U.$('.mp-right').insertBefore(volumeControl(), U.$('.mp-right').firstChild);
    ['track', 'state'].forEach(function (evt) { Player.on(evt, function () { media(); mediaState(); }); });
    N.updates.ready();
  });

  return { updateSetting: updateSetting };
})();
