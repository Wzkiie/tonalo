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
      el.appendChild(h('div.empty', { text: T('Fehler: {msg}', { msg: e.message }) }));
      el.appendChild(h('div.nav-container', null, UI.button(T('Erneut versuchen'), function () { App.reload(); }, 'outline')));
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
        U.toast(on ? T('Zu deiner Bibliothek hinzugefügt') : T('Aus deiner Bibliothek entfernt'));
      }).catch(App.error);
    }, T('Favorit'), obj.starred ? 'on' : null);
    return b;
  }

  // ---------------- Start
  function home() {
    var el = view('home');
    var types = [[T('Zuletzt gespielt'), 'recent'], [T('Neu hinzugefügt'), 'newest'], [T('Häufig gespielt'), 'frequent'], [T('Entdecken'), 'random'], [T('Deine Lieblingsalben'), 'starred']];
    async(el, Promise.all(types.map(function (t) { return API.albumList(t[1], 20).catch(function () { return []; }); })), function (lists) {
      var recent = lists[0];
      UI.heroBg(el, recent[0] ? API.cover(recent[0].coverArt || recent[0].id, 120) : null, [40, 40, 40]);
      el.appendChild(h('h1.page-title', { text: greeting() }));
      var tiles = [
        UI.shortcut({ art: { cls: 'liked', icon: 'heartFill' }, label: T('Favoriten'), onClick: function () { App.go('starred'); } }),
        UI.shortcut({ art: { cls: 'mix', icon: 'shuffle' }, label: T('Zufallsmix'), onClick: function () {
          API.randomSongs(150).then(function (s) { Player.playList(s, 0); App.go('nowplaying'); }).catch(App.error);
        } })
      ];
      var cur = Player.current();
      if (cur) tiles.push(UI.shortcut({ coverId: cur.coverArt || cur.albumId, label: T('Weiterhören: {title}', { title: cur.title }), onClick: function () { Player.play(); App.go('nowplaying'); } }));
      recent.slice(0, 8 - tiles.length).forEach(function (a) {
        tiles.push(UI.shortcut({ coverId: a.coverArt || a.id, label: a.name, onClick: function () { App.go('album', { id: a.id }); }, onOptions: function () { Menus.album(a); } }));
      });
      el.appendChild(h('div.shortcuts.nav-container', null, tiles));
      var radioHolder = h('div');
      el.appendChild(radioHolder);
      Promise.all([API.genres().catch(function () { return []; }), API.stations().catch(function () { return []; })]).then(function (r) {
        var cards = UI.smartRadioCards(UI.radioGenres(r[0]).slice(0, 4)).concat(r[1].map(function (st) { return UI.stationCard(st, r[1]); }));
        radioHolder.appendChild(UI.row(T('Radio'), cards, function (c) { return c; }, function () { App.go('radio'); }));
      });
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
    return hr < 5 ? T('Gute Nacht') : hr < 12 ? T('Guten Morgen') : hr < 18 ? T('Guten Tag') : T('Guten Abend');
  }

  // ---------------- Alben
  var ALBUM_SORTS = [
    ['alphabeticalByName', T('A–Z')], ['alphabeticalByArtist', T('Künstler|Einzahl')], ['newest', T('Neu hinzugefügt')],
    ['recent', T('Zuletzt gespielt')], ['frequent', T('Häufig gespielt')], ['random', T('Zufällig')], ['starred', T('Favoriten')]
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
    el.appendChild(UI.header(T('Alben')));
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
    el.appendChild(UI.header(T('Künstler')));
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
        type: T('Künstler|Einzahl'), title: ar.name, coverId: ar.coverArt || ar.id, round: true,
        desc: bio, meta: [T.n(albumsList.length, '{n} Album', '{n} Alben')]
      }));
      var top = [];
      el.appendChild(h('div.action-bar.nav-container', null,
        UI.playBig(function () { if (top.length) Player.playList(top, 0); else Menus.artistShuffle(ar.id); }, true),
        UI.iconBtn('shuffle', function () { Menus.artistShuffle(ar.id); }, T('Zufällig')),
        UI.iconBtn('radio', function () { Menus.radio(ar.id, ar); }, T('Künstler-Radio')),
        heartBtn('artist', ar),
        UI.iconBtn('more', function () { Menus.artist(ar); }, T('Mehr'))
      ));
      var topHolder = h('div');
      el.appendChild(topHolder);
      API.topSongs(ar.name).then(function (t) {
        if (t.length) return { songs: t, title: T('Top-Songs') };
        // Ohne Last.fm kennt der Server keine Top-Songs: dann die meistgehörten Songs aus der eigenen Bibliothek
        return Promise.all(albumsList.slice(0, 30).map(function (al) { return API.album(al.id).catch(function () { return {}; }); })).then(function (als) {
          var all = [];
          als.forEach(function (al) { all = all.concat(A(al.song)); });
          var played = all.filter(function (s) { return s.playCount > 0 && (!s.artistId || s.artistId === ar.id || s.artist === ar.name); })
            .sort(function (a, b) { return b.playCount - a.playCount; });
          return { songs: played, title: T('Deine meistgehörten Songs') };
        });
      }).then(function (r) {
        top = r.songs;
        if (!top.length) return;
        topHolder.appendChild(h('h2.section-title', { text: r.title }));
        topHolder.appendChild(UI.trackList(top.slice(0, 10), { showCover: true, header: false, hideArtist: true }));
      });
      el.appendChild(h('h2.section-title', { text: T('Diskografie') }));
      el.appendChild(UI.staticGrid(albumsList, UI.albumCard));
      var similar = A(info.similarArtist).filter(function (s) { return s.id; });
      if (similar.length) el.appendChild(UI.row(T('Ähnliche Künstler'), similar, UI.artistCard));
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
        type: T('Album'), title: al.name, coverId: al.coverArt || al.id,
        meta: [artistLink, al.year ? String(al.year) : null, T.n(songs.length, '{n} Song, {dur}', '{n} Songs, {dur}', { dur: U.fmtDuration(al.duration) })]
      }));
      el.appendChild(h('div.action-bar.nav-container', null,
        UI.playBig(function () { Player.playList(songs, 0); }, true),
        UI.iconBtn('shuffle', function () { Player.playList(songs, 0, { shuffle: true }); }, T('Zufällig')),
        heartBtn('album', al),
        UI.iconBtn('addQueue', function () { Player.enqueue(songs); }, T('Zur Warteschlange')),
        UI.iconBtn('more', function () { Menus.album(al); }, T('Mehr'))
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
    el.appendChild(UI.header(T('Playlists')));
    async(el, API.playlists(), function (pls) { el.appendChild(UI.staticGrid(pls, UI.playlistCard)); });
    return { el: el };
  }

  function playlist(params) {
    var el = view('detail');
    async(el, API.playlist(params.id), function (pl) {
      var songs = A(pl.entry);
      var own = Menus.ownPlaylist(pl);
      function more() {
        UI.modal(null, [
          { icon: 'edit', label: T('Umbenennen'), action: function () {
            UI.prompt(T('Playlist umbenennen'), pl.name, T('Speichern'), function (name) {
              API.renamePlaylist(pl.id, name).then(function () { U.toast(T('Umbenannt in „{name}“', { name: name })); App.reload(); }).catch(App.error);
            });
          } },
          { icon: 'trash', label: T('Playlist löschen'), danger: true, action: function () {
            UI.confirm(T('„{name}“ löschen?', { name: pl.name }), T('Löschen'), function () {
              API.deletePlaylist(pl.id).then(function () { U.toast(T('„{name}“ gelöscht', { name: pl.name })); App.back(); App.reload(); }).catch(App.error);
            }, 'trash');
          } }
        ], { head: { coverId: pl.coverArt || pl.id, title: pl.name, sub: T('Playlist') } });
      }
      UI.heroBg(el, API.cover(pl.coverArt || pl.id, 120));
      el.appendChild(hero({
        type: pl.public ? T('Öffentliche Playlist') : T('Playlist'), title: pl.name, coverId: pl.coverArt || pl.id, desc: pl.comment,
        meta: [pl.owner ? h('span', { style: 'color:#fff;font-weight:700', text: pl.owner }) : null, T.n(songs.length, '{n} Song, {dur}', '{n} Songs, {dur}', { dur: U.fmtDuration(pl.duration) })]
      }));
      el.appendChild(h('div.action-bar.nav-container', null,
        UI.playBig(function () { Player.playList(songs, 0); }, true),
        UI.iconBtn('shuffle', function () { Player.playList(songs, 0, { shuffle: true }); }, T('Zufällig')),
        UI.iconBtn('addQueue', function () { Player.enqueue(songs); }, T('Zur Warteschlange')),
        own ? UI.iconBtn('more', more, T('Mehr')) : null
      ));
      el.appendChild(UI.trackList(songs, { showCover: true, showAlbum: true, menuExtra: own ? function (i) {
        return [{ icon: 'close', label: T('Aus Playlist entfernen'), action: function () {
          API.removeFromPlaylist(pl.id, i).then(function () { U.toast(T('Aus „{name}“ entfernt', { name: pl.name })); App.reload(); }).catch(App.error);
        } }];
      } : null }));
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
      }, h('div.genre-name', { text: g.value }), h('div.genre-sub', { text: T.n(g.albumCount || 0, '{n} Album', '{n} Alben') })));
    });
    return grid;
  }

  function genres() {
    var el = view();
    el.appendChild(UI.header(T('Genres')));
    async(el, API.genres(), function (list) {
      el.appendChild(list.length ? genreTiles(list) : h('div.empty', { text: T('Keine Genres.') }));
    });
    return { el: el };
  }

  function genre(params) {
    var el = view('detail');
    UI.heroBg(el, null, hexRgb(params.color || '#535353'));
    el.appendChild(h('div.hero', { style: 'padding-top:80px' }, h('div.hero-info', null,
      h('div.hero-type', { text: T('Genre') }),
      h('h1.hero-title' + (titleClass(params.name) ? '.' + titleClass(params.name) : ''), { text: params.name })
    )));
    el.appendChild(h('div.action-bar.nav-container', null,
      UI.playBig(function () {
        API.randomSongs(150, params.name).then(function (s) { Player.playList(s, 0); App.go('nowplaying'); }).catch(App.error);
      }, true)
    ));
    el.appendChild(h('h2.section-title', { text: T('Alben') }));
    var g = UI.grid(UI.albumCard, function (off, size) { return API.albumList('byGenre', size, off, { genre: params.name }); }, 60);
    el.appendChild(g.el);
    g.more().then(function () { App.viewReady(el); });
    return { el: el };
  }

  // ---------------- Radio: Endlos-Radios und die Sender vom Server
  function radio() {
    var el = view();
    el.appendChild(UI.header(T('Radio')));
    async(el, Promise.all([API.genres().catch(function () { return []; }), API.stations().catch(function () { return []; })]), function (r) {
      el.appendChild(h('h2.section-title', { text: T('Endlos-Radio'), style: 'margin-top:10px' }));
      el.appendChild(h('div.grid.nav-container', null, UI.smartRadioCards(UI.radioGenres(r[0]).slice(0, 16))));
      el.appendChild(h('h2.section-title', { text: T('Sender') }));
      if (r[1].length) el.appendChild(h('div.grid.nav-container', null, r[1].map(function (st) { return UI.stationCard(st, r[1]); })));
      else el.appendChild(h('div.empty', { text: T('Noch keine Radiosender. Sie werden auf dem Server eingerichtet, in Navidrome unter „Radio“.') }));
    });
    return {
      el: el,
      update: function (evt) {
        if (evt !== 'track') return;
        var st = Player.station();
        U.$$('.radio-card', el).forEach(function (c) { c.classList.remove('playing'); });
        if (st) U.$$('.radio-card', el).forEach(function (c) { if (U.$('.card-title', c).textContent === st.name) c.classList.add('playing'); });
      }
    };
  }

  // ---------------- Favoriten
  function starred() {
    var el = view('detail');
    UI.heroBg(el, null, [80, 56, 160]);
    async(el, API.starred(), function (s) {
      var art = h('div.tile-art.liked', { style: 'width:100%;height:100%' }, Icon.el('heartFill', 120));
      var me = App.account();
      el.appendChild(hero({ type: T('Sammlung'), title: T('Favoriten'), art: art,
        meta: [me ? h('span', { style: 'color:#fff;font-weight:700', text: me.user }) : null, T.n(s.songs.length, '{n} Song', '{n} Songs')] }));
      if (s.songs.length) {
        el.appendChild(h('div.action-bar.nav-container', null,
          UI.playBig(function () { Player.playList(s.songs, 0); }, true),
          UI.iconBtn('shuffle', function () { Player.playList(s.songs, 0, { shuffle: true }); }, T('Zufällig'))
        ));
        el.appendChild(UI.trackList(s.songs, { showCover: true, showAlbum: true }));
      } else {
        el.appendChild(h('div.empty', { text: T('Noch keine Favoriten. Gelbe Taste auf einem Song → „Zu Favoriten hinzufügen“.') }));
      }
      if (s.albums.length) el.appendChild(UI.row(T('Favorisierte Alben'), s.albums, UI.albumCard));
      if (s.artists.length) el.appendChild(UI.row(T('Favorisierte Künstler'), s.artists, UI.artistCard));
    });
    return { el: el };
  }

  // ---------------- Suche
  function search() {
    var el = view();
    var input = h('input.search-input.focusable', { type: 'text', placeholder: T('Künstler, Alben oder Songs'), 'data-autofocus': true });
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
      results.appendChild(h('h2.section-title', { text: T('Genres entdecken'), style: 'margin-top:0' }));
      API.genres().then(function (list) { results.appendChild(genreTiles(list.slice(0, 20))); }).catch(function () { });
    }

    function topCard(r) {
      var a = r.artists[0], al = r.albums[0], s = r.songs[0];
      var o = a ? { coverId: a.coverArt || a.id, round: true, title: a.name, kind: T('Künstler|Einzahl'), go: function () { App.go('artist', { id: a.id }); } }
        : al ? { coverId: al.coverArt || al.id, title: al.name, sub: al.artist, kind: T('Album'), go: function () { App.go('album', { id: al.id }); } }
          : { coverId: s.coverArt || s.albumId, title: s.title, sub: s.artist, kind: T('Song'), go: function () { Player.playList(r.songs, 0); } };
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
          results.appendChild(h('div.empty', { text: T('Keine Ergebnisse für „{q}“', { q: q }) }));
          return;
        }
        var left = h('div', null, h('h2.section-title', { text: T('Top-Ergebnis'), style: 'margin-top:0' }), h('div.nav-container', null, topCard(r)));
        var right = h('div.top-songs', null, r.songs.length ? h('h2.section-title', { text: T('Songs'), style: 'margin-top:0' }) : null,
          r.songs.length ? UI.trackList(r.songs.slice(0, 4), { showCover: true, header: false }) : null);
        results.appendChild(h('div.top-result', null, left, right));
        if (r.artists.length) results.appendChild(UI.row(T('Künstler'), r.artists, UI.artistCard));
        if (r.albums.length) results.appendChild(UI.row(T('Alben'), r.albums, UI.albumCard));
        if (r.songs.length > 4) {
          results.appendChild(h('h2.section-title', { text: T('Alle Songs') }));
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
    var artist = h('button.np-artist.link.focusable', { onclick: function () { var s = Player.current(); if (s && s.artistId && !Player.station()) App.go('artist', { id: s.artistId }); } });
    var bar = h('div.np-bar-fill');
    var progress = h('button.np-progress.focusable', null, h('div.np-bar', null, bar));
    var tCur = h('span'), tDur = h('span');
    var btnShuffle = UI.iconBtn('shuffle', function () { Player.setShuffle(!Player.shuffle()); }, T('Zufällig'));
    var btnPrev = UI.iconBtn('prev', Player.prev, T('Zurück'));
    var btnPlay = h('button.np-play.focusable', { onclick: Player.toggle, title: T('Play/Pause'), 'data-autofocus': true });
    var btnNext = UI.iconBtn('next', Player.next, T('Weiter'));
    var btnRepeat = UI.iconBtn('repeat', Player.cycleRepeat, T('Wiederholen'));
    var btnHeart = UI.iconBtn('heart', function () {
      var s = Player.current(); if (!s) return;
      var on = !s.starred;
      API.star('song', s.id, on).then(function () { Player.setStarred(s, on); U.toast(on ? T('Zu Favoriten hinzugefügt') : T('Aus Favoriten entfernt')); }).catch(App.error);
    }, T('Favorit'));
    var btnLyrics = UI.iconBtn('mic', function () { lyricsOn = !lyricsOn; U.ustore.set('lyricsOn', lyricsOn); ensureLyrics(); renderPanel(); }, T('Songtext'));
    var btnQueue = UI.iconBtn('queue', function () { App.go('queue'); }, T('Warteschlange'));
    var btnMore = UI.iconBtn('more', function () {
      var st = Player.station();
      if (st) {
        UI.modal(null, [{ icon: 'queue', label: T('Zurück zur Warteschlange'), action: function () { Player.stopStation(); if (!Player.current()) App.back(); } }],
          { head: { coverId: null, title: st.name, sub: T('Live-Radio') } });
        return;
      }
      var s = Player.current(); if (s) Menus.song(s);
    }, T('Mehr'));
    var btnSleep = UI.iconBtn('moon', sleepMenu, T('Sleep-Timer'));
    var sleepLabel = h('span.np-sleep-left');
    btnSleep.appendChild(sleepLabel);
    var context = h('div.np-context');
    var live = h('span.live-badge', { text: 'LIVE' });
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
        h('div.np-left', null, context, coverEl,
          h('div.np-titlerow', null, h('div.np-titles', null, title, h('div.nav-container', null, artist)))),
        h('div.np-right', null, panelTitle, panel)
      ),
      h('div.np-bottom', null,
        h('div.nav-container.np-progressrow', null, progress),
        h('div.np-time', null, tCur, live, tDur),
        h('div.np-controls.nav-container', null, btnShuffle, btnPrev, btnPlay, btnNext, btnRepeat,
          h('div.np-extra', null, btnSleep, btnHeart, btnLyrics, btnQueue, btnMore))
      )
    ));

    Nav.onKey(function (e, code) {
      if (Nav.current() !== progress || !el.isConnected) return false;
      if (code === Nav.KEY.LEFT) { Player.seekBy(-10); return true; }
      if (code === Nav.KEY.RIGHT) { Player.seekBy(10); return true; }
      return false;
    });

    function sleepMenu() {
      var left = Player.sleepLeft();
      var items = [15, 30, 45, 60, 90].map(function (m) {
        return { icon: 'moon', label: T('{n} Min.', { n: m }), action: function () { Player.setSleep(m); U.toast(T('Sleep-Timer: {n} Min.', { n: m })); } };
      });
      if (!Player.station()) items.push({ icon: 'clock', label: T('Ende des Songs'), action: function () { Player.setSleep(-1); U.toast(T('Sleep-Timer: Ende des Songs')); } });
      if (left) items.unshift({ icon: 'close', label: T('Sleep-Timer ausschalten'), action: function () { Player.setSleep(0); U.toast(T('Sleep-Timer aus')); } });
      UI.modal(left > 0 ? T('Sleep-Timer · noch {time}', { time: U.fmtTime(left / 1000) }) : left < 0 ? T('Sleep-Timer · Ende des Songs') : T('Sleep-Timer'), items);
    }

    function renderSleep() {
      var left = Player.sleepLeft();
      btnSleep.classList.toggle('on', !!left);
      sleepLabel.textContent = left > 0 ? Math.ceil(left / 60000) + '′' : '';
    }

    function renderContext() {
      var c = Player.context(), st = Player.station();
      context.textContent = st ? T('Live-Radio') : c && c.kind === 'radio' ? T('Radio · {name}', { name: c.name }) : '';
    }

    // Sender: daneben die anderen Sender zum Umschalten
    function renderStations() {
      var st = Player.station(), list = Player.stations();
      panel.classList.remove('mode-lyrics');
      panelMode = 'stations';
      panelTitle.textContent = list.length > 1 ? T('Sender') : '';
      if (list.length < 2) return;
      var box = h('div.tracklist.np-upnext.nav-container');
      list.forEach(function (x) {
        box.appendChild(h('div.track-row', null, h('button.track.focusable' + (x.id === st.id ? '.on-air' : ''), { onclick: function () { Player.playStation(x); } },
          h('span.t-main', null, h('div.cover.tiny', null, h('img.loaded', { alt: '', src: UI.radioArt(x.name) })),
            h('span.t-text', null, h('span.t-title.ellipsis', { text: x.name }), h('span.t-artist.ellipsis', { text: T('Live-Radio') }))))));
      });
      panel.appendChild(box);
    }

    function ensureLyrics() {
      var s = Player.current();
      if (Player.station() || !s || !lyricsOn || lyricsFor === s.id) return;
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
      if (Player.station()) {
        renderStations();
      } else if (showLyrics) {
        panelMode = 'lyrics';
        panel.classList.add('mode-lyrics');
        panelTitle.textContent = T('Songtext');
        var inner = h('div.lyrics-inner' + (lyrics.synced ? '.synced' : ''));
        lyrics.lines.forEach(function (l) { inner.appendChild(h('div.lyric', { text: l.text || '♪' })); });
        panel.appendChild(inner);
        syncLyrics();
      } else {
        panelMode = 'queue';
        panel.classList.remove('mode-lyrics');
        var q = Player.queue(), i = Player.index();
        var upcoming = q.slice(i + 1, i + 7);
        panelTitle.textContent = upcoming.length ? T('Als Nächstes') : '';
        if (upcoming.length) {
          var list = UI.trackList(upcoming, { showCover: true, header: false, onPlay: function (k) { Player.jump(i + 1 + k); } });
          list.classList.add('np-upnext');
          panel.appendChild(list);
        }
      }
      if (hadFocus) Nav.focus(btnPlay);
    }

    function renderTrack() {
      var s = Player.current(), st = Player.station();
      el.classList.toggle('live', !!st);
      renderContext();
      if (st) {
        coverEl.src = UI.radioArt(st.name);
        title.textContent = st.name;
        artist.textContent = T('Live-Radio');
        bg.style.background = 'linear-gradient(180deg,#3a3a5a 0,#151520 100%)';
        renderPanel();
        return;
      }
      if (!s) {
        title.textContent = T('Nichts in der Wiedergabe'); artist.textContent = '';
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

    renderTrack(); renderState(); renderTime(); renderSleep();
    setTimeout(function () { App.viewReady(el); }, 0);
    return {
      el: el,
      update: function (evt) {
        if (evt === 'track') renderTrack();
        if (evt === 'queue' && panelMode === 'queue') renderPanel();
        if (evt === 'mode') renderContext();
        if (evt === 'sleep' || evt === 'time') renderSleep();
        if (evt === 'state' || evt === 'mode' || evt === 'track') renderState();
        if (evt === 'time' || evt === 'track') renderTime();
      }
    };
  }

  // ---------------- Warteschlange
  function queue() {
    var el = view();
    var holder = h('div');
    var moving = -1, restList = null; // Song, der gerade verschoben wird (Stelle in der Warteschlange)

    function movingRow() {
      var rows = restList ? U.$$('.track', restList) : [];
      return rows[moving - Player.index() - 1];
    }
    function startMove(k) {
      moving = k;
      render();
      var r = movingRow();
      if (r) Nav.focus(r);
    }
    function endMove() {
      var r = movingRow();
      moving = -1;
      if (r) r.classList.remove('moving');
      U.$$('.move-hint', el).forEach(function (x) { x.parentNode.removeChild(x); });
    }
    // Beim Verschieben: ▲▼ schieben den Song, OK oder Zurück legen ihn ab
    Nav.onKey(function (e, code) {
      if (moving < 0 || !el.isConnected) return false;
      var K = Nav.KEY, idx = Player.index(), last = Player.queue().length - 1;
      if (code === K.UP || code === K.DOWN) {
        var to = moving + (code === K.UP ? -1 : 1);
        if (to > idx && to <= last) { var from = moving; moving = to; Player.move(from, to); }
        return true;
      }
      if (code === K.ENTER || code === K.BACK || code === K.ESC || code === K.BACKSPACE) { endMove(); return true; }
      return code === K.LEFT || code === K.RIGHT;
    });

    function render() {
      var q = Player.queue(), idx = Player.index();
      holder.innerHTML = '';
      holder.appendChild(UI.header(T('Warteschlange')));
      if (!q.length) { holder.appendChild(h('div.empty', { text: T('Deine Warteschlange ist leer.') })); return; }
      holder.appendChild(h('div.chips.nav-container', null,
        UI.chip(T('Zufällig'), function () { Player.setShuffle(!Player.shuffle()); }, Player.shuffle()),
        UI.chip(T('Als Playlist speichern'), function () { Menus.addToPlaylist(q); }),
        UI.chip(T('Leeren'), function () { UI.confirm(T('Warteschlange leeren?'), T('Leeren'), function () { Player.stop(); }, 'trash'); })
      ));
      var extra = function (i) { return [{ icon: 'close', label: T('Aus Warteschlange entfernen'), action: function () { Player.removeAt(i); } }]; };
      if (idx >= 0) {
        holder.appendChild(h('h2.section-title', { text: T('Läuft gerade'), style: 'margin-top:10px' }));
        holder.appendChild(UI.trackList([q[idx]], { showCover: true, showAlbum: true, header: false, onPlay: function () { Player.toggle(); }, menuExtra: function () { return extra(idx); } }));
      }
      var rest = q.slice(idx + 1);
      if (rest.length) {
        holder.appendChild(h('h2.section-title', { text: T.n(rest.length, 'Als Nächstes · {n} Song, {dur}', 'Als Nächstes · {n} Songs, {dur}', { dur: U.fmtDuration(rest.reduce(function (a, s) { return a + (s.duration || 0); }, 0)) }) }));
        if (moving >= 0) holder.appendChild(h('div.move-hint', { text: T('▲ ▼ verschieben · OK ablegen') }));
        restList = UI.trackList(rest, { showCover: true, showAlbum: true, header: false,
          onPlay: function (i) { Player.jump(idx + 1 + i); },
          menuExtra: function (i) {
            return (rest.length > 1 ? [{ icon: 'reorder', label: T('Verschieben'), action: function () { startMove(idx + 1 + i); } }] : []).concat(extra(idx + 1 + i));
          } });
        holder.appendChild(restList);
        var mr = movingRow();
        if (mr) mr.classList.add('moving');
      } else restList = null;
      UI.refreshPlaying();
    }
    el.appendChild(holder);
    render();
    setTimeout(function () { App.viewReady(el); }, 0);
    return {
      el: el,
      update: function (evt) {
        if ((evt === 'queue' || evt === 'mode') && moving >= 0) {
          if (moving >= Player.queue().length || moving <= Player.index()) moving = -1;
          render();
          var mr = movingRow();
          if (mr) Nav.focus(mr); else Nav.focusFirst(el);
          return;
        }
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
    el.appendChild(UI.header(T('Einstellungen')));

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

    el.appendChild(h('div.settings-section', { text: T('Wiedergabe') }));
    el.appendChild(option(T('Streaming-Qualität'), T('Original spielt die Datei unverändert ab'), [[0, T('Original')], [320, '320 kbps'], [192, '192 kbps'], [128, '128 kbps']], 'maxBitRate', function () { Player.reloadCurrent(); }));
    el.appendChild(option(T('Format bei Umwandlung'), T('Nur relevant, wenn nicht „Original“'), [['mp3', 'MP3'], ['opus', 'Opus'], ['aac', 'AAC']], 'format', function () { Player.reloadCurrent(); }));
    el.appendChild(option(T('Scrobbeln'), T('Gehörte Songs an den Server melden'), [[true, T('An')], [false, T('Aus')]], 'scrobble'));
    el.appendChild(option(T('Überblenden'), T('Songs gehen weich ineinander über'), [[0, T('Aus')], [3, T('{n} s', { n: 3 })], [6, T('{n} s', { n: 6 })], [9, T('{n} s', { n: 9 })], [12, T('{n} s', { n: 12 })]], 'crossfade'));
    el.appendChild(option(T('Autoplay'), T('Wenn ein Album oder eine Playlist endet, laufen ähnliche Songs weiter'), [[true, T('An')], [false, T('Aus')]], 'autoplay'));
    el.appendChild(option(T('Lautstärke angleichen'), T('Mit den ReplayGain-Angaben deiner Dateien'), [['off', T('Aus')], ['track', T('Pro Song')], ['album', T('Pro Album')]], 'leveling', function () { Player.applyVolume(); }));

    el.appendChild(h('div.settings-section', { text: T('Anzeige') }));
    el.appendChild(option(T('Bildschirmschoner'), T('Schützt das OLED-Panel vor Einbrennen'), [[0, T('Aus')], [1, T('{n} Min.', { n: 1 })], [3, T('{n} Min.', { n: 3 })], [5, T('{n} Min.', { n: 5 })], [10, T('{n} Min.', { n: 10 })]], 'screensaver'));
    el.appendChild(option(T('Startansicht'), null, [['home', T('Start')], ['nowplaying', T('Läuft gerade')], ['albums', T('Alben')]], 'startView'));

    var langBtn = UI.button(I18N.choice() === 'auto' ? T('Automatisch ({lang})', { lang: I18N.languages[I18N.lang()] }) : I18N.languages[I18N.lang()], function () {
      var items = [{ label: T('Automatisch (Sprache des Fernsehers)'), action: function () { I18N.set('auto'); } }];
      Object.keys(I18N.languages).forEach(function (code) {
        items.push({ label: I18N.languages[code], action: function () { I18N.set(code); } });
      });
      UI.modal(T('Sprache'), items);
    }, 'outline');
    el.appendChild(h('div.setting', null, h('div', null, h('div.setting-label', { text: T('Sprache') }), h('div.setting-desc', { text: 'Language · Idioma · Langue · Lingua · Taal · Język · Dil' })), h('div.nav-container', null, langBtn)));

    el.appendChild(h('div.settings-section', { text: T('Konto') }));
    var infoText = h('div.setting-desc', { text: cfg.url });
    API.ping().then(function (r) { infoText.textContent = cfg.url + ' • ' + (r.type || 'Subsonic') + ' ' + (r.serverVersion || ''); }).catch(function () { });
    el.appendChild(h('div.setting', null, h('div', null, h('div.setting-label', { text: T('Angemeldet als {name}', { name: cfg.user }) }), infoText)));
    el.appendChild(h('div.settings-actions.nav-container', null,
      UI.button(T('Benutzer wechseln'), App.showUsers, 'primary', 'swap'),
      UI.button(T('Konto entfernen'), function () { UI.confirm(T('Konto „{name}“ von diesem TV entfernen?', { name: cfg.user }), T('Entfernen'), App.logout, 'trash'); }, 'danger', 'logout'),
      UI.button(T('App beenden'), App.exit, 'outline', 'power')
    ));

    el.appendChild(h('div.settings-section', { text: T('iPhone') }));
    var phones = Link.phones();
    el.appendChild(h('div.setting', null, h('div', null,
      h('div.setting-label', { text: phones.length ? phones.map(function (p) { return p.guest ? T('{name} (Gast)', { name: p.device }) : p.device; }).join(', ') : T('Kein iPhone verbunden') }),
      h('div.setting-desc', { text: T('In Tonalo auf dem iPhone siehst du, was hier läuft, und kannst Musik für den TV auswählen. Gäste der Jukebox können Songs hinzufügen und überspringen. Verbinden über „TV & Jukebox“ in der iPhone-App.') }))));
    if (phones.length) el.appendChild(h('div.settings-actions.nav-container', null,
      UI.button(T('Alle trennen'), function () { Link.forget(); App.reload(); }, 'outline', 'close')));

    el.appendChild(h('div.settings-section', { text: T('Fernbedienung') }));
    el.appendChild(h('div.keys', { html:
      T('<b>▶ / ❚❚ / ■</b> Play, Pause, Stopp · <b>⏪ ⏩</b> 10 s spulen, gedrückt halten = Song wechseln · <b>CH + / –</b> seitenweise scrollen<br>') +
      T('<b style="color:#e53935">Rot</b> Läuft gerade · <b style="color:#43a047">Grün</b> Suchen · <b style="color:#fdd835">Gelb</b> Optionen · <b style="color:#1e88e5">Blau</b> Play/Pause') }));
    el.appendChild(h('div.version', { text: 'Tonalo · ' + T('inoffizieller Navidrome-Client für LG webOS') + ' · v' + APP_VERSION }));
    setTimeout(function () { App.viewReady(el); }, 0);
    return { el: el };
  }

  return {
    home: home, albums: albums, artists: artists, artist: artist, album: album,
    playlists: playlists, playlist: playlist, genres: genres, genre: genre,
    starred: starred, search: search, nowplaying: nowplaying, queue: queue, settings: settings, radio: radio
  };
})();
