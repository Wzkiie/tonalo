/* Verbindung zum iPhone: Der Hintergrunddienst (tonalo.service) zeigt dem iPhone im Heimnetz, was hier läuft,
   und reicht Musik weiter, die dort ausgewählt wird. Gekoppelt wird einmal mit einem Code auf dem Bildschirm. */
var Link = (function () {
  'use strict';
  var SERVICE = 'luna://tonalo.service/';
  var bridge = null;      // offenes Abo beim Dienst
  var pairModal = null;
  var pushTimer = null, lastPush = 0, lastPos = 0;

  function available() { return typeof PalmServiceBridge !== 'undefined'; }

  // Am PC abschaltbar, z. B. in einem fremden WLAN – am TV immer an
  function visible() { return !U.desktop || U.store.get('linkVisible', true) !== false; }

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
    if (!available() || !App.account() || !visible()) return;
    if (bridge) { try { bridge.cancel(); } catch (e) { /* egal */ } }
    // Die iPhones der anderen Konten auf diesem TV dürfen als Gäste der Jukebox beitreten – sie sehen nicht, wessen Konto läuft
    var others = [];
    (U.store.get('accounts', []) || []).forEach(function (a) {
      if (a.id !== App.account().id) others = others.concat(U.ustore.peek(a.id, 'phones', []) || []);
    });
    var params = { subscribe: true, id: tvId(), name: U.store.get('tvName', 'LG TV'), kind: U.desktop ? 'pc' : 'tv', keys: U.ustore.get('phones', []), others: others,
      // Die DJ-Einrichtung gehört zum Konto. Am PC hält sie der Hauptprozess verschlüsselt, hier geht nur die Kontonummer mit
      account: App.account().id, dj: U.desktop ? null : U.ustore.get('dj', null) };
    bridge = call('attach', params, onMessage);
    push();
  }

  function detach() {
    if (bridge) { try { bridge.cancel(); } catch (e) { /* egal */ } }
    bridge = null;
    DJ.setInfo(null); // gehört zum Konto, das gerade geht
    if (U.desktop) { Desktop.linked([]); Remote.reset(); } // das gesteuerte Gerät gehört zum Konto, das gerade geht
    if (available()) call('state', { state: { active: false } });
  }

  function onMessage(msg) {
    if (msg.keys) U.ustore.set('phones', msg.keys);
    // Das eigene iPhone hat den DJ übergeben oder weggenommen. Am TV legt die App ihn zum Konto ab (es gibt dort keinen
    // geschützten Speicher), am PC kommt hier nur an, wer auswählt – der Schlüssel bleibt im Hauptprozess.
    if ('dj' in msg && !U.desktop) U.ustore.set('dj', msg.dj || null);
    if ('djInfo' in msg) {
      var had = DJ.ready();
      DJ.setInfo(msg.djInfo);
      if (!had && DJ.ready() && msg.djGiven) U.toast(T('Der DJ ist jetzt auch hier eingerichtet'), 4000);
    }
    if ('pairCode' in msg) showCode(msg.pairCode, msg.pairName, msg.guest, msg.pairVia);
    if (msg.paired) U.toast(msg.guest ? T('{device} ist der Jukebox beigetreten', { device: msg.paired }) : T('{device} ist jetzt verbunden', { device: msg.paired }), 4000);
    if (msg.command) run(msg.command);
    if (msg.connected && U.desktop) Desktop.linked(msg.connected);
  }

  function showCode(code, name, guest, via) {
    if (pairModal) { pairModal.close(); pairModal = null; }
    if (!code) return;
    App.wake();
    pairModal = UI.modal(null, [{ icon: 'close', label: T('Abbrechen'), action: function () { pairModal = null; } }], {
      head: { title: code.slice(0, 3) + ' ' + code.slice(3),
        // Wer fragt, steht immer dabei – kommt die Anfrage unerwartet, gibt man den Code einfach nicht weiter
        sub: via === 'pc' ? T('{name} möchte dieses Gerät steuern – diesen Code in Tonalo am Computer eingeben', { name: name || 'PC' })
          : !name ? T('Gib diesen Code in Tonalo auf dem iPhone ein')
          : guest ? T('{name} möchte der Jukebox beitreten – diesen Code auf dem iPhone eingeben', { name: name })
          : T('{name} möchte sich als eigenes Gerät verbinden – diesen Code auf dem iPhone eingeben', { name: name }) }
    });
    pairModal.box.classList.add('pair-code');
    var m = pairModal;
    setTimeout(function () { if (pairModal === m) { m.close(); pairModal = null; } }, 120000);
  }

  // ---------- Befehle vom iPhone
  // Ein Gast der Jukebox hat etwas getan: kurz zeigen, wer
  function announce(c) {
    if (!c.by) return;
    var n = (c.songs || []).length;
    if (c.cmd === 'next') U.toast(T('{name} hat übersprungen', { name: c.by }), 3000);
    else if (n === 1) U.toast(T('{name} hat „{title}“ hinzugefügt', { name: c.by, title: c.songs[0].title }), 4000);
    else if (n > 1) U.toast(T('{name} hat {n} Songs hinzugefügt', { name: c.by, n: n }), 4000);
  }

  // Ein Hörbuch, das auf dem iPhone lief, geht hier weiter – nur beim selben Audiobookshelf-Konto
  function playBook(c) {
    if (!ABS.connected() || !c.itemId) { U.toast(T('Audiobookshelf ist hier nicht verbunden.'), 4000); return; }
    if (c.user && String(c.user).toLowerCase() !== ABS.user().toLowerCase()) return;
    BookViews.start(String(c.itemId), c.episodeId ? String(c.episodeId) : null, c.position != null ? +c.position || 0 : null, null);
  }

  // Songs eines Jukebox-Gasts tragen seine Herzen, nicht die dieses Kontos: die eigenen nachschlagen,
  // sonst sieht der Gastgeber fremde Likes und sein Herz schaltet falsch herum
  function ownHearts(c) {
    if (!c.by) return Promise.resolve(c.songs);
    var songs = c.songs.map(function (s) { var o = Object.assign({}, s); delete o.starred; delete o.playCount; delete o.userRating; return o; });
    return API.starred().then(function (r) {
      var mine = {};
      r.songs.forEach(function (s) { mine[s.id] = s.starred || true; });
      songs.forEach(function (s) { if (mine[s.id]) s.starred = mine[s.id]; });
      return songs;
    }, function () { return songs; });
  }

  function run(c) {
    // Gäste der Jukebox (c.by) haben mit einem laufenden Hörbuch nichts zu tun: ihre Songs würden es still unterbrechen
    if (c.by && App.bookMode()) return;
    switch (c.cmd) {
      case 'play':
        if (c.songs && c.songs.length) Player.playList(c.songs, c.index || 0, { shuffle: !!c.shuffle, keepStart: !c.shuffle || c.index > 0, context: c.context || null, at: +c.position || 0 });
        break;
      case 'station': if (c.station) Player.playStation(c.station, c.list || null); break;
      case 'stopStation': Player.stopStation(); break;
      case 'playNext': if (c.songs && c.songs.length) ownHearts(c).then(function (songs) { Player.playNext(songs); }); break;
      case 'enqueue': if (c.songs && c.songs.length) ownHearts(c).then(function (songs) { Player.enqueue(songs); }); break;
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
      // Hörbücher (Audiobookshelf): das iPhone schickt eins her, steuert es oder holt es zurück
      case 'bookPlay': playBook(c); break;
      case 'bookToggle': Book.toggle(); break;
      case 'bookPlayPause': if (c.playing) Book.play(); else Book.pause(); break;
      case 'bookSeek': Book.seek(+c.position || 0); break;
      case 'bookSkip': Book.skip(+c.seconds || 0); break;
      case 'bookChapter': if (+c.dir > 0) Book.nextChapter(); else Book.prevChapter(); break;
      case 'bookRate': Book.setRate(+c.rate); break;
      case 'bookSleep':
        if (c.mode === 'chapter') Book.setSleepChapter();
        else if (+c.minutes > 0) Book.setSleep(Math.min(+c.minutes, 600));
        else Book.cancelSleep();
        break;
      case 'bookStop': Book.close(); break;
      case 'star':
        var s = Player.current();
        if (s && s.id === c.id) Player.setStarred(s, !!c.on); // der Server weiß es schon vom iPhone
        break;
    }
    // Erst danach: der Player zeigt beim Hinzufügen selbst einen Hinweis, der den hier sonst gleich ersetzt
    announce(c);
    App.wake();
    push();
  }

  // ---------- Stand für das iPhone
  function snapshot() {
    var acc = App.account(), cfg = API.getConfig();
    var st = Player.station(), song = Player.current();
    // Audiobookshelf-Konto hier: so weiß das iPhone, dass es Hörbücher hierher schicken kann
    var abs = ABS.connected() ? { server: ABS.server(), user: ABS.user(), libs: ABS.libraryIds() } : null;
    if (acc && cfg && App.bookMode()) {
      var bc = Book.chapter();
      return {
        active: false, user: cfg.user, server: cfg.url, abs: abs, at: Date.now(),
        book: {
          id: Book.itemId(), episode: Book.episodeId(), title: Book.title(), author: Book.author(),
          chapter: bc ? bc.title || '' : '', chapterIndex: Book.chapterIndex(),
          position: Book.position(), duration: Book.duration(), playing: Book.playing(), loading: Book.loading(),
          rate: Book.rate(), sleep: Book.sleepLeft(), server: abs && abs.server, user: abs && abs.user
        }
      };
    }
    if (!acc || !cfg || (!song && !st)) return acc && cfg ? { active: false, user: cfg.user, server: cfg.url, abs: abs } : { active: false };
    var q = Player.queue(), i = Player.index(), from = Math.max(0, i - 20);
    var ctx = Player.context();
    return {
      active: true,
      abs: abs,
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
      lastPos = App.bookMode() ? Book.position() : Player.position();
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
    ['track', 'state', 'sleep'].forEach(function (evt) { Book.on(evt, push); });
    // Die Zeit rechnet das iPhone selbst weiter – nur ab und zu abgleichen, und sofort nach dem Spulen
    Player.on('time', function () {
      var expected = lastPos + (Player.paused() ? 0 : (Date.now() - lastPush) / 1000);
      if (Date.now() - lastPush > 10000 || Math.abs(Player.position() - expected) > 3) push();
    });
    Book.on('time', function () {
      if (!App.bookMode()) return;
      var expected = lastPos + (Book.playing() ? (Date.now() - lastPush) / 1000 * Book.rate() : 0);
      if (Date.now() - lastPush > 10000 || Math.abs(Book.position() - expected) > 3) push();
    });
  }

  function setVisible(on) {
    U.store.set('linkVisible', !!on);
    if (on) { attach(); return; }
    detach();
    if (available()) call('stop', {});
  }

  function phones() { return U.ustore.get('phones', []); }
  // Mit den iPhones geht auch der DJ, den eins von ihnen hier eingerichtet hat
  function forget() { U.ustore.set('phones', []); DJ.forget(); attach(); }

  return { available: available, init: init, attach: attach, detach: detach, push: push, phones: phones, forget: forget, visible: visible, setVisible: setVisible };
})();
