/* Tonalo demo: a mock of the iPhone app with sample songs. It plays no music and talks to no server.
   Screens and texts follow the real app (Player, Settings > Jukebox, Settings > Devices). */
(function () {
  var root = document.getElementById('demo-app');
  if (!root) return;
  var lang = (document.documentElement.lang || 'en').slice(0, 2) === 'de' ? 'de' : 'en';

  var T = {
    en: {
      tabs: { player: 'Player', jukebox: 'Jukebox', devices: 'Devices' },
      yours: 'Your phone', friends: "Friend's phone",
      playing: 'PLAYING MIX', mix: 'Demo', upNext: 'Up next', queue: 'Queue',
      drag: 'Hold a song in the queue and drag it where you want it.',
      settings: 'Settings', jukebox: 'Jukebox', devices: 'Devices',
      yourJb: 'Your Jukebox', hostJb: 'Host a Jukebox',
      hostFoot: "Friends nearby join with a code shown on this iPhone, add songs to what's playing and skip. Works in the car too: the phones connect directly, without Wi-Fi. They need an account on the same server.",
      joinJb: 'Join a Jukebox', joinNone: 'Nothing found. A Jukebox shows up here while Tonalo is open on a TV, computer or iPhone nearby.',
      joinFoot: "As a guest you add songs to what's playing there and skip. You need an account on the same server.",
      join: 'Join', joined: 'Joined', here: 'Here', end: 'End', leave: 'Leave', cancel: 'Cancel',
      waiting: 'Jukebox · waiting for guests', jbWith: function (n) { return 'Jukebox · ' + n; },
      wants: function (n) { return n + ' wants to join the Jukebox'; }, showCode: function (n) { return 'Show this code to ' + n + '.'; },
      enter: function (n) { return 'Enter the code shown on ' + n; }, bad: "That code doesn't match. Look at the other screen and try again.",
      added: 'Added to the Jukebox', songs: 'Songs', addQ: 'Add to queue',
      nearby: 'Nearby', connect: 'Connect', connected: 'Connected', paired: 'Paired', connecting: function (n) { return 'Connecting to ' + n + ' …'; },
      devFoot: "Your own TV or computer: while it plays, this app shows what's playing there, and music you pick here plays on it. Nothing goes through the internet.",
      playingOn: function (n) { return 'Playing on ' + n; }, onPhone: 'Play on iPhone',
      home: 'Home', search: 'Search', library: 'Your Library',
      play: 'Play', pause: 'Pause', next: 'Next', prev: 'Previous', heart: 'Favorite', shuffle: 'Shuffle', repeat: 'Repeat',
      guest: 'Sam', phone: "Alex's iPhone", tv: 'Living Room', tvWait: 'Waiting for your phone', tvShow: 'Show this code to your phone.',
      back: 'Back'
    },
    de: {
      tabs: { player: 'Player', jukebox: 'Jukebox', devices: 'Geräte' },
      yours: 'Dein Handy', friends: 'Handy eines Freundes',
      playing: 'MIX-WIEDERGABE', mix: 'Demo', upNext: 'Als Nächstes', queue: 'Warteschlange',
      drag: 'Halte in der Warteschlange einen Song gedrückt und zieh ihn dahin, wo du ihn haben willst.',
      settings: 'Zurück', jukebox: 'Jukebox', devices: 'Geräte',
      yourJb: 'Deine Jukebox', hostJb: 'Jukebox starten',
      hostFoot: 'Freunde in der Nähe treten mit einem Code bei, den dieses iPhone anzeigt, fügen Songs hinzu und überspringen. Klappt auch im Auto: Die Handys verbinden sich direkt, ohne WLAN. Sie brauchen ein Konto auf demselben Server.',
      joinJb: 'Einer Jukebox beitreten', joinNone: 'Nichts gefunden. Eine Jukebox erscheint hier, solange Tonalo auf einem Fernseher, Computer oder iPhone in der Nähe offen ist.',
      joinFoot: 'Als Gast fügst du Songs zu dem hinzu, was dort läuft, und überspringst. Du brauchst ein Konto auf demselben Server.',
      join: 'Beitreten', joined: 'Beigetreten', here: 'Dabei', end: 'Beenden', leave: 'Verlassen', cancel: 'Abbrechen',
      waiting: 'Jukebox · wartet auf Gäste', jbWith: function (n) { return 'Jukebox · ' + n; },
      wants: function (n) { return n + ' möchte der Jukebox beitreten'; }, showCode: function (n) { return 'Zeig ' + n + ' diesen Code.'; },
      enter: function (n) { return 'Gib den Code ein, den ' + n + ' anzeigt'; }, bad: 'Der Code stimmt nicht. Schau noch mal auf den anderen Bildschirm.',
      added: 'Zur Jukebox hinzugefügt', songs: 'Songs', addQ: 'Zur Warteschlange hinzufügen',
      nearby: 'In der Nähe', connect: 'Verbinden', connected: 'Verbunden', paired: 'Gekoppelt', connecting: function (n) { return 'Verbinde mit ' + n + ' …'; },
      devFoot: 'Dein eigener Fernseher oder Computer: Während er spielt, zeigt dir die App, was dort läuft, und Musik, die du hier auswählst, spielt dort. Nichts geht über das Internet.',
      playingOn: function (n) { return 'Läuft auf: ' + n; }, onPhone: 'Auf dem iPhone',
      home: 'Start', search: 'Suchen', library: 'Bibliothek',
      play: 'Abspielen', pause: 'Pause', next: 'Weiter', prev: 'Zurück', heart: 'Favorit', shuffle: 'Zufall', repeat: 'Wiederholen',
      guest: 'Sam', phone: 'iPhone von Alex', tv: 'Wohnzimmer', tvWait: 'Wartet auf dein Handy', tvShow: 'Zeig deinem Handy diesen Code.',
      back: 'Zurück'
    }
  };
  var t = T[lang];

  // Songs, albums and artists come from the demo library that is already in the app's screenshots.
  var SONGS = [
    { id: 'lucid', title: 'Lucid Shadows', artist: 'Nora Vale', album: 'SILVER WEATHER', len: 227, g: 'linear-gradient(135deg,#ffd36e 0%,#ff9a62 55%,#ff6b6b 100%)', tint: '#7b4f36', deep: '#1f130d', kind: 'rings' },
    { id: 'paper', title: 'Paper Letters', artist: 'Lumen Drift', album: 'GLASS MOON', len: 201, g: 'linear-gradient(135deg,#5ee08a 0%,#1fa56a 55%,#0f6e66 100%)', tint: '#2f6b4c', deep: '#0b1d15', kind: 'stripes' },
    { id: 'salt', title: 'Salt and Static', artist: 'Saffron Lane', album: 'SALT AND STATIC', len: 214, g: 'linear-gradient(135deg,#6ec6ff 0%,#3b82f6 55%,#2b3fa8 100%)', tint: '#2f5c98', deep: '#0b1426', kind: 'rings' },
    { id: 'faded', title: 'Faded Machines', artist: 'Nora Vale', album: 'SILVER WEATHER', len: 188, g: 'linear-gradient(135deg,#ffd36e 0%,#ff9a62 55%,#ff6b6b 100%)', tint: '#7b4f36', deep: '#1f130d', kind: 'rings' }
  ];
  function song(id) { for (var i = 0; i < SONGS.length; i++) if (SONGS[i].id === id) return SONGS[i]; }
  function idx(id) { for (var i = 0; i < SONGS.length; i++) if (SONGS[i].id === id) return i; return 0; }
  function esc(x) { return String(x).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function code6() { return ('000000' + Math.floor(Math.random() * 1000000)).slice(-6); }
  function fmt(sec) { sec = Math.max(0, sec); var m = Math.floor(sec / 60), s = Math.floor(sec % 60); return m + ':' + (s < 10 ? '0' : '') + s; }
  function spaced(c) { return c.slice(0, 3) + ' ' + c.slice(3); }

  var S = {
    tab: 'player', playing: true, now: 'lucid', pos: 0, hearted: false,
    queue: ['paper', 'salt'],
    jb: { on: false, req: null, joined: false, toast: '', friendSheet: false, friendErr: '' },
    tv: { sheet: false, code: '', err: '', paired: false, onTv: false }
  };

  function ic(name) {
    var P = {
      play: '<path fill="currentColor" d="M7 4.6v14.8a1 1 0 001.5.86l12-7.4a1 1 0 000-1.72l-12-7.4A1 1 0 007 4.6z"/>',
      pause: '<path fill="currentColor" d="M6.5 4h4v16h-4zM13.5 4h4v16h-4z"/>',
      next: '<path fill="currentColor" d="M4 5.4v13.2a1 1 0 001.5.86L15 13.4v5.2a1.4 1.4 0 002.8 0V5.4a1.4 1.4 0 00-2.8 0v5.2L5.5 4.54A1 1 0 004 5.4z"/>',
      prev: '<path fill="currentColor" d="M20 5.4v13.2a1 1 0 01-1.5.86L9 13.4v5.2a1.4 1.4 0 01-2.8 0V5.4a1.4 1.4 0 012.8 0v5.2l9.5-5.86A1 1 0 0120 5.4z"/>',
      heart: '<path d="M12 20.4S3.6 15.3 3.6 9.2A4.7 4.7 0 0112 6.6a4.7 4.7 0 018.4 2.6c0 6.1-8.4 11.2-8.4 11.2z" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linejoin="round"/>',
      heartf: '<path d="M12 20.4S3.6 15.3 3.6 9.2A4.7 4.7 0 0112 6.6a4.7 4.7 0 018.4 2.6c0 6.1-8.4 11.2-8.4 11.2z" fill="currentColor" stroke="currentColor" stroke-width="1.7" stroke-linejoin="round"/>',
      shuffle: '<g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7h3.5c5 0 6.5 10 11.5 10H21M3 17h3.5c1.8 0 3-.9 4-2.2M13.5 9.2C14.6 7.9 16 7 18 7h3"/><path d="M18.5 4.5L21 7l-2.5 2.5M18.5 14.5L21 17l-2.5 2.5"/></g>',
      repeat: '<g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 11V9.5A2.5 2.5 0 016.5 7H20M17 4l3 3-3 3M20 13v1.5a2.5 2.5 0 01-2.5 2.5H4M7 20l-3-3 3-3"/></g>',
      down: '<path fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" d="M5 9l7 7 7-7"/>',
      left: '<path fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" d="M15 5l-7 7 7 7"/>',
      dots: '<path fill="currentColor" d="M5 10.6a1.4 1.4 0 110 2.8 1.4 1.4 0 010-2.8zm7 0a1.4 1.4 0 110 2.8 1.4 1.4 0 010-2.8zm7 0a1.4 1.4 0 110 2.8 1.4 1.4 0 010-2.8z"/>',
      lyrics: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M4 5h16a1 1 0 011 1v10a1 1 0 01-1 1h-8l-5 3.5V17H4a1 1 0 01-1-1V6a1 1 0 011-1z"/></g><path fill="currentColor" d="M8.5 8.5h2.3v2.3c0 1.2-.6 2-1.7 2.3l-.4-.8c.6-.2.9-.6.9-1.1H8.5zM13 8.5h2.3v2.3c0 1.2-.6 2-1.7 2.3l-.4-.8c.6-.2.9-.6.9-1.1H13z"/>',
      list: '<g fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M9 6h12M9 12h12M9 18h12M3.5 6h.01M3.5 12h.01M3.5 18h.01"/></g>',
      tv: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="4" width="19" height="13" rx="2"/><path d="M8 21h8M12 17v4"/></g>',
      people: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="9" cy="8.5" r="3"/><path d="M3.5 19c.5-3 2.6-4.7 5.5-4.7s5 1.7 5.5 4.7M16.5 5.5a3 3 0 010 6M18.5 14.7c1.4.7 2.3 2 2.6 3.8"/></g>',
      link: '<g fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"><path d="M10 14a4 4 0 005.7 0l3-3A4 4 0 0013 5.3l-1 1M14 10a4 4 0 00-5.7 0l-3 3A4 4 0 0011 18.7l1-1"/></g>',
      plus: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="9"/><path d="M12 8v8M8 12h8"/></g>',
      home: '<path fill="currentColor" d="M12 3.2l9 7.6V21h-6.2v-6H9.2v6H3V10.8z"/>',
      searchi: '<g fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"><circle cx="10.5" cy="10.5" r="6.5"/><path d="M15.5 15.5L21 21"/></g>',
      lib: '<g fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><rect x="3" y="4" width="4.5" height="16" rx="1"/><rect x="9.5" y="4" width="4.5" height="16" rx="1"/><path d="M16 5.4l4-1 3 14.6-4 1z"/></g>',
      grip: '<path fill="currentColor" d="M5 7h14v1.8H5zM5 11.1h14v1.8H5zM5 15.2h14v1.8H5z"/>'
    };
    return '<svg viewBox="0 0 24 24" aria-hidden="true">' + (P[name] || '') + '</svg>';
  }

  function cover(sg, size) {
    var art = sg.kind === 'stripes'
      ? '<i class="stripes"></i>'
      : '<svg class="rings" viewBox="0 0 100 100" aria-hidden="true"><g fill="none" stroke="#fff" stroke-opacity=".28" stroke-width="3.2"><circle cx="50" cy="50" r="40"/><circle cx="50" cy="50" r="31"/><circle cx="50" cy="50" r="22"/><circle cx="50" cy="50" r="13"/></g></svg>';
    return '<span class="cv ' + (size || '') + '" style="background:' + sg.g + '">' + art + '<b class="cap">' + esc(sg.album) + '</b></span>';
  }

  // ---------- chrome ----------
  var STATUS = '<div class="st"><span>9:41</span><span class="gl"><svg viewBox="0 0 24 24" width="17" height="17" aria-hidden="true"><path fill="currentColor" d="M2 17h3v4H2zM7 13h3v8H7zM12 9h3v12h-3zM17 4.5h3V21h-3z"/></svg><svg viewBox="0 0 24 24" width="17" height="17" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" d="M3 9.5a13 13 0 0118 0M6 13a8.5 8.5 0 0112 0M9.2 16.4a4 4 0 015.6 0"/><circle cx="12" cy="19.4" r="1.4" fill="currentColor"/></svg><i class="bat"><i></i></i></span></div>';

  function tabbar() {
    return '<div class="tb" aria-hidden="true"><span class="on">' + ic('home') + '<small>' + t.home + '</small></span><span>' + ic('searchi') + '<small>' + t.search + '</small></span><span>' + ic('lib') + '<small>' + t.library + '</small></span></div>';
  }

  function tvbar() {
    if (!S.tv.onTv) return '';
    return '<div class="bar-pill"><span class="bi">' + ic('tv') + '</span><span class="bt">' + esc(t.playingOn(t.tv)) + '</span><button type="button" data-act="onphone">' + t.onPhone + '</button></div>';
  }
  function jbbar() {
    if (!S.jb.on) return '';
    return '<div class="bar-pill"><span class="bi">' + ic('people') + '</span><span class="bt">' + (S.jb.joined ? esc(t.jbWith(t.guest)) : t.waiting) + '</span><button type="button" data-act="jbend">' + t.end + '</button></div>';
  }

  function mini() {
    var sg = song(S.now);
    return '<div class="mini" style="background:' + sg.tint + '">' + cover(sg, 'xs') + '<span class="tx"><b>' + esc(sg.title) + '</b><small>' + esc(sg.artist) + '</small></span>' +
      '<button type="button" class="hrt' + (S.hearted ? ' on' : '') + '" data-act="heart" aria-pressed="' + S.hearted + '" aria-label="' + t.heart + '">' + ic(S.hearted ? 'heartf' : 'heart') + '</button>' +
      '<button type="button" data-act="toggle" aria-label="' + (S.playing ? t.pause : t.play) + '">' + ic(S.playing ? 'pause' : 'play') + '</button>' +
      '<i class="mp"><i style="width:' + (S.pos / song(S.now).len * 100) + '%"></i></i></div>';
  }

  // ---------- screens ----------
  function queueRows(readonly) {
    var h = '<ul class="q" id="d-q">';
    S.queue.forEach(function (id) {
      var sg = song(id);
      h += '<li data-id="' + id + '"' + (readonly ? '' : ' tabindex="0"') + ' aria-label="' + esc(sg.title + ', ' + sg.artist) + '">' + cover(sg, 'sm') + '<span class="tx"><b>' + esc(sg.title) + '</b><small>' + esc(sg.artist) + '</small></span>' + (readonly ? '' : '<span class="grip" aria-hidden="true">' + ic('grip') + '</span>') + '</li>';
    });
    return h + '</ul>';
  }

  function screenPlayer() {
    var sg = song(S.now), rem = sg.len - S.pos;
    return '<div class="scr player" style="background:linear-gradient(' + sg.tint + ' 0%,' + sg.deep + ' 62%,#000 100%)">' + STATUS +
      '<div class="ph"><span class="ci">' + ic('down') + '</span><span class="pt"><small>' + t.playing + '</small><b>' + t.mix + '</b></span><span class="ci">' + ic('dots') + '</span></div>' +
      '<div class="art">' + cover(sg, 'lg') + '</div>' +
      '<div class="ti"><div class="tt"><b>' + esc(sg.title) + '</b><span>' + esc(sg.artist) + '</span></div>' +
      '<button type="button" class="hrt big' + (S.hearted ? ' on' : '') + '" data-act="heart" aria-pressed="' + S.hearted + '" aria-label="' + t.heart + '">' + ic(S.hearted ? 'heartf' : 'heart') + '</button></div>' +
      '<div class="pr"><i class="trk"><i class="fill" style="width:' + (S.pos / sg.len * 100) + '%"></i><i class="knob" style="left:' + (S.pos / sg.len * 100) + '%"></i></i><div class="tm"><span id="d-pos">' + fmt(S.pos) + '</span><span id="d-rem">-' + fmt(rem) + '</span></div></div>' +
      '<div class="ct"><span class="ci" aria-hidden="true">' + ic('shuffle') + '</span><button type="button" data-act="prev" aria-label="' + t.prev + '">' + ic('prev') + '</button>' +
      '<button type="button" class="pp" data-act="toggle" aria-label="' + (S.playing ? t.pause : t.play) + '">' + ic(S.playing ? 'pause' : 'play') + '</button>' +
      '<button type="button" data-act="next" aria-label="' + t.next + '">' + ic('next') + '</button><span class="ci" aria-hidden="true">' + ic('repeat') + '</span></div>' +
      '<div class="ex" aria-hidden="true"><span class="ci">' + ic('lyrics') + '</span><span class="ci">' + ic('list') + '</span></div>' +
      (S.tv.onTv ? '<div class="pad">' + tvbar() + '</div>' : '') +
      '<div class="qb"><h4>' + t.upNext + '</h4>' + (S.queue.length ? queueRows(false) : '') + '<p class="hint">' + t.drag + '</p></div></div>';
  }

  function toggleHtml(on, disabled, act) {
    return '<button type="button" class="sw' + (on ? ' on' : '') + '" role="switch" aria-checked="' + on + '"' + (disabled ? ' disabled' : '') + (act ? ' data-act="' + act + '"' : '') + '><i></i></button>';
  }

  function screenJukebox(friend) {
    var h = '<div class="scr list">' + STATUS + '<div class="nb"><span class="bk">' + ic('left') + '<small>' + t.settings + '</small></span><b>' + t.jukebox + '</b><span class="sp"></span></div><div class="lst">';
    h += '<h5>' + t.yourJb + '</h5><div class="grp"><div class="row"><span class="ri">' + ic('people') + '</span><span class="rt">' + t.hostJb + '</span>' + (friend ? toggleHtml(false, true) : toggleHtml(S.jb.on, false, 'host')) + '</div>';
    if (!friend && S.jb.joined) h += '<div class="row"><span class="ri">' + ic('people') + '</span><span class="rt">' + esc(t.guest) + '</span><span class="rv">' + t.here + '</span></div>';
    h += '</div><p class="ft">' + t.hostFoot + '</p>';
    h += '<h5>' + t.joinJb + '</h5><div class="grp">';
    if (friend && S.jb.on) {
      h += '<div class="row"><span class="ri">' + ic('people') + '</span><span class="rt">' + esc(t.phone) + '</span>' + (S.jb.joined ? '<span class="rv">' + t.joined + '</span>' : '<button type="button" class="rl" data-act="fjoin">' + t.join + '</button>') + '</div>';
    } else {
      h += '<div class="row none">' + t.joinNone + '</div>';
    }
    h += '</div><p class="ft">' + t.joinFoot + '</p>';
    if (friend && S.jb.joined) {
      h += '<h5>' + t.songs + '</h5><div class="grp">';
      SONGS.forEach(function (sg) {
        var q = S.queue.indexOf(sg.id) > -1 || S.now === sg.id;
        h += '<div class="row sg">' + cover(sg, 'sm') + '<span class="tx"><b>' + esc(sg.title) + '</b><small>' + esc(sg.artist) + '</small></span><button type="button" class="ci add" data-act="gadd" data-id="' + sg.id + '" aria-label="' + esc(t.addQ + ': ' + sg.title) + '"' + (q ? ' disabled' : '') + '>' + ic('plus') + '</button></div>';
      });
      h += '</div>';
    }
    if (!friend && S.jb.on) h += '<h5>' + t.queue + '</h5>' + (S.queue.length ? '<div class="grp qg">' + queueRows(true) + '</div>' : '');
    h += '</div>';
    var bottom = '';
    if (friend) { if (S.jb.joined) bottom = '<div class="bar-pill"><span class="bi">' + ic('people') + '</span><span class="bt">' + esc(t.jbWith(t.phone)) + '</span><button type="button" data-act="fleave">' + t.leave + '</button></div>'; }
    else bottom = jbbar();
    h += '<div class="dock">' + (bottom ? '<div class="pad">' + bottom + '</div>' : '') + (friend ? '' : mini()) + tabbar() + '</div>';
    if (S.jb.toast && friend) h += '<div class="toast">' + S.jb.toast + '</div>';
    if (!friend && S.jb.req) h += '<div class="sheet"><div class="sc"><span class="ssi">' + ic('people') + '</span><b class="sh">' + esc(t.wants(t.guest)) + '</b><div class="code">' + spaced(S.jb.req) + '</div><p class="sub">' + esc(t.showCode(t.guest)) + '</p><button type="button" class="link" data-act="jbcancel">' + t.cancel + '</button></div></div>';
    if (friend && S.jb.friendSheet) h += pairSheet(t.phone, 'people', 'join', S.jb.friendErr, 'fcancel');
    return h + '</div>';
  }

  function pairSheet(name, icon, form, err, cancelAct) {
    return '<div class="sheet"><form class="sc" data-form="' + form + '"><span class="ssi">' + ic(icon) + '</span><b class="sh">' + esc(t.enter(name)) + '</b>' +
      '<input class="codein" inputmode="numeric" autocomplete="one-time-code" maxlength="7" placeholder="000000" aria-label="' + esc(t.enter(name)) + '">' +
      '<p class="err" role="alert">' + (err || '') + '</p><button type="button" class="link" data-act="' + cancelAct + '">' + t.cancel + '</button></form></div>';
  }

  function screenDevices() {
    var h = '<div class="scr list">' + STATUS + '<div class="nb"><span class="bk">' + ic('left') + '<small>' + t.settings + '</small></span><b>' + t.devices + '</b><span class="sp"></span></div><div class="lst">';
    h += '<h5>' + t.nearby + '</h5><div class="grp"><div class="row"><span class="ri">' + ic('tv') + '</span><span class="rt">' + t.tv + '</span>' + (S.tv.paired ? '<span class="rv">' + t.connected + '</span>' : '<button type="button" class="rl" data-act="connect">' + t.connect + '</button>') + '</div></div><p class="ft">' + t.devFoot + '</p>';
    if (S.tv.paired) h += '<h5>' + t.paired + '</h5><div class="grp"><div class="row"><span class="ri">' + ic('link') + '</span><span class="rt">' + t.tv + '</span></div></div>';
    h += '</div><div class="dock">' + (S.tv.onTv ? '<div class="pad">' + tvbar() + '</div>' : '') + mini() + tabbar() + '</div>';
    if (S.tv.sheet) h += pairSheet(t.tv, 'tv', 'pair', S.tv.err, 'pcancel');
    return h + '</div>';
  }

  function screenTv() {
    var sg = song(S.now), body;
    if (!S.tv.sheet && !S.tv.paired) body = '<div class="tvc"><img src="/favicon.svg" alt="" width="40" height="40"><b>Tonalo</b><small>' + t.tvWait + '</small></div>';
    else if (S.tv.sheet) body = '<div class="tvc"><small>' + t.tvShow + '</small><div class="code tvcode">' + spaced(S.tv.code) + '</div></div>';
    else if (S.tv.onTv) body = '<div class="tvn" style="background:linear-gradient(110deg,' + sg.tint + ',' + sg.deep + ')">' + cover(sg, 'tvl') + '<div class="tvi"><b>' + esc(sg.title) + '</b><span>' + esc(sg.artist) + '</span><i class="trk"><i class="fill" style="width:' + (S.pos / sg.len * 100) + '%"></i></i></div></div>';
    else body = '<div class="tvc"><img src="/favicon.svg" alt="" width="40" height="40"><b>Tonalo</b><small>' + t.paired + '</small></div>';
    return '<div class="tvbox"><div class="tvs">' + body + '</div></div>';
  }

  // ---------- render ----------
  root.innerHTML = '<div class="d-tabs" role="tablist" aria-label="Demo"></div><div class="d-stage" id="d-panel" role="tabpanel" aria-label="Demo"><div class="d-col" id="d-a"></div><div class="d-col" id="d-b"></div></div><p class="d-hint" id="d-hint"></p><div class="d-live" id="d-live" aria-live="polite"></div>';
  var tabsEl = root.querySelector('.d-tabs'), colA = root.querySelector('#d-a'), colB = root.querySelector('#d-b'), hintEl = root.querySelector('#d-hint'), liveEl = root.querySelector('#d-live');
  function say(m) { liveEl.textContent = ''; setTimeout(function () { liveEl.textContent = m; }, 20); }
  function frame(label, inner) { return '<div class="d-label">' + label + '</div><div class="d-phone"><i class="isl"></i>' + inner + '</div>'; }

  function render() {
    var h = '';
    ['player', 'jukebox', 'devices'].forEach(function (k) { h += '<button type="button" role="tab" id="tab-' + k + '" aria-selected="' + (S.tab === k) + '" aria-controls="d-panel" tabindex="' + (S.tab === k ? 0 : -1) + '" data-tab="' + k + '">' + t.tabs[k] + '</button>'; });
    tabsEl.innerHTML = h;
    var a = S.tab === 'player' ? screenPlayer() : S.tab === 'jukebox' ? screenJukebox(false) : screenDevices();
    colA.innerHTML = frame(t.yours, a);
    if (S.tab === 'jukebox') { colB.innerHTML = frame(t.friends, screenJukebox(true)); colB.hidden = false; }
    else if (S.tab === 'devices') { colB.innerHTML = '<div class="d-label">' + t.tv + '</div>' + screenTv(); colB.hidden = false; }
    else { colB.innerHTML = '<div class="d-label">' + t.home + '</div><div class="d-real"><img src="/img/ios/home.jpg" width="600" height="1304" alt="" loading="lazy"></div>'; colB.hidden = false; }
    hintEl.hidden = true;
  }

  // ---------- behaviour ----------
  function nextSong(dir) {
    if (dir > 0) { S.now = S.queue.length ? S.queue.shift() : SONGS[(idx(S.now) + 1) % SONGS.length].id; }
    else { S.now = SONGS[(idx(S.now) + SONGS.length - 1) % SONGS.length].id; }
    S.pos = 0; S.hearted = false;
  }
  setInterval(function () {
    if (!S.playing) return;
    var sg = song(S.now); S.pos += 1;
    if (S.pos >= sg.len) { nextSong(1); render(); return; }
    var w = (S.pos / sg.len * 100) + '%';
    root.querySelectorAll('.trk .fill, .mp i').forEach(function (el) { el.style.width = w; });
    root.querySelectorAll('.trk .knob').forEach(function (el) { el.style.left = w; });
    var p = root.querySelector('#d-pos'), r = root.querySelector('#d-rem');
    if (p) p.textContent = fmt(S.pos); if (r) r.textContent = '-' + fmt(sg.len - S.pos);
  }, 1000);

  var opener = null;
  function focusSheet() { var i = root.querySelector('.sheet input'); if (i) i.focus(); }
  function backToOpener() { if (opener) { var el = root.querySelector('[data-act="' + opener + '"]'); if (el) el.focus(); opener = null; } }

  root.addEventListener('click', function (e) {
    var tb = e.target.closest('[data-tab]');
    if (tb) { S.tab = tb.dataset.tab; S.jb.toast = ''; render(); var el = root.querySelector('#tab-' + S.tab); if (el) el.focus(); return; }
    var b = e.target.closest('[data-act]');
    if (!b || b.disabled) return;
    var a = b.dataset.act, sheet = false;
    if (a === 'toggle') S.playing = !S.playing;
    else if (a === 'next') nextSong(1);
    else if (a === 'prev') nextSong(-1);
    else if (a === 'heart') S.hearted = !S.hearted;
    else if (a === 'host') { if (S.jb.on) { S.jb = { on: false, req: null, joined: false, toast: '', friendSheet: false, friendErr: '' }; } else { S.jb.on = true; say(t.waiting); } }
    else if (a === 'jbend') S.jb = { on: false, req: null, joined: false, toast: '', friendSheet: false, friendErr: '' };
    else if (a === 'fjoin') { S.jb.req = code6(); S.jb.friendSheet = true; S.jb.friendErr = ''; sheet = true; opener = 'fjoin'; }
    else if (a === 'fcancel') { S.jb.friendSheet = false; S.jb.req = null; }
    else if (a === 'jbcancel') { S.jb.req = null; S.jb.friendSheet = false; }
    else if (a === 'fleave') { S.jb.joined = false; S.jb.toast = ''; }
    else if (a === 'gadd') { var id = b.dataset.id; if (S.queue.indexOf(id) < 0 && S.now !== id) { S.queue.push(id); S.jb.toast = t.added; say(t.added); } }
    else if (a === 'connect') { S.tv.sheet = true; S.tv.code = code6(); S.tv.err = ''; sheet = true; opener = 'connect'; }
    else if (a === 'pcancel') { S.tv.sheet = false; }
    else if (a === 'onphone') S.tv.onTv = false;
    render();
    if (sheet) focusSheet(); else if (a === 'fcancel' || a === 'jbcancel' || a === 'pcancel') backToOpener();
    if (S.jb.toast) setTimeout(function () { if (S.jb.toast) { S.jb.toast = ''; var tt = root.querySelector('.toast'); if (tt) tt.remove(); } }, 2200);
  });

  root.addEventListener('submit', function (e) {
    var f = e.target.closest('[data-form]'); if (!f) return;
    e.preventDefault();
    var val = f.querySelector('input').value.replace(/\D/g, '');
    if (f.dataset.form === 'join') {
      if (val === S.jb.req) { S.jb.joined = true; S.jb.req = null; S.jb.friendSheet = false; S.jb.friendErr = ''; say(t.jbWith(t.guest)); render(); }
      else { S.jb.friendErr = t.bad; render(); focusSheet(); }
    } else {
      if (val === S.tv.code) { S.tv.sheet = false; S.tv.paired = true; S.tv.onTv = true; S.tv.err = ''; say(t.connected); render(); }
      else { S.tv.err = t.bad; render(); focusSheet(); }
    }
  });
  root.addEventListener('input', function (e) {
    var inp = e.target.closest && e.target.closest('.codein'); if (!inp) return;
    var v = inp.value.replace(/\D/g, '').slice(0, 6); inp.value = v;
    if (v.length === 6) { var f = inp.closest('form'); if (f.requestSubmit) f.requestSubmit(); else f.dispatchEvent(new Event('submit', { cancelable: true, bubbles: true })); }
  });

  root.addEventListener('keydown', function (e) {
    if (e.key !== 'Escape') return;
    var act = S.jb.friendSheet || S.jb.req ? 'fcancel' : S.tv.sheet ? 'pcancel' : null;
    if (!act) return;
    if (act === 'fcancel') { S.jb.friendSheet = false; S.jb.req = null; } else { S.tv.sheet = false; }
    render(); backToOpener();
  });
  tabsEl.addEventListener('keydown', function (e) {
    if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') return;
    var order = ['player', 'jukebox', 'devices'], i = order.indexOf(S.tab);
    S.tab = order[(i + (e.key === 'ArrowRight' ? 1 : 2)) % 3]; render();
    var el = root.querySelector('#tab-' + S.tab); if (el) el.focus();
  });

  // queue: drag to reorder (pointer) and arrow keys
  function readOrder(list) { S.queue = Array.prototype.map.call(list.querySelectorAll('li[data-id]'), function (li) { return li.dataset.id; }); }
  root.addEventListener('pointerdown', function (e) {
    var li = e.target.closest('.player .q li[data-id]');
    if (!li || e.button > 0) return;
    var list = li.parentNode;
    li.setPointerCapture(e.pointerId); li.classList.add('drag');
    function move(ev) {
      var sibs = Array.prototype.filter.call(list.children, function (c) { return c !== li && c.dataset.id; });
      for (var i = 0; i < sibs.length; i++) {
        var r = sibs[i].getBoundingClientRect();
        if (ev.clientY < r.top + r.height / 2) { if (li.nextSibling !== sibs[i]) list.insertBefore(li, sibs[i]); return; }
      }
      list.appendChild(li);
    }
    function up() { li.classList.remove('drag'); li.removeEventListener('pointermove', move); li.removeEventListener('pointerup', up); li.removeEventListener('pointercancel', up); readOrder(list); }
    li.addEventListener('pointermove', move); li.addEventListener('pointerup', up); li.addEventListener('pointercancel', up);
    e.preventDefault();
  });
  root.addEventListener('keydown', function (e) {
    var li = e.target.closest && e.target.closest('.player .q li[data-id]');
    if (!li || (e.key !== 'ArrowUp' && e.key !== 'ArrowDown')) return;
    e.preventDefault();
    var list = li.parentNode;
    if (e.key === 'ArrowUp' && li.previousElementSibling) list.insertBefore(li, li.previousElementSibling);
    if (e.key === 'ArrowDown' && li.nextElementSibling) list.insertBefore(li.nextElementSibling, li);
    readOrder(list); li.focus();
  });

  render();
})();
