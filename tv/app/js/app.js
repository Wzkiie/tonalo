/* App-Steuerung: Login, Router, Tasten, Mini-Player, Bildschirmschoner */
var App = (function () {
  'use strict';
  var K = Nav.KEY;
  var APP_ID = 'tonalo';

  var DEFAULTS = { maxBitRate: 0, format: 'mp3', scrobble: true, screensaver: 3, startView: 'home' };
  var settings = Object.assign({}, DEFAULTS);
  var account = null;   // aktives Konto {id, url, user, salt, token}

  var stack = [];       // [{name, params, view, scroll, focus}]
  var content, main, login, users;

  // ---------------- Skalierung (im Desktop-Browser zum Testen; TV läuft nativ 1920x1080)
  function fit() {
    var s = Math.min(window.innerWidth / 1920, window.innerHeight / 1080);
    var st = document.getElementById('stage');
    st.style.transform = s === 1 ? '' : 'scale(' + s + ')';
  }

  // ---------------- Fokus-Bereich
  function updateScope() {
    Nav.setScope(function () {
      if (UI.modalOpen()) return U.$('#modal-layer');
      if (!users.classList.contains('hidden')) return users;
      if (!login.classList.contains('hidden')) return login;
      return main;
    });
  }

  // ---------------- Konten
  function accounts() { return U.store.get('accounts', []) || []; }
  function saveAccounts(list) { U.store.set('accounts', list); }
  function accId(url, user) { return md5(API.normalizeUrl(url) + '|' + user.toLowerCase()).slice(0, 10); }

  // Flache Profilfarben
  var AVATAR_COLORS = ['#5b9dff', '#f59e0b', '#34d399', '#f472b6', '#a78bfa', '#fb7185', '#38bdf8', '#facc15', '#4ade80', '#fb923c'];
  function avatarColor(name) {
    var hash = parseInt(md5(String(name).toLowerCase()).slice(0, 6), 16);
    return AVATAR_COLORS[hash % AVATAR_COLORS.length];
  }
  function initial(name) { return String(name || '?').charAt(0).toUpperCase(); }

  // Alte Einzelkonto-Daten (v1.0) in das Mehrbenutzer-Format übernehmen
  function migrate() {
    var old = U.store.get('auth', null);
    if (!old || !old.token) return;
    var acc = Object.assign({ id: accId(old.url, old.user) }, old);
    saveAccounts([acc].concat(accounts().filter(function (a) { return a.id !== acc.id; })));
    ['queue', 'index', 'repeat', 'shuffle', 'pos', 'lastSearch', 'albumSort', 'lyricsOn', 'settings'].forEach(function (k) {
      var v = U.store.get(k);
      if (v !== undefined) { U.store.set('u.' + acc.id + '.' + k, v); U.store.del(k); }
    });
    U.store.del('auth');
  }

  function hideAllScreens() {
    main.classList.add('hidden');
    login.classList.add('hidden');
    users.classList.add('hidden');
  }

  // ---------------- Benutzerauswahl
  function showUsers() {
    if (UI.modalOpen()) UI.closeModal();
    var list = accounts();
    if (!list.length) { showLogin(); return; }
    if (!main.classList.contains('hidden') && stack.length) {
      var top = stack[stack.length - 1];
      top.scroll = top.view.el.scrollTop; top.focus = Nav.current();
    }
    hideAllScreens();
    users.classList.remove('hidden');
    var box = U.$('#user-list');
    box.innerHTML = '';
    var lastId = account ? account.id : U.store.get('lastAccount', null);
    var focusEl = null;
    list.forEach(function (acc) {
      var q = U.ustore.peek(acc.id, 'queue', []) || [], i = U.ustore.peek(acc.id, 'index', -1);
      var last = q[i];
      var host = acc.url.replace(/^https?:\/\//, '');
      var card = U.h('button.user-card.focusable' + (account && account.id === acc.id ? '.current' : ''),
        { onclick: function () { selectAccount(acc); } },
        U.h('div.avatar', { style: 'background:' + avatarColor(acc.user), text: initial(acc.user) }),
        U.h('div.user-name.ellipsis', { text: acc.user }),
        U.h('div.user-sub.muted.ellipsis', { text: host }),
        U.h('div.user-last.ellipsis', { text: last ? T('Zuletzt: {title}', { title: last.title }) : ' ' })
      );
      card.addEventListener('options', function () { userMenu(acc); });
      box.appendChild(card);
      if (acc.id === lastId) focusEl = card;
    });
    box.appendChild(U.h('button.user-card.focusable', { onclick: function () { showLogin(null, { adding: true }); } },
      U.h('div.avatar.add', null, Icon.el('plus', 80)),
      U.h('div.user-name', { text: T('Konto hinzufügen') }),
      U.h('div.user-sub.muted', { text: T('Neu anmelden') }),
      U.h('div.user-last', { text: ' ' })
    ));
    updateScope();
    Nav.focus(focusEl || box.firstChild);
  }

  function userMenu(acc) {
    UI.modal(acc.user, [
      { icon: 'play', label: T('Auswählen'), action: function () { selectAccount(acc); } },
      { icon: 'refresh', label: T('Neu anmelden (Passwort geändert)'), action: function () { showLogin(null, { prefill: acc, adding: true }); } },
      { icon: 'trash', label: T('Konto von diesem TV entfernen'), danger: true, action: function () {
        UI.confirm(T('„{name}“ entfernen?', { name: acc.user }), T('Entfernen'), function () { removeAccount(acc); }, 'trash');
      } }
    ]);
  }

  function removeAccount(acc) {
    if (account && account.id === acc.id) {
      Player.detach();
      account = null;
      API.setConfig(null);
      stack = []; content.innerHTML = '';
    }
    saveAccounts(accounts().filter(function (a) { return a.id !== acc.id; }));
    U.ustore.clear(acc.id);
    if (U.store.get('lastAccount') === acc.id) U.store.del('lastAccount');
    U.toast(T('Konto „{name}“ entfernt', { name: acc.user }));
    showUsers();
  }

  function selectAccount(acc) {
    if (account && account.id === acc.id && stack.length) { backToMain(); return; }
    if (account) Player.detach();
    account = acc;
    U.ustore.setNs(acc.id);
    API.setConfig(acc);
    settings = Object.assign({}, DEFAULTS, U.ustore.get('settings', {}));
    U.store.set('lastAccount', acc.id);
    startMain();
    API.ping().catch(function (e) {
      if (e.code === 40) showLogin(T('Anmeldung für „{name}“ abgelaufen – bitte Passwort neu eingeben.', { name: acc.user }), { prefill: acc, adding: true });
      else U.toast(T('Server nicht erreichbar: {msg}', { msg: e.message }), 4000);
    });
  }

  function backToMain() {
    hideAllScreens();
    main.classList.remove('hidden');
    updateScope();
    var top = stack[stack.length - 1];
    if (top) focusView(top); else Nav.focusFirst();
  }

  function updateUserBadge() {
    var b = U.$('#nav-user');
    if (!account) return;
    var i = U.$('i', b);
    i.textContent = initial(account.user);
    i.style.background = avatarColor(account.user);
    U.$('span', b).textContent = account.user + (accounts().length > 1 ? '  ⇄' : '');
  }

  // ---------------- Login
  var loginOpts = {};
  function showLogin(msg, opts) {
    loginOpts = opts || {};
    hideAllScreens();
    login.classList.remove('hidden');
    var pre = loginOpts.prefill;
    U.$('#in-url').value = (pre && pre.url) || U.store.get('lastUrl', '');
    U.$('#in-user').value = (pre && pre.user) || '';
    U.$('#in-pass').value = '';
    U.$('#login-msg').textContent = msg || '';
    U.$('#login-msg').className = 'msg';
    U.$('#btn-login-cancel').classList.toggle('hidden', !accounts().length);
    updateScope();
    Nav.focus(U.$('#in-url').value ? U.$('#in-user').value ? U.$('#in-pass') : U.$('#in-user') : U.$('#in-url'), { noInputFocus: true });
  }

  function cancelLogin() {
    if (account && stack.length && !loginOpts.adding) backToMain();
    else if (accounts().length) showUsers();
    else confirmExit();
  }

  function doLogin() {
    var url = U.$('#in-url').value, user = U.$('#in-user').value.trim(), pass = U.$('#in-pass').value;
    var msg = U.$('#login-msg');
    if (!url || !user || !pass) { msg.textContent = T('Bitte alle Felder ausfüllen.'); return; }
    var creds = API.makeCreds(url, user, pass);
    var prev = API.getConfig();
    API.setConfig(creds);
    msg.textContent = T('Verbinde …');
    msg.className = 'msg';
    API.ping().then(function () {
      var acc = Object.assign({ id: accId(creds.url, creds.user) }, creds);
      saveAccounts(accounts().filter(function (a) { return a.id !== acc.id; }).concat([acc]));
      U.store.set('lastUrl', creds.url);
      if (account && account.id === acc.id) { Player.detach(); account = null; } // gleiches Konto neu angemeldet -> frisch laden
      selectAccount(acc);
    }).catch(function (e) {
      API.setConfig(prev);
      msg.className = 'msg error';
      msg.textContent = e.code === 40 ? T('Benutzername oder Passwort falsch.') : T('Verbindung fehlgeschlagen: {msg}', { msg: e.message });
    });
  }

  function logout() {
    if (account) removeAccount(account); else showUsers();
  }

  // ---------------- Router
  function go(name, params, opts) {
    if (!Views[name]) return;
    var top = stack[stack.length - 1];
    if (top && top.name === name && JSON.stringify(top.params || {}) === JSON.stringify(params || {})) { focusView(top); return; }
    if (top) { top.scroll = top.view.el.scrollTop; top.focus = Nav.current(); }
    if (opts && opts.root) stack = [];
    var view = Views[name](params || {});
    var entry = { name: name, params: params, view: view };
    stack.push(entry);
    if (stack.length > 15) stack.splice(1, 1);
    mount(entry, true);
  }

  function mount(entry, fresh) {
    content.innerHTML = '';
    content.appendChild(entry.view.el);
    entry.view.el.scrollTop = entry.scroll || 0;
    U.$$('.nav-item').forEach(function (b) { b.classList.toggle('active', b.dataset.view === rootName()); });
    U.$('#miniplayer').classList.toggle('np-hidden', entry.name === 'nowplaying');
    syncMiniLayout();
    if (fresh) {
      entry.pendingFocus = true;
      // Fokus erst setzen, wenn Inhalte geladen sind (viewReady); bis dahin auf die Ansicht selbst
      var first = U.$('.focusable', entry.view.el);
      if (first && !entry.view.noAutoInput) Nav.focusFirst(entry.view.el);
    } else {
      focusView(entry);
    }
    UI.refreshPlaying();
  }

  function focusView(entry) {
    if (entry.focus && entry.view.el.contains(entry.focus)) Nav.focus(entry.focus);
    else Nav.focusFirst(entry.view.el);
  }

  // Ansichten melden, dass ihr Inhalt geladen ist
  function viewReady(el) {
    var top = stack[stack.length - 1];
    if (!top || top.view.el !== el || !top.pendingFocus) return;
    var cur = Nav.current();
    // Nur übernehmen, wenn der Nutzer nicht schon selbst navigiert hat
    if (!cur || !el.contains(cur) || cur === U.$('.focusable', el)) {
      if (U.$('.focusable[data-autofocus]', el) && top.view.noAutoInput) { /* Suchfeld: keine Tastatur aufpoppen */ }
      Nav.focusFirst(el);
    }
    top.pendingFocus = false;
  }

  function rootName() {
    for (var i = stack.length - 1; i >= 0; i--) {
      if (U.$('.nav-item[data-view="' + stack[i].name + '"]')) return stack[i].name;
    }
    return stack[0] && stack[0].name;
  }

  function back() {
    if (UI.closeModal()) return true;
    var cur = Nav.current();
    if (cur && cur.closest('#sidebar') && stack.length <= 1) { confirmExit(); return true; }
    if (stack.length > 1) {
      stack.pop();
      mount(stack[stack.length - 1], false);
      return true;
    }
    // In der Wurzelansicht: erst zur Seitenleiste
    var active = U.$('.nav-item.active') || U.$('.nav-item');
    Nav.focus(active);
    return true;
  }

  function reload() {
    var top = stack.pop();
    if (top) go(top.name, top.params);
  }

  function confirmExit() { UI.confirm(T('Tonalo beenden?'), T('Beenden'), exit); }
  function exit() {
    try { if (window.webOS && webOS.platformBack) { webOS.platformBack(); return; } } catch (e) { /* weiter */ }
    window.close();
  }

  // ---------------- Fehler
  function error(e) {
    console.error(e);
    U.toast(T('Fehler: {msg}', { msg: (e && e.message) || e }));
    if (e && e.code === 40 && account) showLogin(T('Anmeldung abgelaufen – bitte Passwort neu eingeben.'), { prefill: account, adding: true });
  }

  // ---------------- Mini-Player
  function updateMini(evt) {
    var s = Player.current();
    var mp = U.$('#miniplayer');
    mp.classList.toggle('hidden', !s);
    syncMiniLayout();
    if (!s) return;
    if (evt === 'track' || evt === 'init') {
      U.$('#mp-cover').src = API.cover(s.coverArt || s.albumId, 120);
      U.$('#mp-title').textContent = s.title;
      U.$('#mp-artist').textContent = s.artist || '';
      var heart = U.$('#mp-heart');
      heart.innerHTML = Icon.svg(s.starred ? 'heartFill' : 'heart');
      heart.classList.toggle('on', !!s.starred);
    }
    if (evt !== 'time') {
      U.$('#mp-play').innerHTML = Icon.svg(Player.paused() ? 'play' : 'pause');
      U.$('#mp-shuffle').classList.toggle('on', Player.shuffle());
      var r = Player.repeat();
      U.$('#mp-repeat').classList.toggle('on', r !== 'off');
      U.$('#mp-repeat').innerHTML = r === 'one' ? Icon.repeatOne() : Icon.svg('repeat');
    }
    var p = Player.position(), d = Player.duration();
    U.$('#mp-bar').style.width = (d ? Math.min(100, p / d * 100) : 0) + '%';
    U.$('#mp-pos').textContent = U.fmtTime(p);
    U.$('#mp-dur').textContent = U.fmtTime(d);
  }

  // Inhalt endet über dem Mini-Player, damit nichts dahinter verschwindet
  function syncMiniLayout() {
    var mp = U.$('#miniplayer');
    var visible = !mp.classList.contains('hidden') && !mp.classList.contains('np-hidden');
    main.classList.toggle('mini-on', visible);
    var cur = Nav.current();
    if (!visible && cur && mp.contains(cur) && !main.classList.contains('hidden')) {
      var top = stack[stack.length - 1];
      if (top) Nav.focusFirst(top.view.el);
    }
  }

  // ---------------- Bildschirmschoner (OLED-Schutz)
  var lastInput = Date.now(), ssActive = false, ssMoveTimer = null;
  function touch() { lastInput = Date.now(); }
  function ssCheck() {
    var mins = settings.screensaver;
    if (!mins || ssActive || main.classList.contains('hidden')) return;
    if (Date.now() - lastInput > mins * 60000) ssShow();
  }
  function ssShow() {
    ssActive = true;
    var s = Player.current();
    U.$('#ss-cover').style.display = s ? '' : 'none';
    if (s) U.$('#ss-cover').src = API.cover(s.coverArt || s.albumId, 400);
    U.$('#ss-title').textContent = s ? s.title : '';
    U.$('#ss-artist').textContent = s ? (s.artist || '') : '';
    U.$('#screensaver').classList.remove('hidden');
    ssMove();
    ssMoveTimer = setInterval(ssMove, 15000);
  }
  function ssMove() {
    var box = U.$('#ss-box');
    var x = Math.random() * (1920 - 520), y = Math.random() * (1080 - 620);
    box.style.transform = 'translate(' + Math.round(x) + 'px,' + Math.round(y) + 'px)';
    var d = new Date();
    U.$('#ss-clock').textContent = (d.getHours() < 10 ? '0' : '') + d.getHours() + ':' + (d.getMinutes() < 10 ? '0' : '') + d.getMinutes();
  }
  function ssHide() {
    ssActive = false;
    clearInterval(ssMoveTimer);
    U.$('#screensaver').classList.add('hidden');
    touch();
  }

  // webOS-eigenen Bildschirmschoner während der Wiedergabe unterdrücken (best effort, Luna-API)
  var lunaBridges = [];
  function luna(uri, params, cb) {
    if (typeof PalmServiceBridge === 'undefined') return;
    try {
      var b = new PalmServiceBridge();
      b.onservicecallback = function (msg) { try { if (cb) cb(JSON.parse(msg)); } catch (e) { /* egal */ } };
      b.call(uri, JSON.stringify(params || {}));
      lunaBridges.push(b);
      if (lunaBridges.length > 20) lunaBridges.splice(1, 1);
    } catch (e) { console.warn('luna', e); }
  }
  function blockTvScreensaver() {
    luna('luna://com.webos.service.tvpower/power/registerScreenSaverRequest', { subscribe: true, clientName: APP_ID }, function (msg) {
      if (!msg || !msg.timestamp) return;
      var playing = !Player.paused();
      luna('luna://com.webos.service.tvpower/power/responseScreenSaverRequest', { clientName: APP_ID, ack: !playing && !ssActive, timestamp: msg.timestamp });
    });
  }

  // ---------------- Tasten
  var seekHoldTimer = null, seekHeld = false;
  function keyHandler(e, code) {
    touch();
    if (ssActive) { ssHide(); return true; }
    if (main.classList.contains('hidden') && !UI.modalOpen()) {
      var typing = document.activeElement && document.activeElement.tagName === 'INPUT';
      if (code === K.BACK || code === K.ESC) {
        if (typing) { document.activeElement.blur(); return true; }
        if (!users.classList.contains('hidden')) { if (account && stack.length) backToMain(); else confirmExit(); }
        else cancelLogin();
        return true;
      }
      return false;
    }
    if (UI.modalOpen() && main.classList.contains('hidden')) {
      if (code === K.BACK || code === K.ESC) { UI.closeModal(); return true; }
      return false;
    }
    var inInput = document.activeElement && document.activeElement.tagName === 'INPUT';
    if (code === K.BACK || code === K.ESC || (code === K.BACKSPACE && !inInput)) {
      if (inInput) { document.activeElement.blur(); return true; }
      return back();
    }
    switch (code) {
      case K.PLAY: Player.play(); return true;
      case K.PAUSE: Player.pause(); return true;
      case K.PLAYPAUSE: case K.BLUE: Player.toggle(); return true;
      case K.STOP: Player.pause(); Player.seek(0); return true;
      case K.NEXT: Player.next(); return true;
      case K.PREV: Player.prev(); return true;
      case K.FF: case K.RW:
        // kurz: ±10 s spulen, gedrückt halten: Titel wechseln
        if (e.repeat) {
          if (!seekHeld) { seekHeld = true; if (code === K.FF) Player.next(); else Player.prev(); }
          return true;
        }
        seekHeld = false;
        Player.seekBy(code === K.FF ? 10 : -10);
        return true;
      case K.RED: go('nowplaying'); return true;
      case K.GREEN: go('search'); return true;
      case K.CH_UP: case K.CH_DOWN:
        for (var i = 0; i < 4; i++) Nav.move(code === K.CH_UP ? 'up' : 'down');
        return true;
    }
    return false;
  }

  // ---------------- Start
  function startMain() {
    hideAllScreens();
    main.classList.remove('hidden');
    updateScope();
    Player.restore();
    updateMini('init');
    updateUserBadge();
    offerRemoteQueue();
    stack = [];
    go(settings.startView === 'nowplaying' && !Player.current() ? 'home' : settings.startView, null, { root: true });
  }

  // Lief zuletzt auf einem anderen Gerät (z. B. dem iPhone) etwas, kann der TV dort weitermachen
  var offerModal = null; // das offene „Weiterhören?“-Fenster, sonst null
  function offerRemoteQueue() {
    if (!account || (UI.modalOpen() && !offerModal)) return;
    Player.checkRemote().then(function (o) {
      if (!o) return;
      // Ein älteres Angebot durch das aktuelle ersetzen – andere offene Dialoge aber nie anfassen
      if (offerModal) offerModal.close();
      else if (UI.modalOpen()) return;
      var s = o.songs[o.index];
      var m = UI.modal(null, [
        { icon: 'play', label: T('Hier weiterhören'), action: function () { Player.take(o, true); } },
        { icon: 'close', label: T('Nein, danke'), action: function () { Player.dismissRemote(o); } }
      ], { head: { coverId: s.coverArt || s.albumId, title: T('Weiterhören vom {device}?', { device: o.device }),
        sub: s.title + (s.artist ? ' · ' + s.artist : '') } });
      offerModal = m;
      // Egal wie es zugeht (Knopf, Zurück-Taste, ersetzt): danach gilt es als geschlossen
      var close = m.close;
      m.close = function () { if (offerModal === m) offerModal = null; close(); };
      m.box.addEventListener('click', function () { if (offerModal === m) offerModal = null; });
    });
  }

  function init() {
    content = U.$('#content'); main = U.$('#main'); login = U.$('#login'); users = U.$('#users');
    // Icon-Platzhalter im HTML durch SVGs ersetzen
    I18N.applyStatic(document);
    U.$$('[data-icon]').forEach(function (i) { i.outerHTML = Icon.svg(i.getAttribute('data-icon'), +(i.getAttribute('data-size') || 24)); });
    fit();
    window.addEventListener('resize', fit);
    // App wieder im Vordergrund (webOS hält Apps im Hintergrund am Leben)
    document.addEventListener('visibilitychange', function () {
      if (!document.hidden && !main.classList.contains('hidden')) offerRemoteQueue();
    });
    document.addEventListener('webOSRelaunch', function () { if (!main.classList.contains('hidden')) offerRemoteQueue(); });
    updateScope();
    Nav.onKey(keyHandler);
    document.addEventListener('mousemove', function () { if (ssActive) ssHide(); else touch(); });
    document.addEventListener('click', function (e) { if (ssActive) { e.stopPropagation(); ssHide(); } }, true);
    setInterval(ssCheck, 10000);

    U.$$('.nav-item').forEach(function (b) {
      b.addEventListener('click', function () { go(b.dataset.view, null, { root: true }); });
    });
    U.$('#sidebar').classList.add('nav-container');
    U.$('#miniplayer')._lastFocused = U.$('#mp-play'); // beim ersten Betreten auf Play/Pause landen
    U.$('#mp-info').addEventListener('click', function () { go('nowplaying'); });
    U.$('#mp-open').addEventListener('click', function () { go('nowplaying'); });
    U.$('#mp-play').addEventListener('click', function () { Player.toggle(); });
    U.$('#mp-prev').addEventListener('click', function () { Player.prev(); });
    U.$('#mp-next').addEventListener('click', function () { Player.next(); });
    U.$('#mp-shuffle').addEventListener('click', function () { Player.setShuffle(!Player.shuffle()); });
    U.$('#mp-repeat').addEventListener('click', function () { Player.cycleRepeat(); });
    U.$('#mp-queue').addEventListener('click', function () { go('queue'); });
    U.$('#mp-lyrics').addEventListener('click', function () { U.ustore.set('lyricsOn', true); go('nowplaying'); });
    U.$('#mp-heart').addEventListener('click', function () {
      var s = Player.current(); if (!s) return;
      var on = !s.starred;
      API.star('song', s.id, on).then(function () {
        Player.setStarred(s, on);
        U.toast(on ? T('Zu Favoriten hinzugefügt') : T('Aus Favoriten entfernt'));
      }).catch(error);
    });

    U.$('#nav-user').addEventListener('click', showUsers);
    U.$('#btn-login').addEventListener('click', doLogin);
    U.$('#btn-login-cancel').addEventListener('click', cancelLogin);
    ['#in-url', '#in-user', '#in-pass'].forEach(function (sel, i, arr) {
      U.$(sel).addEventListener('keydown', function (e) {
        if (e.keyCode !== 13) return;
        e.preventDefault(); e.stopPropagation();
        U.$(sel).blur();
        if (i < arr.length - 1) Nav.focus(U.$(arr[i + 1]), { noInputFocus: true });
        else { Nav.focus(U.$('#btn-login')); doLogin(); }
      });
    });

    ['track', 'state', 'time', 'queue', 'mode'].forEach(function (evt) {
      Player.on(evt, function () {
        updateMini(evt);
        if (evt === 'track') UI.refreshPlaying();
        var top = stack[stack.length - 1];
        if (top && top.view.update) top.view.update(evt);
      });
    });

    document.addEventListener('webOSRelaunch', function () { touch(); if (ssActive) ssHide(); });
    document.addEventListener('visibilitychange', function () { if (!document.hidden) touch(); });
    blockTvScreensaver();

    // Beim Start immer die Benutzerauswahl zeigen (oder Login, wenn noch kein Konto existiert)
    migrate();
    if (accounts().length) showUsers(); else showLogin();
  }

  return {
    init: init, go: go, back: back, reload: reload, viewReady: viewReady, updateScope: updateScope,
    error: error, logout: logout, exit: exit, showUsers: showUsers,
    account: function () { return account; },
    accountCount: function () { return accounts().length; },
    settings: function () { return settings; },
    setSetting: function (k, v) { settings[k] = v; U.ustore.set('settings', settings); touch(); }
  };
})();

document.addEventListener('DOMContentLoaded', App.init);
