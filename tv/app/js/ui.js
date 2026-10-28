/* Wiederverwendbare UI-Bausteine */
var UI = (function () {
  'use strict';
  var h = U.h;

  function icon(name, size) { return Icon.el(name, size); }

  // ---- Lazy-Loading für Cover
  var io = ('IntersectionObserver' in window) ? new IntersectionObserver(function (entries) {
    entries.forEach(function (en) {
      if (en.isIntersecting) { loadImg(en.target); io.unobserve(en.target); }
    });
  }, { rootMargin: '600px' }) : null;

  // Navidromes Standardbild für Künstler ohne Foto (heller, grauer Stern) erkennen
  function isPlaceholder(img) {
    try {
      var c = document.createElement('canvas'); c.width = c.height = 12;
      var ctx = c.getContext('2d');
      ctx.drawImage(img, 0, 0, 12, 12);
      var d = ctx.getImageData(0, 0, 12, 12).data, bright = 0, sat = 0, n = d.length / 4;
      for (var i = 0; i < d.length; i += 4) {
        var mx = Math.max(d[i], d[i + 1], d[i + 2]), mn = Math.min(d[i], d[i + 1], d[i + 2]);
        bright += mx; sat += mx - mn;
      }
      return sat / n < 6 && bright / n > 170;
    } catch (e) { return false; }
  }

  function loadImg(img) {
    var src = img.getAttribute('data-src');
    if (!src) return;
    var checkPh = img.hasAttribute('data-check');
    if (checkPh) img.crossOrigin = 'anonymous';
    img.onload = function () {
      if (checkPh && isPlaceholder(img)) { img.classList.add('broken'); return; }
      img.classList.add('loaded');
    };
    img.onerror = function () { img.classList.add('broken'); };
    img.src = src;
    img.removeAttribute('data-src');
  }

  function cover(id, size, cls, fallbackIcon) {
    var wrap = h('div.cover' + (cls ? '.' + cls : ''));
    var img = h('img', { alt: '' });
    if (id) {
      img.setAttribute('data-src', API.cover(id, size || 300));
      if (fallbackIcon === 'artist') img.setAttribute('data-check', '');
      if (io) io.observe(img); else loadImg(img);
    } else {
      img.classList.add('broken');
    }
    wrap.appendChild(img);
    wrap.appendChild(h('div.cover-fallback', null, icon(fallbackIcon || 'album')));
    return wrap;
  }

  // ---- Dominante Coverfarbe für Kopfbereiche
  var colorCache = {};
  function coverColor(url) {
    if (!url) return Promise.resolve(null);
    if (colorCache[url]) return colorCache[url];
    colorCache[url] = new Promise(function (resolve) {
      var img = new Image();
      img.crossOrigin = 'anonymous';
      img.onload = function () {
        try {
          var c = document.createElement('canvas'); c.width = c.height = 24;
          var ctx = c.getContext('2d');
          ctx.drawImage(img, 0, 0, 24, 24);
          var d = ctx.getImageData(0, 0, 24, 24).data, r = 0, g = 0, b = 0, wsum = 0;
          for (var i = 0; i < d.length; i += 4) {
            var mx = Math.max(d[i], d[i + 1], d[i + 2]), mn = Math.min(d[i], d[i + 1], d[i + 2]);
            var w = 0.15 + (mx - mn) / 255 + (mx > 40 && mx < 235 ? 0.3 : 0); // bunte, mittlere Töne bevorzugen
            r += d[i] * w; g += d[i + 1] * w; b += d[i + 2] * w; wsum += w;
          }
          resolve(tone([r / wsum, g / wsum, b / wsum]));
        } catch (e) { resolve(null); }
      };
      img.onerror = function () { resolve(null); };
      img.src = url;
    });
    return colorCache[url];
  }

  // Farbe in einen gedeckten, mittel-dunklen Ton bringen
  function tone(rgb) {
    var r = rgb[0] / 255, g = rgb[1] / 255, b = rgb[2] / 255;
    var mx = Math.max(r, g, b), mn = Math.min(r, g, b), l = (mx + mn) / 2, s = 0, hh = 0, dd = mx - mn;
    if (dd) {
      s = l > 0.5 ? dd / (2 - mx - mn) : dd / (mx + mn);
      hh = mx === r ? (g - b) / dd + (g < b ? 6 : 0) : mx === g ? (b - r) / dd + 2 : (r - g) / dd + 4;
      hh /= 6;
    }
    s = Math.min(s, 0.6); l = Math.max(0.24, Math.min(l, 0.38));
    function f(p, q, t) { if (t < 0) t += 1; if (t > 1) t -= 1; if (t < 1 / 6) return p + (q - p) * 6 * t; if (t < 1 / 2) return q; if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6; return p; }
    var q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q;
    return [Math.round(f(p, q, hh + 1 / 3) * 255), Math.round(f(p, q, hh) * 255), Math.round(f(p, q, hh - 1 / 3) * 255)];
  }

  function rgb(c, a) { return 'rgba(' + c[0] + ',' + c[1] + ',' + c[2] + ',' + (a == null ? 1 : a) + ')'; }

  // Farbverlauf oben in einer Ansicht
  function heroBg(viewEl, coverUrl, fallback) {
    var bg = h('div.hero-bg');
    var base = fallback || [83, 83, 83];
    function paint(c) { bg.style.background = 'linear-gradient(180deg,' + rgb(c) + ' 0,' + rgb(c, 0.55) + ' 360px,#121212 720px)'; }
    paint(base);
    viewEl.insertBefore(bg, viewEl.firstChild);
    coverColor(coverUrl).then(function (c) { if (c) paint(c); });
    return bg;
  }

  // ---- Karten
  function card(opts) {
    var el = h('button.card.focusable' + (opts.round ? '.round' : ''),
      { onclick: opts.onClick },
      cover(opts.coverId, 300, opts.round ? 'round' : null, opts.round ? 'artist' : 'album'),
      opts.round ? null : h('span.card-play', null, icon('play')),
      h('div.card-title.ellipsis', { text: opts.title || '' }),
      h('div.card-sub', { text: opts.sub || '' })
    );
    if (opts.onOptions) el.addEventListener('options', opts.onOptions);
    return el;
  }

  function albumCard(a) {
    return card({
      coverId: a.coverArt || a.id,
      title: a.name || a.title,
      sub: (a.year ? a.year + ' • ' : '') + (a.artist || ''),
      onClick: function () { App.go('album', { id: a.id }); },
      onOptions: function () { Menus.album(a); }
    });
  }

  function artistCard(a) {
    return card({
      coverId: a.coverArt || a.id,
      round: true,
      title: a.name,
      sub: T('Künstler|Einzahl'),
      onClick: function () { App.go('artist', { id: a.id }); },
      onOptions: function () { Menus.artist(a); }
    });
  }

  function playlistCard(p) {
    return card({
      coverId: p.coverArt || p.id,
      title: p.name,
      sub: (p.owner ? T('Von {name}', { name: p.owner }) + ' • ' : '') + T.n(p.songCount || 0, '{n} Song', '{n} Songs'),
      onClick: function () { App.go('playlist', { id: p.id }); }
    });
  }

  // Bild für Radiosender und Endlos-Radios: Farbverlauf (fest pro Name) mit Symbol, als Bild-Adresse
  function radioArt(name, iconName) {
    var hue = parseInt(md5(String(name || '').toLowerCase()).slice(0, 6), 16) % 360;
    var svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 120"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">' +
      '<stop offset="0" stop-color="hsl(' + hue + ',62%,46%)"/><stop offset="1" stop-color="hsl(' + ((hue + 40) % 360) + ',68%,22%)"/>' +
      '</linearGradient></defs><rect width="120" height="120" fill="url(#g)"/>' +
      '<g color="#fff" transform="translate(38 38)">' + Icon.svg(iconName || 'radio', 44) + '</g></svg>';
    return 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
  }

  function radioCard(o) {
    var el = h('button.card.radio-card.focusable', { onclick: o.onClick },
      h('div.cover', null, h('img.loaded', { alt: '', src: radioArt(o.artName || o.title, o.icon) }), o.live ? h('span.live-badge', { text: 'LIVE' }) : null),
      h('span.card-play', null, icon('play')),
      h('div.card-title.ellipsis', { text: o.title }),
      h('div.card-sub', { text: o.sub || '' })
    );
    if (o.playing) el.classList.add('playing');
    return el;
  }

  function stationCard(st, list) {
    var cur = Player.station();
    return radioCard({ title: st.name, sub: T('Live-Radio'), live: true, playing: cur && cur.id === st.id,
      onClick: function () { Player.playStation(st, list); App.go('nowplaying'); } });
  }

  // Endlos-Radios: aus den Favoriten, aus dem laufenden Song und je Genre
  function smartRadioCards(genres) {
    var cards = [radioCard({ title: T('Dein Radio'), sub: T('Endlos, nach deinen Lieblingssongs'), icon: 'heartFill', artName: 'your radio',
      onClick: function () {
        API.starred().then(function (s) {
          var seeds = U.shuffle(s.songs).slice(0, 10);
          return Radio.start(T('Dein Radio'), { seeds: seeds, seedId: seeds[0] && seeds[0].id, first: seeds[0] });
        }).then(function (ok) { if (ok) App.go('nowplaying'); }).catch(App.error);
      } })];
    var cur = Player.current();
    if (cur && cur.artist) {
      cards.push(radioCard({ title: T('Mehr wie {name}', { name: cur.artist }), sub: T('Radio zum Song, der gerade läuft'), artName: cur.artist,
        onClick: function () { Menus.radio(cur.id, cur); } }));
    }
    genres.forEach(function (g) {
      cards.push(radioCard({ title: g.value, sub: T('Genre-Radio'), icon: 'genre', artName: g.value,
        onClick: function () { Radio.start(g.value, { genre: g.value }).then(function (ok) { if (ok) App.go('nowplaying'); }); } }));
    });
    return cards;
  }

  // Genres mit genug Songs für ein Radio, die größten zuerst
  function radioGenres(list) {
    return list.filter(function (g) { return (g.songCount || 0) >= 20; })
      .sort(function (a, b) { return (b.songCount || 0) - (a.songCount || 0); });
  }

  // Schnellzugriff-Kachel (Startseite)
  function shortcut(opts) {
    var art = opts.art ? h('div.tile-art.' + opts.art.cls, null, icon(opts.art.icon)) : cover(opts.coverId, 120);
    var el = h('button.shortcut.focusable', { onclick: opts.onClick }, art, h('span.label.ellipsis', { text: opts.label }));
    if (opts.onOptions) el.addEventListener('options', opts.onOptions);
    return el;
  }

  // ---- Reihe mit „Alle anzeigen“
  function row(title, items, renderFn, moreFn) {
    var head = h('div.section-head', null, h('h2', { text: title }),
      moreFn ? h('div.nav-container', null, h('button.show-all.focusable', { text: T('Alle anzeigen'), onclick: moreFn })) : null);
    var track = h('div.row-track.nav-container', null, items.map(renderFn));
    return h('section.row', null, head, track);
  }

  // ---- Raster mit Nachladen
  function grid(renderFn, loader, pageSize) {
    var el = h('div.grid.nav-container');
    var offset = 0, loading = false, done = false;
    function more() {
      if (loading || done) return Promise.resolve();
      loading = true;
      return loader(offset, pageSize).then(function (items) {
        items.forEach(function (it) { el.appendChild(renderFn(it)); });
        offset += items.length;
        if (items.length < pageSize) done = true;
        if (!offset) el.appendChild(h('div.empty', { text: T('Nichts gefunden.') }));
        loading = false;
      }).catch(function (e) { loading = false; App.error(e); });
    }
    el.addEventListener('navfocus', function (e) {
      var idx = Array.prototype.indexOf.call(el.children, e.target);
      if (idx > el.children.length - 14) more();
    });
    return { el: el, more: more };
  }

  function staticGrid(items, renderFn) {
    if (!items.length) return h('div.empty', { text: T('Nichts gefunden.') });
    return h('div.grid.nav-container', null, items.map(renderFn));
  }

  // ---- Titelliste mit Spaltenkopf
  function trackList(songs, opts) {
    opts = opts || {};
    var list = h('div.tracklist.nav-container');
    if (opts.header !== false && songs.length) {
      list.appendChild(h('div.tl-head', null,
        h('span.t-num', { text: '#' }),
        h('span.t-main', { text: T('Titel') }),
        opts.showAlbum ? h('span.t-album', { text: T('Album') }) : null,
        h('span.t-heart'),
        h('span.t-dur', null, icon('clock')),
        h('span.t-more', { style: 'height:auto' })
      ));
    }
    songs.forEach(function (s, i) {
      var playing = Player.current() && Player.current().id === s.id;
      var num = opts.numbers === 'track' ? (s.track || i + 1) : i + 1;
      var openMenu = function () { Menus.song(s, opts.menuExtra ? opts.menuExtra(i) : null); };
      var row = h('button.track.focusable' + (playing ? '.playing' : ''),
        { onclick: function () { if (opts.onPlay) opts.onPlay(i); else Player.playList(songs, i); }, dataset: { id: s.id } },
        h('span.t-num', null, h('span', { text: num }), Icon.el('play', 24, 'play'), Icon.el('bars', 24, 'eq')),
        h('span.t-main', null,
          opts.showCover ? cover(s.coverArt || s.albumId, 80, 'tiny') : null,
          h('span.t-text', null,
            h('span.t-title.ellipsis', { text: s.title }),
            opts.hideArtist ? null : h('span.t-artist.ellipsis', { text: s.artist || '' })
          )
        ),
        opts.showAlbum ? h('span.t-album.ellipsis', { text: s.album || '' }) : null,
        h('span.t-heart', null, s.starred ? icon('heartFill') : null),
        h('span.t-dur', { text: U.fmtTime(s.duration) })
      );
      row.addEventListener('options', openMenu);
      var more = h('button.t-more.focusable', { onclick: openMenu }, icon('more'));
      list.appendChild(h('div.track-row', null, row, more));
    });
    if (!songs.length) list.appendChild(h('div.empty', { text: T('Keine Songs.') }));
    return list;
  }

  function refreshPlaying() {
    var cur = Player.current();
    U.$$('.track').forEach(function (el) { el.classList.toggle('playing', !!cur && el.dataset.id === cur.id); });
  }

  // ---- Buttons
  function button(label, onClick, cls, iconName) {
    return h('button.btn.focusable' + (cls ? '.' + cls : ''), { onclick: onClick }, iconName ? icon(iconName) : null, h('span', { text: label }));
  }
  function chip(label, onClick, active) {
    return h('button.chip.focusable' + (active ? '.active' : ''), { onclick: onClick, text: label });
  }
  function iconBtn(name, onClick, title, cls) {
    return h('button.icon-btn.focusable' + (cls ? '.' + cls : ''), { onclick: onClick, title: title }, icon(name));
  }
  function playBig(onClick, autofocus) {
    return h('button.play-big.focusable', { onclick: onClick, title: T('Abspielen'), 'data-autofocus': autofocus || null }, icon('play'));
  }
  function setIcon(btn, name) { btn.innerHTML = Icon.svg(name); }

  function header(title) { return h('h1.page-title', { text: title }); }
  function loading() { return h('div.loading', null, h('div.spinner')); }

  // ---- Kontextmenüs
  var modalStack = [];
  function modal(title, items, opts) {
    opts = opts || {};
    var layer = U.$('#modal-layer');
    var prevFocus = Nav.current();
    var box = h('div.modal');
    if (opts.head) {
      box.appendChild(h('div.modal-head', null,
        opts.head.coverId !== undefined ? cover(opts.head.coverId, 120, opts.head.round ? 'round' : null) : null,
        h('div', null, h('div.mh-title.ellipsis', { text: opts.head.title }), opts.head.sub ? h('div.mh-sub.ellipsis', { text: opts.head.sub }) : null)
      ));
    } else if (title) {
      box.appendChild(h('div.modal-head', null, h('div', null, h('div.mh-title', { text: title }))));
    }
    var list = h('div.modal-list.nav-container');
    items.filter(Boolean).forEach(function (it) {
      list.appendChild(h('button.modal-item.focusable' + (it.danger ? '.danger' : ''), {
        onclick: function () { close(); if (it.action) it.action(); }
      }, it.icon ? icon(it.icon) : null, h('span', { text: it.label })));
    });
    box.appendChild(list);
    var entry = { box: box, prevFocus: prevFocus };
    function close() {
      var i = modalStack.indexOf(entry);
      if (i >= 0) modalStack.splice(i, 1);
      if (box.parentNode) box.parentNode.removeChild(box);
      if (!modalStack.length) layer.classList.add('hidden');
      App.updateScope();
      if (prevFocus && document.body.contains(prevFocus) && prevFocus.offsetParent) Nav.focus(prevFocus);
      else Nav.focusFirst();
    }
    entry.close = close;
    modalStack.push(entry);
    layer.innerHTML = '';
    layer.appendChild(box);
    layer.classList.remove('hidden');
    App.updateScope();
    Nav.focusFirst(box);
    return entry;
  }
  function closeModal() { var m = modalStack[modalStack.length - 1]; if (m) { m.close(); return true; } return false; }
  function modalOpen() { return modalStack.length > 0; }

  function confirm(title, okLabel, onOk, okIcon) {
    modal(title, [{ label: okLabel, icon: okIcon || 'close', action: onOk, danger: true }, { label: T('Abbrechen'), icon: 'prev' }]);
  }

  // Texteingabe im Fenster (z. B. Playlist umbenennen)
  function prompt(title, value, okLabel, onOk) {
    var m = modal(title, [{ label: T('Abbrechen'), icon: 'prev' }]);
    var input = h('input.modal-input.focusable', { type: 'text', autocomplete: 'off' });
    input.value = value || '';
    function done() {
      var v = input.value.trim();
      if (!v) return;
      m.close();
      onOk(v);
    }
    input.addEventListener('submit', done);
    input.addEventListener('keydown', function (e) { if (e.keyCode === 13) { e.preventDefault(); e.stopPropagation(); input.blur(); done(); } });
    var ok = h('button.modal-item.focusable', { onclick: done }, icon('edit'), h('span', { text: okLabel }));
    var list = U.$('.modal-list', m.box);
    list.insertBefore(ok, list.firstChild);
    list.insertBefore(input, ok);
    Nav.focus(input, { noInputFocus: true });
    return m;
  }

  return {
    icon: icon, cover: cover, coverColor: coverColor, heroBg: heroBg, rgb: rgb,
    card: card, albumCard: albumCard, artistCard: artistCard, playlistCard: playlistCard, shortcut: shortcut,
    row: row, grid: grid, staticGrid: staticGrid, trackList: trackList, refreshPlaying: refreshPlaying,
    button: button, chip: chip, iconBtn: iconBtn, playBig: playBig, setIcon: setIcon, header: header, loading: loading,
    modal: modal, closeModal: closeModal, modalOpen: modalOpen, confirm: confirm, prompt: prompt,
    radioArt: radioArt, radioCard: radioCard, stationCard: stationCard, smartRadioCards: smartRadioCards, radioGenres: radioGenres
  };
})();

