/* Am PC/Mac: andere Geräte im Heimnetz steuern (Fernseher, andere Computer) – wie mit Tonalo auf dem iPhone.
   Einmal mit einem Code koppeln, dann zeigt eine Leiste unten, was dort läuft, und lässt Pause und Weiter zu.
   Gesucht, gekoppelt und gesendet wird im Hauptprozess (desktop/remote.js); die Schlüssel sieht diese Oberfläche nie.
   Am TV gibt es das nicht: der bleibt Empfänger. */
var Remote = (function () {
  'use strict';
  if (!U.desktop) return null;
  var h = U.h, root = document.documentElement;

  var SERVICE = 'luna://tonalo.service/';
  function call(method, params, cb) {
    var b = new PalmServiceBridge();
    b.onservicecallback = function (msg) { try { if (cb) cb(JSON.parse(msg)); } catch (e) { /* egal */ } };
    b.call(SERVICE + method, JSON.stringify(params || {}));
    return b;
  }
  function account() { var a = App.account(); return a ? a.id : ''; }
  function ownId() { return U.store.get('tvId') || ''; }

  // ---------------- Das Gerät, das gerade gesteuert wird
  var current = null;    // { id, name, kind }
  var watch = null;      // offenes Abo auf seinen Stand
  var state = null, received = 0, bar = null, tick = null;

  function iconOf(kind) { return kind === 'pc' ? 'laptop' : 'tv'; }

  function stop() {
    if (watch) { try { watch.cancel(); } catch (e) { /* egal */ } }
    watch = null; current = null; state = null;
    clearInterval(tick); tick = null;
    root.classList.remove('remote');
  }

  function control(dev) {
    stop();
    current = dev;
    root.classList.add('remote');
    paint();
    tick = setInterval(paint, 1000);
    watch = call('remoteWatch', { subscribe: true, account: account(), id: dev.id }, function (m) {
      if (!current || current.id !== dev.id) return;
      if (m.state) { state = m.state; received = m.received || Date.now(); paint(); }
      if (m.lost === 'gone') { U.toast(T('{name} ist nicht erreichbar.', { name: dev.name }), 4000); stop(); }
      if (m.lost === 'not paired') { U.toast(T('Die Kopplung mit {name} gilt dort nicht mehr.', { name: dev.name }), 4000); stop(); }
    });
  }

  function send(cmd) {
    if (!current) return;
    var name = current.name;
    call('remoteSend', { account: account(), id: current.id, cmd: cmd }, function (m) {
      if (!m.ok) U.toast(T('{name} ist nicht erreichbar.', { name: name }), 3000);
    });
  }

  // Was dort läuft: Titel und Interpret, oder der Sender, oder das Hörbuch
  function nowText() {
    var s = state;
    if (!s || (!s.active && !s.book)) return T('Es läuft nichts');
    if (s.book) return T('Hörbuch') + ': ' + (s.book.title || '');
    if (s.station) return s.station.name || '';
    var song = s.queue && s.queue[s.index];
    return song ? (song.title || '') + (song.artist ? ' – ' + song.artist : '') : T('Es läuft nichts');
  }

  function playing() { return !!state && (state.book ? !!state.book.playing : !!state.playing); }

  function paint() {
    if (!bar || !current) return;
    U.$('.rb-text', bar).textContent = current.name + ' · ' + nowText();
    var btn = U.$('.rb-play', bar);
    if (btn && btn.dataset.state !== String(playing())) { btn.dataset.state = String(playing()); UI.setIcon(btn, playing() ? 'pause' : 'play'); }
    U.$$('.rb-next, .rb-prev, .rb-play', bar).forEach(function (b) { b.disabled = !state || (!state.active && !state.book); });
  }

  document.addEventListener('DOMContentLoaded', function () {
    bar = h('div#remotebar', null, Icon.el('tv'), h('span.rb-text'),
      h('div.rb-controls', null,
        UI.iconBtn('prev', function () { send({ cmd: 'prev' }); }, T('Zurück'), 'rb-prev'),
        UI.iconBtn('play', function () { send({ cmd: 'play-pause', playing: !playing() }); if (state) { if (state.book) state.book.playing = !playing(); else state.playing = !playing(); paint(); } }, T('Play/Pause'), 'rb-play'),
        UI.iconBtn('next', function () { send({ cmd: 'next' }); }, T('Weiter'), 'rb-next')),
      UI.iconBtn('close', function () { stop(); }, T('Nicht mehr steuern'), 'rb-close'));
    U.$('#main').appendChild(bar);
  });

  // ---------------- Geräte: finden, koppeln, auswählen
  function sheet() {
    var m = UI.modal(T('Andere Geräte steuern'), []);
    var list = U.$('.modal-list', m.box);
    var devices = null, sig = '', sub = null, first = true;

    function render() {
      list.innerHTML = '';
      var shown = (devices || []).filter(function (d) { return d.kind !== 'phone'; });
      if (!devices) list.appendChild(h('div.hdr-body', null, h('p.hdr-hint.muted', { text: T('Suche im Netzwerk …') })));
      else if (!shown.length) list.appendChild(h('div.hdr-body', null, h('p.hdr-hint.muted', { text: T('Keine Geräte gefunden. Ist Tonalo dort geöffnet, und sind beide im selben Netzwerk?') })));
      shown.forEach(function (d) {
        var status = d.paired ? (d.here ? T('Gekoppelt') : T('Nicht gefunden')) : T('Nicht gekoppelt');
        var row = h('button.modal-item.focusable', { onclick: function () { choose(d); } },
          Icon.el(iconOf(d.kind)), h('span', null, d.name, h('span.muted', { text: ' · ' + status })));
        list.appendChild(row);
      });
      shown.filter(function (d) { return d.paired; }).forEach(function (d) {
        list.appendChild(h('button.modal-item.focusable.danger', { onclick: function () {
          call('remoteForget', { account: account(), id: d.id });
          if (current && current.id === d.id) stop();
          U.toast(T('Kopplung mit {name} entfernt', { name: d.name }));
        } }, Icon.el('trash'), h('span', { text: T('Kopplung mit {name} entfernen', { name: d.name }) })));
      });
      if (first && shown.length) { first = false; Nav.focusFirst(m.box); }
    }

    function choose(d) {
      if (d.paired && d.here) { close(); control(d); return; }
      if (d.paired) { U.toast(T('{name} nicht gefunden. Ist es an, und im selben Netzwerk?', { name: d.name }), 4000); return; }
      close();
      pair(d);
    }
    function close() { if (sub) { try { sub.cancel(); } catch (e) { /* egal */ } sub = null; } m.close(); }

    sub = call('remoteDevices', { subscribe: true, account: account(), self: ownId() }, function (r) {
      if (!r.devices) return;
      var s = JSON.stringify(r.devices);
      if (s === sig) return;
      sig = s; devices = r.devices;
      if (document.body.contains(list)) render();
    });
    render();
    // Beim Schließen (Esc, Zurück) hört die Suche auf
    var observer = new MutationObserver(function () { if (!document.body.contains(list)) { observer.disconnect(); if (sub) { try { sub.cancel(); } catch (e) { /* egal */ } sub = null; } } });
    observer.observe(document.body, { childList: true, subtree: true });
  }

  // Mit den Texten als Literale, damit die Übersetzungsprüfung sie findet
  function problem(code) {
    switch (code) {
      case 'gone': return T('Das Gerät antwortet nicht.');
      case 'not ready': return T('Dort ist noch kein Konto gewählt. Öffne Tonalo dort und wähle ein Konto.');
      case 'expired': return T('Der Code ist abgelaufen. Versuche es noch einmal.');
      case 'wrong code': return T('Falscher Code.');
      default: return T('Verbinden hat nicht geklappt.');
    }
  }

  // Das Gerät zeigt einen sechsstelligen Code; hier wird er eingegeben – er selbst geht nie übers Netz
  function pair(d) {
    call('remotePair', { account: account(), id: d.id, step: 'start' }, function (r) {
      if (r.result !== 'ok') { U.toast(problem(r.result), 4500); return; }
      var input = h('input.focusable.hdr-name', { type: 'text', inputmode: 'numeric', maxlength: 7, placeholder: '123 456', autocomplete: 'off', spellcheck: 'false' });
      var msg = h('div.msg.error');
      var m = UI.modal(null, [], { head: { title: T('Code eingeben'), sub: T('Auf {name} steht jetzt ein sechsstelliger Code.', { name: d.name }) } });
      var busy = false;
      function go() {
        var code = input.value.replace(/\D/g, '');
        if (busy) return;
        if (code.length !== 6) { msg.textContent = problem('wrong code'); return; }
        busy = true;
        call('remotePair', { account: account(), id: d.id, step: 'finish', code: code }, function (r2) {
          busy = false;
          if (r2.result === 'ok') { m.close(); U.toast(T('{device} ist jetzt verbunden', { device: d.name }), 3500); control(d); return; }
          msg.textContent = problem(r2.result);
          if (r2.result !== 'wrong code') { setTimeout(function () { m.close(); }, 1800); }
        });
      }
      input.addEventListener('keydown', function (e) { if (e.keyCode === 13) { e.preventDefault(); e.stopPropagation(); go(); } });
      var list = U.$('.modal-list', m.box);
      var ok = h('button.modal-item.focusable', { onclick: go }, Icon.el('play'), h('span', { text: T('Verbinden') }));
      var body = h('div.hdr-body.nav-container', null, input, msg);
      list.insertBefore(ok, list.firstChild);
      list.insertBefore(body, ok);
      Nav.focus(input, { noInputFocus: true });
    });
  }

  // Die Zeile in den Einstellungen
  function setting() {
    return h('div.setting', null, h('div', null,
      h('div.setting-label', { text: T('Andere Geräte steuern') }),
      h('div.setting-desc', { text: T('Steuere die Musik auf einem Fernseher oder anderen Computer im selben Netzwerk, wie mit Tonalo auf dem iPhone. Einmal koppeln, dann siehst du dort, was läuft.') })),
      h('div.nav-container', null, UI.button(T('Geräte anzeigen'), sheet, 'outline', 'tv')));
  }

  // Beim Kontowechsel oder Abmelden: nichts mehr steuern, was zum alten Konto gehörte
  function reset() { stop(); }

  return { setting: setting, sheet: sheet, reset: reset, current: function () { return current; } };
})();
