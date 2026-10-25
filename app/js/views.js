/* Ansichten. Jede Ansicht liefert { el, update?(evt) } */
var Views = (function () {
  'use strict';
  var h = U.h, A = U.asArray;

  // Kachelfarben für Genres
  var TILE_COLORS = ['#2f6fdb', '#c2410c', '#0f766e', '#be123c', '#a16207', '#4338ca', '#4d7c0f', '#0e7490', '#9d174d',
    '#b45309', '#15803d', '#1d4ed8', '#b91c1c', '#0369a1', '#7c2d12', '#334155'];
  function tileColor(i) { return TILE_COLORS[i % TILE_COLORS.length]; }
  function hexRgb(hex) { var n = parseInt(hex.slice(1), 16); return [(n >> 16) & 255, (n >> 8) & 255, n & 255]; }

  function view(cls) { return h('div.view' + (cls ? '.' + cls : '')); }

  function async(el, promise, render) {
    var sp = UI.loading();
    el.appendChild(sp);
    return promise.then(function (data) {
      if (sp.parentNode) sp.parentNode.removeChild(sp);
      render(data);
      App.viewReady(el);
    }).catch(function (e) {
      if (sp.parentNode) sp.parentNode.removeChild(sp);
      el.appendChild(h('div.empty', { text: 'Fehler: ' + e.message }));
      el.appendChild(h('div.nav-container', null, UI.button('Erneut versuchen', function () { App.reload(); }, 'outline')));
      App.viewReady(el);
    });
  }

  function titleClass(t) { t = t || ''; return t.length > 34 ? 's' : t.length > 16 ? 'm' : ''; }
  function dot() { return h('span.dot', { text: '•' }); }

  // Kopfbereich für Album / Playlist / Künstler
  function hero(o) {
    var cov = h('div.hero-cover' + (o.round ? '.round' : ''));
    if (o.art) cov.appendChild(o.art);
    else cov.appendChild(UI.cover(o.coverId, 600, o.round ? 'round' : null, o.round ? 'artist' : 'album'));
    var meta = h('div.hero-meta');
    (o.meta || []).filter(Boolean).forEach(function (m, i) { if (i) meta.appendChild(dot()); meta.appendChild(typeof m === 'string' ? h('span', { text: m }) : m); });
    return h('div.hero', null, cov, h('div.hero-info', null,
      h('div.hero-type', { text: o.type }),
      h('h1.hero-title' + (titleClass(o.title) ? '.' + titleClass(o.title) : ''), { text: o.title }),
      o.desc ? h('p.bio', { text: o.desc }) : null,
      h('div.nav-container', null, meta)
    ));
  }

  function heartBtn(type, obj) {
    var b = UI.iconBtn(obj.starred ? 'heartFill' : 'heart', function () {
      var on = !obj.starred;
      API.star(type, obj.id, on).then(function () {
        obj.starred = on ? 'x' : undefined;
        UI.setIcon(b, on ? 'heartFill' : 'heart');
        b.classList.toggle('on', on);
        U.toast(on ? 'Zu deiner Bibliothek hinzugefügt' : 'Aus deiner Bibliothek entfernt');
      }).catch(App.error);
    }, 'Favorit', obj.starred ? 'on' : null);
    return b;
  }

  // ---------------- Start
  function home() {
    var el = view('home');
    var types = [['Zuletzt gespielt', 'recent'], ['Neu hinzugefügt', 'newest'], ['Häufig gespielt', 'frequent'], ['Entdecken', 'random'], ['Deine Lieblingsalben', 'starred']];
    async(el, Promise.all(types.map(function (t) { return API.albumList(t[1], 20).catch(function () { return []; }); })), function (lists) {
      var recent = lists[0];
      UI.heroBg(el, recent[0] ? API.cover(recent[0].coverArt || recent[0].id, 120) : null, [40, 40, 40]);
      el.appendChild(h('h1.page-title', { text: greeting() }));
      var tiles = [
        UI.shortcut({ art: { cls: 'liked', icon: 'heartFill' }, label: 'Favoriten', onClick: function () { App.go('starred'); } }),
        UI.shortcut({ art: { cls: 'mix', icon: 'shuffle' }, label: 'Zufallsmix', onClick: function () {
          API.randomSongs(150).then(function (s) { Player.playList(s, 0); App.go('nowplaying'); }).catch(App.error);
        } })
      ];
      var cur = Player.current();
      if (cur) tiles.push(UI.shortcut({ coverId: cur.coverArt || cur.albumId, label: 'Weiterhören: ' + cur.title, onClick: function () { Player.play(); App.go('nowplaying'); } }));
      recent.slice(0, 8 - tiles.length).forEach(function (a) {
        tiles.push(UI.shortcut({ coverId: a.coverArt || a.id, label: a.name, onClick: function () { App.go('album', { id: a.id }); }, onOptions: function () { Menus.album(a); } }));
      });
      el.appendChild(h('div.shortcuts.nav-container', null, tiles));
      lists.forEach(function (items, i) {
        if (!items.length) return;
        var type = types[i][1];
        el.appendChild(UI.row(types[i][0], items, UI.albumCard, function () { App.go('albums', { sort: type }); }));
      });
    });
    return { el: el };
  }

  function greeting() {
    var hr = new Date().getHours();
    return hr < 5 ? 'Gute Nacht' : hr < 11 ? 'Guten Morgen' : hr < 18 ? 'Guten Tag' : 'Guten Abend';
  }

  // ---------------- Alben
  var ALBUM_SORTS = [
    ['alphabeticalByName', 'A–Z'], ['alphabeticalByArtist', 'Künstler'], ['newest', 'Neu hinzugefügt'],
    ['recent', 'Zuletzt gespielt'], ['frequent', 'Häufig gespielt'], ['random', 'Zufällig'], ['starred', 'Favoriten']
  ];
  function albums(params) {
    var el = view();
    var sort = (params && params.sort) || U.ustore.get('albumSort', 'alphabeticalByName');
    var gridHolder = h('div');
    var chips = ALBUM_SORTS.map(function (s) {
      var c = UI.chip(s[1], function () {
        sort = s[0]; U.ustore.set('albumSort', sort);
        chips.forEach(function (x) { x.classList.remove('active'); });
        c.classList.add('active');
        build();
      }, s[0] === sort);
      return c;
    });
    el.appendChild(UI.header('Alben'));
    el.appendChild(h('div.chips.nav-container', null, chips));
    el.appendChild(gridHolder);
    function build() {
      gridHolder.innerHTML = '';
      var g = UI.grid(UI.albumCard, function (off, size) { return API.albumList(sort, size, off); }, 60);
      gridHolder.appendChild(g.el);
      g.more().then(function () { App.viewReady(el); });
    }
    build();
    return { el: el };
  }

  // ---------------- Künstler
  function artists() {
    var el = view();
    el.appendChild(UI.header('Künstler'));
    async(el, API.artists(), function (list) {
      var g = UI.grid(UI.artistCard, function (off, size) { return Promise.resolve(list.slice(off, off + size)); }, 60);
      el.appendChild(g.el);
      g.more();
    });
    return { el: el };
  }

  function artist(params) {
    var el = view('detail');
    async(el, Promise.all([API.artist(params.id), API.artistInfo(params.id)]), function (res) {
      var ar = res[0], info = res[1];
      var albumsList = A(ar.album).sort(function (a, b) { return (b.year || 0) - (a.year || 0); });
      UI.heroBg(el, API.cover(ar.coverArt || ar.id, 120));
      var bio = info.biography ? info.biography.replace(/<[^>]+>/g, '').replace(/\s+/g, ' ').trim() : '';
      el.appendChild(hero({
        type: 'Künstler', title: ar.name, coverId: ar.coverArt || ar.id, round: true,
        desc: bio, meta: [albumsList.length + (albumsList.length === 1 ? ' Album' : ' Alben')]
      }));
      var top = [];
      el.appendChild(h('div.action-bar.nav-container', null,
        UI.playBig(function () { if (top.length) Player.playList(top, 0); else Menus.artistShuffle(ar.id); }, true),
        UI.iconBtn('shuffle', function () { Menus.artistShuffle(ar.id); }, 'Zufällig'),
        UI.iconBtn('radio', function () { Menus.radio(ar.id, ar); }, 'Künstler-Radio'),
        heartBtn('artist', ar),
        UI.iconBtn('more', function () { Menus.artist(ar); }, 'Mehr')
      ));
      var topHolder = h('div');
      el.appendChild(topHolder);
      API.topSongs(ar.name).then(function (t) {
        top = t;
        if (!t.length) return;
        topHolder.appendChild(h('h2.section-title', { text: 'Top-Songs' }));
        topHolder.appendChild(UI.trackList(t.slice(0, 10), { showCover: true, header: false, hideArtist: true }));
      });
      el.appendChild(h('h2.section-title', { text: 'Diskografie' }));
      el.appendChild(UI.staticGrid(albumsList, UI.albumCard));
      var similar = A(info.similarArtist).filter(function (s) { return s.id; });
      if (similar.length) el.appendChild(UI.row('Ähnliche Künstler', similar, UI.artistCard));
    });
    return { el: el };
  }

  // ---------------- Album
  function album(params) {
    var el = view('detail');
    async(el, API.album(params.id), function (al) {
      var songs = A(al.song);
      UI.heroBg(el, API.cover(al.coverArt || al.id, 120));
      var artistLink = h('button.link.focusable', { text: al.artist || '', onclick: function () { if (al.artistId) App.go('artist', { id: al.artistId }); } });
      el.appendChild(hero({
        type: 'Album', title: al.name, coverId: al.coverArt || al.id,
        meta: [artistLink, al.year ? String(al.year) : null, songs.length + ' Songs, ' + U.fmtDuration(al.duration)]
      }));
      el.appendChild(h('div.action-bar.nav-container', null,
        UI.playBig(function () { Player.playList(songs, 0); }, true),
        UI.iconBtn('shuffle', function () { Player.playList(songs, 0, { shuffle: true }); }, 'Zufällig'),
        heartBtn('album', al),
        UI.iconBtn('addQueue', function () { Player.enqueue(songs); }, 'Zur Warteschlange'),
        UI.iconBtn('more', function () { Menus.album(al); }, 'Mehr')
      ));
      var discs = {};
      songs.forEach(function (s) { discs[s.discNumber || 1] = true; });
      if (Object.keys(discs).length > 1) {
        Object.keys(discs).sort(function (a, b) { return a - b; }).forEach(function (d) {
          el.appendChild(h('h2.section-title', { text: 'CD ' + d }));
          var sub = songs.filter(function (s) { return String(s.discNumber || 1) === d; });
          el.appendChild(UI.trackList(sub, { numbers: 'track', onPlay: function (i) { Player.playList(songs, songs.indexOf(sub[i])); } }));
        });
      } else {
        el.appendChild(UI.trackList(songs, { numbers: 'track' }));
      }
      if (al.genre) el.appendChild(h('p.muted', { style: 'margin-top:30px;font-size:20px', text: [al.genre, al.year].filter(Boolean).join(' • ') }));
    });
    return { el: el };
  }

  // ---------------- Playlists
  function playlists() {
    var el = view();
    el.appendChild(UI.header('Playlists'));
    async(el, API.playlists(), function (pls) { el.appendChild(UI.staticGrid(pls, UI.playlistCard)); });
    return { el: el };
  }

  function playlist(params) {
    var el = view('detail');
    async(el, API.playlist(params.id), function (pl) {
      var songs = A(pl.entry);
      UI.heroBg(el, API.cover(pl.coverArt || pl.id, 120));
      el.appendChild(hero({
        type: pl.public ? 'Öffentliche Playlist' : 'Playlist', title: pl.name, coverId: pl.coverArt || pl.id, desc: pl.comment,
        meta: [pl.owner ? h('span', { style: 'color:#fff;font-weight:700', text: pl.owner }) : null, songs.length + ' Songs, ' + U.fmtDuration(pl.duration)]
      }));
      el.appendChild(h('div.action-bar.nav-container', null,
        UI.playBig(function () { Player.playList(songs, 0); }, true),
        UI.iconBtn('shuffle', function () { Player.playList(songs, 0, { shuffle: true }); }, 'Zufällig'),
        UI.iconBtn('addQueue', function () { Player.enqueue(songs); }, 'Zur Warteschlange')
      ));
      el.appendChild(UI.trackList(songs, { showCover: true, showAlbum: true }));
    });
    return { el: el };
  }

  // ---------------- Genres
  function genreTiles(list) {
    var grid = h('div.genre-grid.nav-container');
    list.forEach(function (g, i) {
      grid.appendChild(h('button.genre.focusable', {
        style: 'background:' + tileColor(i),
        onclick: function () { App.go('genre', { name: g.value, color: tileColor(i) }); }
      }, h('div.genre-name', { text: g.value }), h('div.genre-sub', { text: (g.albumCount || 0) + ' Alben' })));
    });
    return grid;
  }

  function genres() {
    var el = view();
    el.appendChild(UI.header('Genres'));
    async(el, API.genres(), function (list) {
      el.appendChild(list.length ? genreTiles(list) : h('div.empty', { text: 'Keine Genres.' }));
    });
    return { el: el };
  }

  function genre(params) {
    var el = view('detail');
    UI.heroBg(el, null, hexRgb(params.color || '#535353'));
    el.appendChild(h('div.hero', { style: 'padding-top:80px' }, h('div.hero-info', null,
      h('div.hero-type', { text: 'Genre' }),
      h('h1.hero-title' + (titleClass(params.name) ? '.' + titleClass(params.name) : ''), { text: params.name })
    )));
    el.appendChild(h('div.action-bar.nav-container', null,
      UI.playBig(function () {
        API.randomSongs(150, params.name).then(function (s) { Player.playList(s, 0); App.go('nowplaying'); }).catch(App.error);
      }, true)
    ));
    el.appendChild(h('h2.section-title', { text: 'Alben' }));
    var g = UI.grid(UI.albumCard, function (off, size) { return API.albumList('byGenre', size, off, { genre: params.name }); }, 60);
    el.appendChild(g.el);
    g.more().then(function () { App.viewReady(el); });
    return { el: el };
  }

  // ---------------- Favoriten
  function starred() {
    var el = view('detail');
    UI.heroBg(el, null, [80, 56, 160]);
    async(el, API.starred(), function (s) {
      var art = h('div.tile-art.liked', { style: 'width:100%;height:100%' }, Icon.el('heartFill', 120));
      var me = App.account();
      el.appendChild(hero({ type: 'Sammlung', title: 'Favoriten', art: art,
        meta: [me ? h('span', { style: 'color:#fff;font-weight:700', text: me.user }) : null, s.songs.length + ' Songs'] }));
      if (s.songs.length) {
        el.appendChild(h('div.action-bar.nav-container', null,
          UI.playBig(function () { Player.playList(s.songs, 0); }, true),
          UI.iconBtn('shuffle', function () { Player.playList(s.songs, 0, { shuffle: true }); }, 'Zufällig')
        ));
        el.appendChild(UI.trackList(s.songs, { showCover: true, showAlbum: true }));
      } else {
        el.appendChild(h('div.empty', { text: 'Noch keine Favoriten. Gelbe Taste auf einem Song → „Zu Favoriten hinzufügen“.' }));
      }
      if (s.albums.length) el.appendChild(UI.row('Favorisierte Alben', s.albums, UI.albumCard));
      if (s.artists.length) el.appendChild(UI.row('Favorisierte Künstler', s.artists, UI.artistCard));
    });
    return { el: el };
  }

  // ---------------- Suche
  function search() {
    var el = view();
    var input = h('input.search-input.focusable', { type: 'text', placeholder: 'Künstler, Alben oder Songs', 'data-autofocus': true });
    var bar = h('div.search-bar', null, Icon.el('search', 34), input);
    var results = h('div.results');
    var lastQ = U.ustore.get('lastSearch', '');
    input.value = lastQ;
    input.addEventListener('focus', function () { bar.classList.add('focus-in'); });
    input.addEventListener('blur', function () { bar.classList.remove('focus-in'); });
    el.appendChild(h('div.nav-container', null, bar));
    el.appendChild(results);
    var seq = 0;

    function browseAll() {
      results.innerHTML = '';
      results.appendChild(h('h2.section-title', { text: 'Genres entdecken', style: 'margin-top:0' }));
      API.genres().then(function (list) { results.appendChild(genreTiles(list.slice(0, 20))); }).catch(function () { });
    }

    function topCard(r) {
      var a = r.artists[0], al = r.albums[0], s = r.songs[0];
      var o = a ? { coverId: a.coverArt || a.id, round: true, title: a.name, kind: 'Künstler', go: function () { App.go('artist', { id: a.id }); } }
        : al ? { coverId: al.coverArt || al.id, title: al.name, sub: al.artist, kind: 'Album', go: function () { App.go('album', { id: al.id }); } }
          : { coverId: s.coverArt || s.albumId, title: s.title, sub: s.artist, kind: 'Song', go: function () { Player.playList(r.songs, 0); } };
      var sub = h('div.tc-sub', null, o.sub ? o.sub : null, h('b', { text: o.kind }));
      return h('button.top-card.focusable', { onclick: o.go },
        UI.cover(o.coverId, 300, o.round ? 'round' : null, o.round ? 'artist' : 'album'), h('div.tc-title.ellipsis', { text: o.title }), sub, h('span.card-play', null, Icon.el('play', 30)));
    }

    function run() {
      var q = input.value.trim();
      U.ustore.set('lastSearch', q);
      if (q.length < 2) { browseAll(); return; }
      var my = ++seq;
      results.innerHTML = '';
      results.appendChild(UI.loading());
      API.search(q).then(function (r) {
        if (my !== seq) return;
        results.innerHTML = '';
        if (!r.artists.length && !r.albums.length && !r.songs.length) {
          results.appendChild(h('div.empty', { text: 'Keine Ergebnisse für „' + q + '“' }));
          return;
        }
        var left = h('div', null, h('h2.section-title', { text: 'Top-Ergebnis', style: 'margin-top:0' }), h('div.nav-container', null, topCard(r)));
        var right = h('div.top-songs', null, r.songs.length ? h('h2.section-title', { text: 'Songs', style: 'margin-top:0' }) : null,
          r.songs.length ? UI.trackList(r.songs.slice(0, 4), { showCover: true, header: false }) : null);
        results.appendChild(h('div.top-result', null, left, right));
        if (r.artists.length) results.appendChild(UI.row('Künstler', r.artists, UI.artistCard));
        if (r.albums.length) results.appendChild(UI.row('Alben', r.albums, UI.albumCard));
        if (r.songs.length > 4) {
          results.appendChild(h('h2.section-title', { text: 'Alle Songs' }));
          results.appendChild(UI.trackList(r.songs, { showCover: true, showAlbum: true }));
        }
      }).catch(App.error);
    }
    input.addEventListener('input', U.debounce(run, 700));
    input.addEventListener('keydown', function (e) { if (e.keyCode === 13) { e.preventDefault(); input.blur(); run(); setTimeout(function () { Nav.move('down'); }, 50); } });
    run();
    return { el: el, noAutoInput: true };
  }

  // ---------------- Läuft gerade (Vollbild)
  function nowplaying() {
    var el = view('np');
    var bg = h('div.np-bg');
    var coverEl = h('img.np-cover', { alt: '' });
    var title = h('div.np-title.ellipsis');
    var artist = h('button.np-artist.link.focusable', { onclick: function () { var s = Player.current(); if (s && s.artistId) App.go('artist', { id: s.artistId }); } });
    var bar = h('div.np-bar-fill');
    var progress = h('button.np-progress.focusable', null, h('div.np-bar', null, bar));
    var tCur = h('span'), tDur = h('span');
    var btnShuffle = UI.iconBtn('shuffle', function () { Player.setShuffle(!Player.shuffle()); }, 'Zufall');
    var btnPrev = UI.iconBtn('prev', Player.prev, 'Zurück');
    var btnPlay = h('button.np-play.focusable', { onclick: Player.toggle, title: 'Play/Pause', 'data-autofocus': true });
    var btnNext = UI.iconBtn('next', Player.next, 'Weiter');
    var btnRepeat = UI.iconBtn('repeat', Player.cycleRepeat, 'Wiederholen');
    var btnHeart = UI.iconBtn('heart', function () {
      var s = Player.current(); if (!s) return;
      var on = !s.starred;
      API.star('song', s.id, on).then(function () { Player.setStarred(s, on); U.toast(on ? 'Zu Favoriten hinzugefügt' : 'Aus Favoriten entfernt'); }).catch(App.error);
    }, 'Favorit');
    var btnLyrics = UI.iconBtn('mic', function () { lyricsOn = !lyricsOn; U.ustore.set('lyricsOn', lyricsOn); ensureLyrics(); renderPanel(); }, 'Songtext');
    var btnQueue = UI.iconBtn('queue', function () { App.go('queue'); }, 'Warteschlange');
    var btnMore = UI.iconBtn('more', function () { var s = Player.current(); if (s) Menus.song(s); }, 'Mehr');
    var panelTitle = h('div.np-panel-title');
    var panel = h('div.np-lyrics');
    var lyricsOn = U.ustore.get('lyricsOn', true);
    var lyrics, lyricsFor = null, activeLine = -1, panelMode = '';

    progress.addEventListener('click', function (e) {
      if (e.clientX && Nav.pointerActive()) {
        var r = progress.getBoundingClientRect();
        Player.seek((e.clientX - r.left) / r.width * Player.duration());
      } else Player.toggle();
    });

    el.appendChild(bg);
    el.appendChild(h('div.np-main', null,
      h('div.np-top', null,
        h('div.np-left', null, coverEl,
          h('div.np-titlerow', null, h('div.np-titles', null, title, h('div.nav-container', null, artist)))),
        h('div.np-right', null, panelTitle, panel)
      ),
      h('div.np-bottom', null,
        h('div.nav-container', null, progress),
        h('div.np-time', null, tCur, tDur),
        h('div.np-controls.nav-container', null, btnShuffle, btnPrev, btnPlay, btnNext, btnRepeat,
          h('div.np-extra', null, btnHeart, btnLyrics, btnQueue, btnMore))
      )
    ));

    Nav.onKey(function (e, code) {
      if (Nav.current() !== progress || !el.isConnected) return false;
      if (code === Nav.KEY.LEFT) { Player.seekBy(-10); return true; }
      if (code === Nav.KEY.RIGHT) { Player.seekBy(10); return true; }
      return false;
    });

    function ensureLyrics() {
      var s = Player.current();
      if (!s || !lyricsOn || lyricsFor === s.id) return;
      lyricsFor = s.id; lyrics = undefined;
      API.lyrics(s).then(function (l) {
        if (lyricsFor !== s.id) return;
        lyrics = l; renderPanel();
      });
    }

    function renderPanel() {
      btnLyrics.classList.toggle('on', lyricsOn);
      var hadFocus = Nav.current() && panel.contains(Nav.current());
      var showLyrics = lyricsOn && lyrics && lyrics.lines.length;
      panel.innerHTML = '';
      activeLine = -1;
      if (showLyrics) {
        panelMode = 'lyrics';
        panel.classList.add('mode-lyrics');
        panelTitle.textContent = 'Songtext';
        var inner = h('div.lyrics-inner' + (lyrics.synced ? '.synced' : ''));
        lyrics.lines.forEach(function (l) { inner.appendChild(h('div.lyric', { text: l.text || '♪' })); });
        panel.appendChild(inner);
        syncLyrics();
      } else {
        panelMode = 'queue';
        panel.classList.remove('mode-lyrics');
        var q = Player.queue(), i = Player.index();
        var upcoming = q.slice(i + 1, i + 7);
        panelTitle.textContent = upcoming.length ? 'Als Nächstes' : '';
        if (upcoming.length) {
          var list = UI.trackList(upcoming, { showCover: true, header: false, onPlay: function (k) { Player.jump(i + 1 + k); } });
          list.classList.add('np-upnext');
          panel.appendChild(list);
        }
      }
      if (hadFocus) Nav.focus(btnPlay);
    }

    function renderTrack() {
      var s = Player.current();
      if (!s) {
        title.textContent = 'Nichts in der Wiedergabe'; artist.textContent = '';
        coverEl.removeAttribute('src'); bg.style.background = '#121212';
        panel.innerHTML = ''; panelTitle.textContent = '';
        return;
      }
      coverEl.src = API.cover(s.coverArt || s.albumId, 800);
      title.textContent = s.title;
      artist.textContent = s.artist || '';
      UI.setIcon(btnHeart, s.starred ? 'heartFill' : 'heart');
      btnHeart.classList.toggle('on', !!s.starred);
      UI.coverColor(API.cover(s.coverArt || s.albumId, 120)).then(function (c) {
        c = c || [83, 83, 83];
        var d = [Math.round(c[0] * 0.45), Math.round(c[1] * 0.45), Math.round(c[2] * 0.45)];
        bg.style.background = 'linear-gradient(180deg,' + UI.rgb(c) + ' 0,' + UI.rgb(d) + ' 100%)';
      });
      ensureLyrics();
      renderPanel();
    }

    function syncLyrics() {
      if (panelMode !== 'lyrics' || !lyrics || !lyrics.synced) return;
      var p = Player.position() + 0.3, idx = -1;
      for (var i = 0; i < lyrics.lines.length; i++) { if (lyrics.lines[i].t <= p) idx = i; else break; }
      if (idx === activeLine) return;
      var lines = U.$$('.lyric', panel);
      lines.forEach(function (ln, k) { ln.classList.toggle('past', k < idx); ln.classList.toggle('active', k === idx); });
      activeLine = idx;
      if (lines[idx]) panel.scrollTop = lines[idx].offsetTop - panel.clientHeight / 3;
    }

    function renderState() {
      UI.setIcon(btnPlay, Player.paused() ? 'play' : 'pause');
      btnShuffle.classList.toggle('on', Player.shuffle());
      var r = Player.repeat();
      btnRepeat.classList.toggle('on', r !== 'off');
      btnRepeat.innerHTML = r === 'one' ? Icon.repeatOne() : Icon.svg('repeat');
    }

    function renderTime() {
      var p = Player.position(), d = Player.duration();
      bar.style.width = (d ? Math.min(100, p / d * 100) : 0) + '%';
      tCur.textContent = U.fmtTime(p);
      tDur.textContent = U.fmtTime(d);
      syncLyrics();
    }

    renderTrack(); renderState(); renderTime();
    setTimeout(function () { App.viewReady(el); }, 0);
    return {
      el: el,
      update: function (evt) {
        if (evt === 'track') renderTrack();
        if (evt === 'queue' && panelMode === 'queue') renderPanel();
        if (evt === 'state' || evt === 'mode' || evt === 'track') renderState();
        if (evt === 'time' || evt === 'track') renderTime();
      }
    };
  }

  // ---------------- Warteschlange
  function queue() {
    var el = view();
    var holder = h('div');
    function render() {
      var q = Player.queue(), idx = Player.index();
      holder.innerHTML = '';
      holder.appendChild(UI.header('Warteschlange'));
      if (!q.length) { holder.appendChild(h('div.empty', { text: 'Deine Warteschlange ist leer.' })); return; }
      holder.appendChild(h('div.chips.nav-container', null,
        UI.chip('Zufällig', function () { Player.setShuffle(!Player.shuffle()); }, Player.shuffle()),
        UI.chip('Als Playlist speichern', function () { Menus.addToPlaylist(q); }),
        UI.chip('Leeren', function () { UI.confirm('Warteschlange leeren?', 'Leeren', function () { Player.stop(); }, 'trash'); })
      ));
      var extra = function (i) { return [{ icon: 'close', label: 'Aus Warteschlange entfernen', action: function () { Player.removeAt(i); } }]; };
      if (idx >= 0) {
        holder.appendChild(h('h2.section-title', { text: 'Läuft gerade', style: 'margin-top:10px' }));
        holder.appendChild(UI.trackList([q[idx]], { showCover: true, showAlbum: true, header: false, onPlay: function () { Player.toggle(); }, menuExtra: function () { return extra(idx); } }));
      }
      var rest = q.slice(idx + 1);
      if (rest.length) {
        holder.appendChild(h('h2.section-title', { text: 'Als Nächstes · ' + rest.length + ' Songs, ' + U.fmtDuration(rest.reduce(function (a, s) { return a + (s.duration || 0); }, 0)) }));
        holder.appendChild(UI.trackList(rest, { showCover: true, showAlbum: true, header: false,
          onPlay: function (i) { Player.jump(idx + 1 + i); }, menuExtra: function (i) { return extra(idx + 1 + i); } }));
      }
      UI.refreshPlaying();
    }
    el.appendChild(holder);
    render();
    setTimeout(function () { App.viewReady(el); }, 0);
    return {
      el: el,
      update: function (evt) {
        if (evt === 'queue' || evt === 'mode') {
          var f = Nav.current(), all0 = U.$$('.focusable', el), i0 = f ? all0.indexOf(f) : -1;
          render();
          var all = U.$$('.focusable', el);
          if (i0 >= 0 && all.length) Nav.focus(all[Math.min(i0, all.length - 1)]);
        }
      }
    };
  }

  // ---------------- Einstellungen
  function settings() {
    var el = view('settings');
    var cfg = API.getConfig();
    el.appendChild(UI.header('Einstellungen'));

    function option(label, desc, values, key, onChange) {
      var chips = h('div.chips.nav-container');
      values.forEach(function (v) {
        var c = UI.chip(v[1], function () {
          App.setSetting(key, v[0]);
          U.$$('.chip', chips).forEach(function (x) { x.classList.remove('active'); });
          c.classList.add('active');
          if (onChange) onChange(v[0]);
        }, App.settings()[key] === v[0]);
        chips.appendChild(c);
      });
      return h('div.setting', null, h('div', null, h('div.setting-label', { text: label }), desc ? h('div.setting-desc', { text: desc }) : null), chips);
    }

    el.appendChild(h('div.settings-section', { text: 'Wiedergabe' }));
    el.appendChild(option('Streaming-Qualität', 'Original spielt die Datei unverändert ab', [[0, 'Original'], [320, '320 kbps'], [192, '192 kbps'], [128, '128 kbps']], 'maxBitRate', function () { Player.reloadCurrent(); }));
    el.appendChild(option('Format bei Umwandlung', 'Nur relevant, wenn nicht „Original“', [['mp3', 'MP3'], ['opus', 'Opus'], ['aac', 'AAC']], 'format', function () { Player.reloadCurrent(); }));
    el.appendChild(option('Scrobbeln', 'Gehörte Songs an den Server melden', [[true, 'An'], [false, 'Aus']], 'scrobble'));

    el.appendChild(h('div.settings-section', { text: 'Anzeige' }));
    el.appendChild(option('Bildschirmschoner', 'Schützt das OLED-Panel vor Einbrennen', [[0, 'Aus'], [1, '1 Min.'], [3, '3 Min.'], [5, '5 Min.'], [10, '10 Min.']], 'screensaver'));
    el.appendChild(option('Startansicht', null, [['home', 'Start'], ['nowplaying', 'Läuft gerade'], ['albums', 'Alben']], 'startView'));

    el.appendChild(h('div.settings-section', { text: 'Konto' }));
    var infoText = h('div.setting-desc', { text: cfg.url });
    API.ping().then(function (r) { infoText.textContent = cfg.url + ' • ' + (r.type || 'Subsonic') + ' ' + (r.serverVersion || ''); }).catch(function () { });
    el.appendChild(h('div.setting', null, h('div', null, h('div.setting-label', { text: 'Angemeldet als ' + cfg.user }), infoText)));
    el.appendChild(h('div.settings-actions.nav-container', null,
      UI.button('Benutzer wechseln', App.showUsers, 'primary', 'swap'),
      UI.button('Konto entfernen', function () { UI.confirm('Konto „' + cfg.user + '“ von diesem TV entfernen?', 'Entfernen', App.logout, 'trash'); }, 'danger', 'logout'),
      UI.button('App beenden', App.exit, 'outline', 'power')
    ));

    el.appendChild(h('div.settings-section', { text: 'Fernbedienung' }));
    el.appendChild(h('div.keys', { html:
      '<b>▶ / ❚❚ / ■</b> Play, Pause, Stopp · <b>⏪ ⏩</b> 10 s spulen, gedrückt halten = Song wechseln · <b>CH + / –</b> seitenweise scrollen<br>' +
      '<b style="color:#e53935">Rot</b> Läuft gerade · <b style="color:#43a047">Grün</b> Suchen · <b style="color:#fdd835">Gelb</b> Optionen · <b style="color:#1e88e5">Blau</b> Play/Pause' }));
    el.appendChild(h('div.version', { text: 'Tonalo · inoffizieller Navidrome-Client für LG webOS · v1.4.0' }));
    setTimeout(function () { App.viewReady(el); }, 0);
    return { el: el };
  }

  return {
    home: home, albums: albums, artists: artists, artist: artist, album: album,
    playlists: playlists, playlist: playlist, genres: genres, genre: genre,
    starred: starred, search: search, nowplaying: nowplaying, queue: queue, settings: settings
  };
})();