/* Kontextmenüs (gelbe Taste / ⋯) */
var Menus = (function () {
  'use strict';

  function starItem(type, obj, onDone) {
    var on = !obj.starred;
    return {
      icon: on ? 'heart' : 'heartFill',
      label: on ? T('Zu Favoriten hinzufügen') : T('Aus Favoriten entfernen'),
      action: function () {
        API.star(type, obj.id, on).then(function () {
          obj.starred = on ? new Date().toISOString() : undefined;
          if (type === 'song') Player.setStarred(obj, on);
          U.toast(on ? T('Zu Favoriten hinzugefügt') : T('Aus Favoriten entfernt'));
          if (onDone) onDone();
        }).catch(App.error);
      }
    };
  }

  function addToPlaylist(songs) {
    API.playlists().then(function (pls) {
      var items = [{
        icon: 'plus', label: T('Neue Playlist'),
        action: function () {
          var name = T('Neue Playlist {date}', { date: new Date().toLocaleDateString(I18N.locale()) });
          API.createPlaylist(name, songs.map(function (s) { return s.id; }))
            .then(function () { U.toast(T('„{name}“ erstellt', { name: name })); }).catch(App.error);
        }
      }];
      pls.filter(ownPlaylist).forEach(function (p) {
        items.push({ icon: 'playlist', label: p.name, action: function () { addChecked(p, songs); } });
      });
      UI.modal(T('Zur Playlist hinzufügen'), items);
    }).catch(App.error);
  }

  // Nur eigene Playlists lassen sich ändern (fremde, auch öffentliche, nicht)
  function ownPlaylist(p) { return !p.readonly && (!p.owner || p.owner === API.getConfig().user); }

  // Vorher nachsehen, ob Songs schon in der Playlist sind – dann fragen statt doppelt einfügen
  function addChecked(p, songs) {
    function add(list) {
      API.addToPlaylist(p.id, list.map(function (s) { return s.id; }))
        .then(function () { U.toast(T('Zu „{name}“ hinzugefügt', { name: p.name })); }).catch(App.error);
    }
    API.playlist(p.id).then(function (pl) {
      var have = {};
      U.asArray(pl.entry).forEach(function (s) { have[s.id] = true; });
      var fresh = songs.filter(function (s) { return !have[s.id]; });
      var dupes = songs.length - fresh.length;
      if (!dupes) { add(songs); return; }
      UI.modal(songs.length === 1 ? T('Schon in „{name}“', { name: p.name }) : T.n(dupes, '{n} Song ist schon in „{name}“', '{n} Songs sind schon in „{name}“', { name: p.name }), [
        fresh.length ? { icon: 'plus', label: T('Nur neue hinzufügen'), action: function () { add(fresh); } } : null,
        { icon: 'addQueue', label: T('Trotzdem hinzufügen'), action: function () { add(songs); } },
        { icon: 'prev', label: T('Abbrechen') }
      ]);
    }).catch(function () { add(songs); });
  }

  function song(s, extra) {
    UI.modal(null, [
      { icon: 'play', label: T('Abspielen'), action: function () { Player.playList([s], 0); } },
      { icon: 'playNext', label: T('Als Nächstes abspielen'), action: function () { Player.playNext([s]); } },
      { icon: 'addQueue', label: T('Zur Warteschlange hinzufügen'), action: function () { Player.enqueue([s]); } },
      { icon: 'radio', label: T('Song-Radio starten'), action: function () { radio(s.id, s); } },
      starItem('song', s),
      { icon: 'plus', label: T('Zur Playlist hinzufügen'), action: function () { addToPlaylist([s]); } },
      s.albumId ? { icon: 'album', label: T('Album anzeigen'), action: function () { App.go('album', { id: s.albumId }); } } : null,
      s.artistId ? { icon: 'artist', label: T('Künstler anzeigen'), action: function () { App.go('artist', { id: s.artistId }); } } : null
    ].concat(extra || []), { head: { coverId: s.coverArt || s.albumId, title: s.title, sub: s.artist } });
  }

  function album(a) {
    function withSongs(fn) { API.album(a.id).then(function (al) { fn(U.asArray(al.song)); }).catch(App.error); }
    UI.modal(null, [
      { icon: 'play', label: T('Abspielen'), action: function () { withSongs(function (s) { Player.playList(s, 0); }); } },
      { icon: 'shuffle', label: T('Zufallswiedergabe'), action: function () { withSongs(function (s) { Player.playList(s, 0, { shuffle: true }); }); } },
      { icon: 'playNext', label: T('Als Nächstes abspielen'), action: function () { withSongs(Player.playNext); } },
      { icon: 'addQueue', label: T('Zur Warteschlange hinzufügen'), action: function () { withSongs(Player.enqueue); } },
      starItem('album', a),
      { icon: 'plus', label: T('Zur Playlist hinzufügen'), action: function () { withSongs(addToPlaylist); } },
      a.artistId ? { icon: 'artist', label: T('Künstler anzeigen'), action: function () { App.go('artist', { id: a.artistId }); } } : null
    ], { head: { coverId: a.coverArt || a.id, title: a.name, sub: a.artist } });
  }

  function artist(a) {
    UI.modal(null, [
      { icon: 'radio', label: T('Künstler-Radio starten'), action: function () { radio(a.id, a); } },
      { icon: 'shuffle', label: T('Alle Songs zufällig'), action: function () { artistShuffle(a.id); } },
      starItem('artist', a),
      { icon: 'artist', label: T('Künstler anzeigen'), action: function () { App.go('artist', { id: a.id }); } }
    ], { head: { coverId: a.coverArt || a.id, title: a.name, sub: T('Künstler|Einzahl'), round: true } });
  }

  // Endlos-Radio aus einem Song (läuft zuerst) oder einem Künstler
  function radio(id, seed) {
    var song = seed && seed.title ? seed : null;
    Radio.start((seed && (seed.title || seed.name)) || T('Radio'), { seedId: id, first: song })
      .then(function (ok) { if (ok) App.go('nowplaying'); });
  }

  function artistShuffle(id) {
    API.artist(id).then(function (ar) {
      return Promise.all(U.asArray(ar.album).map(function (al) { return API.album(al.id); }));
    }).then(function (albums) {
      var songs = [];
      albums.forEach(function (al) { songs = songs.concat(U.asArray(al.song)); });
      Player.playList(songs, 0, { shuffle: true });
    }).catch(App.error);
  }

  return { song: song, album: album, artist: artist, radio: radio, artistShuffle: artistShuffle, addToPlaylist: addToPlaylist, ownPlaylist: ownPlaylist };
})();
