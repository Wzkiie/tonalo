/* Ansichten für Hörbücher und Podcasts (Audiobookshelf): Übersicht, Bibliothek, Suche, Detail und Player */
var BookViews = (function () {
  'use strict';
  var h = U.h, A = U.asArray;

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
      el.appendChild(h('div.empty', { text: e.message }));
      el.appendChild(h('div.nav-container', null, UI.button(T('Erneut versuchen'), function () { App.reload(); }, 'outline')));
      App.viewReady(el);
    });
  }

  // ---------- Angaben aus einem Eintrag
  function meta(it) { return (it && it.media && it.media.metadata) || {}; }
  function titleOf(it, ep) { return ep ? ep.title : meta(it).title || ''; }
  function authorOf(it) { var m = meta(it); return m.authorName || m.author || ''; }
  function isPodcast(it) { return it && it.mediaType === 'podcast'; }
  function lengthOf(it, ep) { return ep ? (ep.duration || (ep.audioFile && ep.audioFile.duration) || 0) : (it.media && it.media.duration) || 0; }

  // Cover mit Anmeldung geholt (der Dienst), erst wenn sie ins Bild kommen
  var io = ('IntersectionObserver' in window) ? new IntersectionObserver(function (entries) {
    entries.forEach(function (en) { if (en.isIntersecting) { io.unobserve(en.target); fill(en.target); } });
  }, { rootMargin: '600px' }) : null;

  function fill(img) {
    var id = img.getAttribute('data-item'), w = +img.getAttribute('data-w') || 400;
    if (!id) return;
    img.removeAttribute('data-item');
    ABS.cover(id, w).then(function (url) {
      img.onload = function () { img.classList.add('loaded'); };
      img.src = url;
    }).catch(function () { img.classList.add('broken'); });
  }

  function cover(id, width, cls) {
    var wrap = h('div.cover' + (cls ? '.' + cls : ''));
    var img = h('img', { alt: '' });
    if (id) {
      img.setAttribute('data-item', id);
      img.setAttribute('data-w', width || 400);
      if (io) io.observe(img); else fill(img);
    } else img.classList.add('broken');
    wrap.appendChild(img);
    wrap.appendChild(h('div.cover-fallback', null, Icon.el('book')));
    return wrap;
  }

  // Fortschrittsbalken unten im Cover (nicht bei fertig Gehörtem)
  function progressBar(it, ep) {
    var p = ABS.progressOf(it.id, ep ? ep.id : (it.recentEpisode ? it.recentEpisode.id : null));
    if (!p) return null;
    if (p.isFinished) return h('span.bk-done', null, Icon.el('play', 20));
    return p.progress > 0.005 ? h('span.bk-bar', null, h('span', { style: 'width:' + Math.round(Math.min(1, p.progress) * 100) + '%' })) : null;
  }

  function card(it) {
    var ep = it.recentEpisode || null;
    var el = h('button.card.focusable.bk', { onclick: function () { App.go('book', { id: it.id, episode: ep ? ep.id : null }); } },
      cover(it.id, 400), h('span.card-play', null, Icon.el('play')),
      h('div.card-title.ellipsis', { text: titleOf(it, ep) }),
      h('div.card-sub', { text: ep ? meta(it).title : authorOf(it) }));
    var bar = progressBar(it, ep);
    if (bar) U.$('.cover', el).appendChild(bar);
    el.addEventListener('options', function () { itemMenu(it, ep); });
    return el;
  }

  function itemMenu(it, ep) {
    var done = ABS.finished(it.id, ep ? ep.id : null);
    UI.modal(null, [
      { icon: 'play', label: T('Abspielen'), action: function () { startPlayback(it.id, ep ? ep.id : null); } },
      { icon: 'book', label: T('Details'), action: function () { App.go('book', { id: it.id, episode: ep ? ep.id : null }); } },
      { icon: done ? 'refresh' : 'clock', label: done ? T('Als ungehört markieren') : T('Als gehört markieren'), action: function () {
        ABS.setFinished(it.id, ep ? ep.id : null, !done).then(function () { App.reload(); }).catch(App.error);
      } }
    ], { head: { title: titleOf(it, ep), sub: authorOf(it) } });
  }

  function startPlayback(id, episode, at) {
    Book.start(id, episode, at, null);
    ABS.item(id).then(function (it) {
      var ep = episode ? A(it.media && it.media.episodes).filter(function (e) { return e.id === episode; })[0] : null;
      if (Book.itemId() === id) Book.describe(episode ? (ep ? ep.title : '') : meta(it).title, episode ? meta(it).title : authorOf(it));
    }).catch(function () { });
  }

  // ---------- Übersicht
  function books() {
    var el = view('home');
    el.appendChild(h('h1.page-title', { text: T('Hörbücher & Podcasts') }));
    async(el, ABS.home(), function (r) {
      var bar = h('div.action-bar.nav-container', null,
        UI.button(T('Suchen'), function () { App.go('booksearch'); }, 'primary', 'search'));
      var shelvesOnly = r.libraries.filter(function (lib) { return lib.mediaType !== 'podcast'; });
      r.libraries.forEach(function (lib) {
        bar.appendChild(UI.button(lib.name, function () { App.go('booklib', { id: lib.id, name: lib.name }); }, 'outline', 'library'));
      });
      // Serien gibt es nur bei Hörbüchern, nicht bei Podcasts
      shelvesOnly.forEach(function (lib) {
        bar.appendChild(UI.button(shelvesOnly.length > 1 ? T('Serien') + ' – ' + lib.name : T('Serien'), function () { App.go('bookseries', { id: lib.id, name: lib.name }); }, 'outline', 'queue'));
      });
      el.appendChild(bar);
      if (!r.shelves.length) el.appendChild(h('div.empty', { text: T('Noch nichts da – in Audiobookshelf gibt es hier noch keine Bücher.') }));
      r.shelves.forEach(function (sh) { el.appendChild(UI.row(sh.title, sh.items, card)); });
    });
    return { el: el };
  }

  // ---------- Eine Bibliothek
  var SORTS = [['media.metadata.title', false, T('Titel')], ['addedAt', true, T('Neu hinzugefügt')], ['media.metadata.authorName', false, T('Autor')]];
  function booklib(params) {
    var el = view();
    var sort = SORTS[U.ustore.get('bookSort', 0)] || SORTS[0];
    el.appendChild(UI.header(params.name || T('Bibliothek')));
    var chips = h('div.chips.nav-container');
    SORTS.forEach(function (s, i) {
      var c = UI.chip(s[2], function () { U.ustore.set('bookSort', i); App.reload(); }, s === sort);
      chips.appendChild(c);
    });
    el.appendChild(h('div.filters', null, chips));
    var g = UI.grid(card, function (offset, size) {
      return ABS.items(params.id, Math.floor(offset / size), size, sort[0], sort[1]).then(function (r) { return r.items; });
    }, 60);
    el.appendChild(g.el);
    g.more().then(function () { App.viewReady(el); });
    return { el: el };
  }

  // ---------- Serien einer Bibliothek
  function seriesCard(lib) {
    return function (s) {
      var n = A(s.books).length || s.numBooks || 0;
      var first = A(s.books)[0];
      return h('button.card.focusable.bk', { onclick: function () { App.go('bookserie', { lib: lib, id: s.id, name: s.name }); } },
        cover(first && first.id, 400),
        h('div.card-title.ellipsis', { text: s.name }),
        h('div.card-sub', { text: n ? T.n(n, '{n} Buch', '{n} Bücher') : '' }));
    };
  }
  function bookseries(params) {
    var el = view();
    el.appendChild(h('h1.page-title', { text: T('Serien') }));
    var g = UI.grid(seriesCard(params.id), function (offset, size) {
      return ABS.series(params.id, Math.floor(offset / size), size).then(function (r) { return r.items; });
    }, 40);
    el.appendChild(g.el);
    g.more().then(function () {
      if (!g.el.children.length) g.el.appendChild(h('div.empty', { text: T('Nichts gefunden.') }));
      App.viewReady(el);
    });
    return { el: el };
  }
  // Die Bücher einer Serie, in der Reihenfolge der Serie
  function bookserie(params) {
    var el = view();
    el.appendChild(UI.header(params.name || T('Serien')));
    var g = UI.grid(card, function (offset, size) {
      return ABS.items(params.lib, Math.floor(offset / size), size, 'media.metadata.series', false, ['series', params.id]).then(function (r) { return r.items; });
    }, 60);
    el.appendChild(g.el);
    g.more().then(function () { App.viewReady(el); });
    return { el: el };
  }

  // ---------- Suche
  function booksearch() {
    var el = view();
    var input = h('input.search-input.focusable', { type: 'text', placeholder: T('Titel, Autor oder Podcast'), 'data-autofocus': true });
    var bar = h('div.search-bar', null, Icon.el('search', 34), input);
    var results = h('div.results');
    input.addEventListener('focus', function () { bar.classList.add('focus-in'); });
    input.addEventListener('blur', function () { bar.classList.remove('focus-in'); });
    el.appendChild(h('div.nav-container', null, bar));
    el.appendChild(results);
    var seq = 0;
    function run() {
      var q = input.value.trim();
      var my = ++seq;
      results.innerHTML = '';
      if (q.length < 2) return;
      results.appendChild(UI.loading());
      ABS.search(q).then(function (list) {
        if (my !== seq) return;
        results.innerHTML = '';
        if (!list.length) { results.appendChild(h('div.empty', { text: T('Keine Ergebnisse für „{q}“', { q: q }) })); return; }
        results.appendChild(UI.staticGrid(list, card));
      }).catch(function (e) { if (my === seq) { results.innerHTML = ''; results.appendChild(h('div.empty', { text: e.message })); } });
    }
    input.addEventListener('input', U.debounce(run, 700));
    input.addEventListener('keydown', function (e) { if (e.keyCode === 13) { e.preventDefault(); input.blur(); run(); setTimeout(function () { Nav.move('down'); }, 50); } });
    return { el: el, noAutoInput: true };
  }

  // ---------- Detail
  function when(ms) {
    if (!ms) return '';
    var d = new Date(ms);
    return d.toLocaleDateString(I18N.locale(), { day: 'numeric', month: 'short', year: 'numeric' });
  }

  function book(params) {
    var el = view('detail');
    async(el, ABS.item(params.id), function (it) {
      var m = meta(it), podcast = isPodcast(it);
      var chosenEp = params.episode ? A(it.media.episodes).filter(function (e) { return e.id === params.episode; })[0] : null;
      var big = h('div.hero-cover');
      big.appendChild(cover(it.id, 600));
      var progress = ABS.progressOf(it.id, chosenEp ? chosenEp.id : null);
      var metaRow = h('div.hero-meta.nav-container');
      var parts = [];
      if (!podcast) {
        if (m.narratorName) parts.push(T('Gesprochen von {name}', { name: m.narratorName }));
        if (m.seriesName) parts.push(m.seriesName);
        if (m.publishedYear) parts.push(String(m.publishedYear));
        if (it.media.duration) parts.push(U.fmtDuration(it.media.duration));
      } else {
        parts.push(T.n(A(it.media.episodes).length, '{n} Folge', '{n} Folgen'));
      }
      parts.forEach(function (x, i) { if (i) metaRow.appendChild(h('span.dot', { text: '•' })); metaRow.appendChild(h('span', { text: x })); });
      var desc = (m.description || '').replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim(); // nur Text, nie als HTML einsetzen
      UI.heroBg(el, null, [60, 52, 44]);
      el.appendChild(h('div.hero', null, big, h('div.hero-info', null,
        h('div.hero-type', { text: podcast ? T('Podcast') : T('Hörbuch') }),
        h('h1.hero-title' + (titleOf(it).length > 34 ? '.s' : titleOf(it).length > 16 ? '.m' : ''), { text: titleOf(it, chosenEp) }),
        podcast || !authorOf(it) ? (chosenEp ? h('p.bio', { text: m.title }) : null) : h('p.bio', { text: authorOf(it) }),
        metaRow)));

      var target = chosenEp || null;
      var label = progress && !progress.isFinished && progress.currentTime > 10
        ? T('Weiterhören bei {time}', { time: U.fmtTime(progress.currentTime) }) : T('Abspielen');
      var actions = h('div.action-bar.nav-container', null);
      // Ein Podcast braucht eine Folge: erst unten eine wählen
      if (!podcast || chosenEp) actions.appendChild(UI.button(label, function () { startPlayback(it.id, target ? target.id : null); App.go('bookplayer'); }, 'primary', 'play'));
      if (!podcast || chosenEp) {
        var done = ABS.finished(it.id, target ? target.id : null);
        actions.appendChild(UI.button(done ? T('Als ungehört markieren') : T('Als gehört markieren'), function () {
          ABS.setFinished(it.id, target ? target.id : null, !done).then(function () { App.reload(); }).catch(App.error);
        }, 'outline', done ? 'refresh' : 'clock'));
      }
      if (actions.children.length) el.appendChild(actions);
      if (desc) el.appendChild(h('p.bk-desc', { text: desc.length > 700 ? desc.slice(0, 697) + '…' : desc }));

      if (podcast && !chosenEp) {
        var eps = A(it.media.episodes).slice().sort(function (a, b) { return (b.publishedAt || 0) - (a.publishedAt || 0); });
        el.appendChild(h('h2.section-title', { text: T('Folgen') }));
        var list = h('div.tracklist.nav-container');
        eps.slice(0, 200).forEach(function (ep) {
          var p = ABS.progressOf(it.id, ep.id);
          var row = h('button.track.focusable', { onclick: function () { startPlayback(it.id, ep.id); App.go('bookplayer'); } },
            h('span.t-main', null, h('span.t-text', null,
              h('span.t-title.ellipsis', { text: ep.title || '' }),
              h('span.t-artist.ellipsis', { text: [when(ep.publishedAt), p && p.isFinished ? T('gehört') : p && p.progress > 0.01 ? T('{n} % gehört', { n: Math.round(p.progress * 100) }) : ''].filter(Boolean).join(' · ') }))),
            h('span.t-dur', { text: U.fmtTime(lengthOf(it, ep)) }));
          row.addEventListener('options', function () { itemMenu(it, ep); });
          list.appendChild(h('div.track-row', null, row));
        });
        el.appendChild(list);
        return;
      }
      var chapters = A(it.media.chapters);
      if (!podcast && chapters.length > 1) {
        el.appendChild(h('h2.section-title', { text: T('Kapitel') }));
        var cl = h('div.tracklist.nav-container');
        chapters.forEach(function (c, i) {
          cl.appendChild(h('div.track-row', null, h('button.track.focusable', { onclick: function () { startPlayback(it.id, null, c.start); App.go('bookplayer'); } },
            h('span.t-num', { text: i + 1 }),
            h('span.t-main', null, h('span.t-text', null, h('span.t-title.ellipsis', { text: c.title || T('Kapitel {n}', { n: i + 1 }) }))),
            h('span.t-dur', { text: U.fmtTime(c.start) }))));
        });
        el.appendChild(cl);
      }
    });
    return { el: el };
  }

  // ---------- Player (Vollbild)
  function bookplayer() {
    var el = view('np');
    var bg = h('div.np-bg');
    var coverEl = h('img.np-cover', { alt: '' });
    var title = h('div.np-title.ellipsis');
    var sub = h('div.np-artist');
    var chapterLine = h('div.bk-chapter.ellipsis');
    var bar = h('div.np-bar-fill');
    var progress = h('button.np-progress.focusable', null, h('div.np-bar', null, bar));
    var tCur = h('span'), tLeft = h('span');
    var btnPlay = h('button.np-play.focusable', { onclick: Book.toggle, title: T('Play/Pause'), 'data-autofocus': true });
    var btnBack = h('button.icon-btn.focusable', { onclick: Book.skipBack, title: T('Zurück') }); btnBack.innerHTML = Icon.skip(-1, Book.back, 40);
    var btnFwd = h('button.icon-btn.focusable', { onclick: Book.skipForward, title: T('Vor') }); btnFwd.innerHTML = Icon.skip(1, Book.forward, 40);
    var btnPrev = UI.iconBtn('prev', Book.prevChapter, T('Voriges Kapitel'));
    var btnNext = UI.iconBtn('next', Book.nextChapter, T('Nächstes Kapitel'));
    var btnRate = h('button.icon-btn.focusable.bk-rate', { onclick: rateMenu, title: T('Tempo') });
    var btnSleep = UI.iconBtn('moon', sleepMenu, T('Sleep-Timer'));
    var sleepLabel = h('span.np-sleep-left');
    btnSleep.appendChild(sleepLabel);
    var panelTitle = h('div.np-panel-title');
    var panel = h('div.np-lyrics.bk-chapters');
    var shownItem = null;

    progress.addEventListener('click', function (e) {
      if (e.clientX && Nav.pointerActive()) {
        var r = progress.getBoundingClientRect();
        Book.seek((e.clientX - r.left) / r.width * Book.duration());
      } else Book.toggle();
    });

    el.appendChild(bg);
    el.appendChild(h('div.np-main', null,
      h('div.np-top', null,
        h('div.np-left', null, h('div.np-context', { text: T('Hörbuch') }), coverEl,
          h('div.np-titlerow', null, h('div.np-titles', null, title, sub))),
        h('div.np-right', null, panelTitle, panel)),
      h('div.np-bottom', null,
        chapterLine,
        h('div.nav-container.np-progressrow', null, progress),
        h('div.np-time', null, tCur, tLeft),
        h('div.np-controls.nav-container', null, btnPrev, btnBack, btnPlay, btnFwd, btnNext,
          h('div.np-extra', null, btnRate, btnSleep),
          U.desktop ? Desktop.volume() : null)
      )));

    Nav.onKey(function (e, code) {
      if (Nav.current() !== progress || !el.isConnected) return false;
      if (code === Nav.KEY.LEFT) { Book.skipBack(); return true; }
      if (code === Nav.KEY.RIGHT) { Book.skipForward(); return true; }
      return false;
    });

    function rateMenu() {
      UI.modal(T('Tempo'), Book.rates.map(function (r) {
        return { icon: Book.rate() === r ? 'play' : 'clock', label: r + '×', action: function () { Book.setRate(r); } };
      }));
    }

    function sleepMenu() {
      var left = Book.sleepLeft();
      var items = [15, 30, 45, 60, 90].map(function (m) {
        return { icon: 'moon', label: T('{n} Min.', { n: m }), action: function () { Book.setSleep(m); U.toast(T('Sleep-Timer: {n} Min.', { n: m })); } };
      });
      if (Book.chapters().length) items.push({ icon: 'clock', label: T('Ende des Kapitels'), action: function () { Book.setSleepChapter(); U.toast(T('Sleep-Timer: Ende des Kapitels')); } });
      if (left) items.unshift({ icon: 'close', label: T('Sleep-Timer ausschalten'), action: function () { Book.cancelSleep(); U.toast(T('Sleep-Timer aus')); } });
      UI.modal(left > 0 ? T('Sleep-Timer · noch {time}', { time: U.fmtTime(left / 1000) }) : left < 0 ? T('Sleep-Timer · Ende des Kapitels') : T('Sleep-Timer'), items);
    }

    function renderSleep() {
      var left = Book.sleepLeft();
      btnSleep.classList.toggle('on', !!left);
      sleepLabel.textContent = left > 0 ? Math.ceil(left / 60000) + '′' : '';
    }

    function renderChapters() {
      panel.innerHTML = '';
      var list = Book.chapters();
      panelTitle.textContent = list.length > 1 ? T('Kapitel') : '';
      if (list.length < 2) return;
      var box = h('div.tracklist.np-upnext.nav-container');
      var cur = Book.chapterIndex();
      list.forEach(function (c, i) {
        box.appendChild(h('div.track-row', null, h('button.track.focusable' + (i === cur ? '.on-air' : ''), { onclick: function () { Book.seek(c.start); } },
          h('span.t-num', { text: i + 1 }),
          h('span.t-main', null, h('span.t-text', null, h('span.t-title.ellipsis', { text: c.title || T('Kapitel {n}', { n: i + 1 }) }))),
          h('span.t-dur', { text: U.fmtTime(c.start) }))));
      });
      panel.appendChild(box);
      var on = U.$('.on-air', box);
      if (on) panel.scrollTop = Math.max(0, on.offsetTop - 160);
    }

    function renderTrack() {
      var id = Book.itemId();
      el.classList.toggle('podcast', false);
      if (!id) {
        title.textContent = T('Nichts in der Wiedergabe'); sub.textContent = '';
        coverEl.removeAttribute('src'); bg.style.background = '#121212';
        panel.innerHTML = ''; panelTitle.textContent = ''; shownItem = null;
        return;
      }
      title.textContent = Book.title();
      sub.textContent = Book.author();
      if (shownItem !== id) {
        shownItem = id;
        coverEl.removeAttribute('src');
        ABS.cover(id, 800).then(function (url) {
          if (Book.itemId() !== id) return;
          coverEl.src = url;
          UI.coverColor(url).then(function (c) {
            c = c || [83, 83, 83];
            var d = [Math.round(c[0] * 0.45), Math.round(c[1] * 0.45), Math.round(c[2] * 0.45)];
            bg.style.background = 'linear-gradient(180deg,' + UI.rgb(c) + ' 0,' + UI.rgb(d) + ' 100%)';
          });
        }).catch(function () { });
      }
      renderChapters();
    }

    function renderState() {
      UI.setIcon(btnPlay, Book.playing() || Book.loading() ? 'pause' : 'play');
      btnRate.textContent = Book.rate() + '×';
      if (Book.active()) { title.textContent = Book.title(); sub.textContent = Book.author(); }
    }

    var lastChapter = -2;
    function renderTime() {
      var p = Book.position(), d = Book.duration();
      bar.style.width = (d ? Math.min(100, p / d * 100) : 0) + '%';
      tCur.textContent = U.fmtTime(p);
      tLeft.textContent = d ? T('noch {time}', { time: U.fmtTime(Math.max(0, (d - p) / Book.rate())) }) : '';
      var c = Book.chapter();
      chapterLine.textContent = c ? (c.title || '') : '';
      var ci = Book.chapterIndex();
      if (ci !== lastChapter) {
        lastChapter = ci;
        U.$$('.track', panel).forEach(function (t, i) { t.classList.toggle('on-air', i === ci); });
        var on = U.$('.on-air', panel);
        if (on && !panel.contains(Nav.current())) panel.scrollTop = Math.max(0, on.offsetTop - 160);
      }
    }

    renderTrack(); renderState(); renderTime(); renderSleep();
    setTimeout(function () { App.viewReady(el); }, 0);
    return {
      el: el,
      update: function (evt) {
        if (evt === 'bktrack') { renderTrack(); renderState(); renderTime(); }
        if (evt === 'bkstate') { renderState(); renderTime(); if (!Book.chapters().length || U.$$('.track', panel).length !== Book.chapters().length) renderChapters(); }
        if (evt === 'bktime') renderTime();
        if (evt === 'bksleep') renderSleep();
      }
    };
  }

  return { views: { books: books, booklib: booklib, bookseries: bookseries, bookserie: bookserie, booksearch: booksearch, book: book, bookplayer: bookplayer }, start: startPlayback, card: card };
})();
Object.keys(BookViews.views).forEach(function (k) { Views[k] = BookViews.views[k]; });
