/* Verbindung zum iPhone: Der Hintergrunddienst (tonalo.service) zeigt dem iPhone im Heimnetz, was hier läuft,
   und reicht Musik weiter, die dort ausgewählt wird. Gekoppelt wird einmal mit einem Code auf dem Bildschirm. */
var Link = (function () {
  'use strict';
  var SERVICE = 'luna://tonalo.service/';
  var bridge = null;      // offenes Abo beim Dienst
  var pairModal = null;
  var pushTimer = null, lastPush = 0, lastPos = 0;

  function available() { return typeof PalmServiceBridge !== 'undefined'; }

  function tvId() {
    var id = U.store.get('tvId');
    if (!id) { id = ''; for (var i = 0; i < 16; i++) id += '0123456789abcdef'.charAt(Math.floor(Math.random() * 16)); U.store.set('tvId', id); }
    return id;
  }

  function call(method, params, cb) {
    var b = new PalmServiceBridge();
    b.onservicecallback = function (msg) { try { if (cb) cb(JSON.parse(msg)); } catch (e) { /* egal */ } };
    b.call(SERVICE + method, JSON.stringify(params || {}));
    return b;
  }

  // Nach der Kontoauswahl: Gekoppelte iPhones gehören zum Konto – ein anderes Konto sieht sie nicht
  function attach() {
    if (!available() || !App.account()) return;
    if (bridge) { try { bridge.cancel(); } catch (e) { /* egal */ } }
    var params = { subscribe: true, id: tvId(), name: U.store.get('tvName', 'LG TV'), keys: U.ustore.get('phones', []) };
    bridge = call('attach', params, onMessage);
    push();
  }

  function detach() {
    if (bridge) { try { bridge.cancel(); } catch (e) { /* egal */ } }
    bridge = null;
    if (available()) call('state', { state: { active: false } });
  }

  function onMessage(msg) {
    if (msg.keys) U.ustore.set('phones', msg.keys);
    if ('pairCode' in msg) showCode(msg.pairCode);
    if (msg.paired) U.toast(T('{device} ist jetzt verbunden', { device: msg.paired }), 4000);
    if (msg.command) run(msg.command);
  }

  function showCode(code) {
    if (pairModal) { pairModal.close(); pairModal = null; }
    if (!code) return;
    App.wake();
    pairModal = UI.modal(null, [{ icon: 'close', label: T('Abbrechen') }], {
      head: { title: code.slice(0, 3) + ' ' + code.slice(3), sub: T('Gib diesen Code in Tonalo auf dem iPhone ein') }
    });
    pairModal.box.classList.add('pair-code');
    var m = pairModal;
    setTimeout(function () { if (pairModal === m) { m.close(); pairModal = null; } }, 120000);
  }

  // ---------- Befehle vom iPhone
  function run(c) {
    switch (c.cmd) {
      case 'play':
        if (c.songs && c.songs.length) Player.playList(c.songs, c.index || 0, { shuffle: !!c.shuffle, keepStart: !c.shuffle || c.index > 0, context: c.context || null });
        break;
      case 'station': if (c.station) Player.playStation(c.station, c.list || null); break;
      case 'stopStation': Player.stopStation(); break;
      case 'playNext': if (c.songs && c.songs.length) Player.playNext(c.songs); break;
      case 'enqueue': if (c.songs && c.songs.length) Player.enqueue(c.songs); break;
      case 'toggle': Player.toggle(); break;
      case 'play-pause': if (c.playing) Player.play(); else Player.pause(); break;
      case 'next': Player.next(); break;
      case 'prev': Player.prev(); break;
      case 'seek': Player.seek(+c.position || 0); break;
      case 'jump': Player.jump(+c.index); break;
      case 'shuffle': Player.setShuffle(!!c.on); break;
      case 'repeat':
        for (var i = 0; i < 3 && Player.repeat() !== c.mode; i++) Player.cycleRepeat();
        break;
      case 'star':
        var s = Player.current();
        if (s && s.id === c.id) Player.setStarred(s, !!c.on); // der Server weiß es schon vom iPhone
        break;
    }
    App.wake();
    push();
  }

  // ---------- Stand für das iPhone
  function snapshot() {
    var acc = App.account(), cfg = API.getConfig();
    var st = Player.station(), song = Player.current();
    if (!acc || !cfg || (!song && !st)) return { active: false };
    var q = Player.queue(), i = Player.index(), from = Math.max(0, i - 20);
    var ctx = Player.context();
    return {
      active: true,
      user: cfg.user,
      server: cfg.url,
      playing: !Player.paused(),
      position: Player.position(),
      duration: Player.duration(),
      at: Date.now(),
      station: st ? { id: st.id, name: st.name, streamUrl: st.streamUrl } : null,
      queue: q.slice(from, i + 101),
      index: i - from,
      offset: from,
      shuffle: Player.shuffle(),
      repeat: Player.repeat(),
      context: ctx ? { kind: ctx.kind, name: ctx.name, id: ctx.id } : null
    };
  }

  function push() {
    if (!bridge) return;
    clearTimeout(pushTimer);
    pushTimer = setTimeout(function () {
      lastPush = Date.now();
      lastPos = Player.position();
      call('state', { state: snapshot() });
    }, 150);
  }

  function init() {
    if (!available()) return;
    // Der Name, den das iPhone beim Koppeln zeigt – sonst „LG TV“
    var b = new PalmServiceBridge();
    b.onservicecallback = function (msg) {
      try {
        var name = (JSON.parse(msg).settings || {}).deviceName;
        if (name) { U.store.set('tvName', name.replace(/^\[LG\]\s*/, '')); if (bridge) attach(); }
      } catch (e) { /* egal */ }
    };
    b.call('luna://com.webos.service.settings/getSystemSettings', JSON.stringify({ category: 'network', keys: ['deviceName'] }));
    ['track', 'state', 'queue', 'mode'].forEach(function (evt) { Player.on(evt, push); });
    // Die Zeit rechnet das iPhone selbst weiter – nur ab und zu abgleichen, und sofort nach dem Spulen
    Player.on('time', function () {
      var expected = lastPos + (Player.paused() ? 0 : (Date.now() - lastPush) / 1000);
      if (Date.now() - lastPush > 10000 || Math.abs(Player.position() - expected) > 3) push();
    });
  }

  function phones() { return U.ustore.get('phones', []); }
  function forget() { U.ustore.set('phones', []); attach(); }

  return { init: init, attach: attach, detach: detach, push: push, phones: phones, forget: forget };
})();
