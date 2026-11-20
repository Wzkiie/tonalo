/* Suche, die Tippfehler, Akzente und halbe Wörter verzeiht ("Kolega" findet "Kollegah"), und die Favoriten und oft
   gehörte Titel nach vorn stellt. Gleiche Idee und gleiche Schwellen wie in der iPhone-App.
   Navidromes search3 findet nur Wortanfänge. Deshalb gibt es zuerst die normale Suche; fehlt ein voller Treffer,
   kommen ein paar lockerere Fragen dazu (einzelne Wörter, vertauschte Buchstaben, die ersten Buchstaben), und alles,
   was gefunden wurde, wird selbst verglichen. Der Code ist bewusst ES5, damit er auch auf älteren TVs läuft. */
var SmartSearch = (function () {
  'use strict';

  var EXTRA_MIN = 0.72;   // so gut muss ein Treffer aus einer lockeren Frage passen
  var NEAREST_MIN = 0.35; // "Ähnliche Ergebnisse", wenn sonst nichts passt
  var FULL_HIT = 0.9;     // ab hier gilt die normale Suche als ausreichend
  var FILLER = { the: 1, a: 1, an: 1, der: 1, die: 1, das: 1, ein: 1, eine: 1, und: 1, and: 1, of: 1, le: 1, la: 1, les: 1 };

  // Kleinbuchstaben, ohne Akzente und Satzzeichen, einfache Leerzeichen
  function normalize(s) {
    var t = String(s == null ? '' : s).toLowerCase();
    try { t = t.normalize('NFD').replace(/[\u0300-\u036f]/g, ''); } catch (e) { /* alter Browser: Akzente bleiben */ }
    t = t.replace(/ß/g, 'ss').replace(/ø/g, 'o').replace(/đ/g, 'd').replace(/ł/g, 'l').replace(/æ/g, 'ae').replace(/œ/g, 'oe');
    t = t.replace(/\u0131/g, 'i');
    return t.replace(/[^\p{L}\p{N}]+/gu, ' ').replace(/^ +| +$/g, '');
  }
  function tokens(s) { var n = normalize(s); return n ? n.split(' ') : []; }

  // Zerlegte Namen merken: die Künstlerliste wird bei jeder Suche neu verglichen
  var cache = {}, cacheSize = 0;
  function parts(text) {
    var k = String(text == null ? '' : text), c = cache[k];
    if (c) return c;
    if (cacheSize > 20000) { cache = {}; cacheSize = 0; }
    var t = tokens(k);
    c = cache[k] = { t: t, s: t.map(sound) };
    cacheSize++;
    return c;
  }

  var rowA = [], rowB = [], rowC = [];
  // Editierabstand, bei dem zwei vertauschte Buchstaben nur einen zählen
  function distance(a, b) {
    var n = a.length, m = b.length, i, j;
    if (!n) return m;
    if (!m) return n;
    var older = rowA, prev = rowB, cur = rowC; // drei Zeilen, einmal angelegt und weitergereicht
    for (j = 0; j <= m; j++) { older[j] = 0; prev[j] = j; cur[j] = 0; }
    for (i = 1; i <= n; i++) {
      cur[0] = i;
      for (j = 1; j <= m; j++) {
        var cost = a.charAt(i - 1) === b.charAt(j - 1) ? 0 : 1;
        cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost);
        if (i > 1 && j > 1 && a.charAt(i - 1) === b.charAt(j - 2) && a.charAt(i - 2) === b.charAt(j - 1)) cur[j] = Math.min(cur[j], older[j - 2] + 1);
      }
      var t = older; older = prev; prev = cur; cur = t;
    }
    return prev[m];
  }

  // Doppelte Buchstaben zählen einmal, "ph" ist "f", ein "h" nur zum Atmen (nicht nach c, s, p, t, l, g) fällt weg
  function sound(w) {
    var s = w.replace(/ph/g, 'f'), out = '', last = '';
    for (var i = 0; i < s.length; i++) {
      var ch = s.charAt(i);
      if (last && last === ch) continue;
      if (ch === 'h' && last && 'cspltg'.indexOf(last) < 0) continue;
      out += ch; last = ch;
    }
    return out;
  }

  function startsWith(s, p) { return s.lastIndexOf(p, 0) === 0; }

  function rawScore(all, t) {
    if (!all.length || !t.length) return 0;
    var meaningful = all.filter(function (w) { return !FILLER[w]; });
    var q = meaningful.length ? meaningful : all;
    var total = 0, i, j;
    for (i = 0; i < q.length; i++) {
      var w = q[i], best = 0;
      for (j = 0; j < t.length; j++) {
        var u = t[j];
        if (u === w || (w.length >= 2 && startsWith(u, w))) { best = 1; break; }
        if (w.length < 2) continue; // ein einzelner Buchstabe passt nur zu sich selbst
        var den = Math.max(w.length, 3);
        var d = distance(w, u.slice(0, w.length));
        // Der ganze Name kann nur besser sein, wenn die Längen nah beieinander liegen
        if (Math.abs(w.length - u.length) / den < 1 - best && u.length !== w.length) d = Math.min(d, distance(w, u));
        best = Math.max(best, Math.max(0, 1 - d / den));
      }
      total += best;
    }
    var byWords = total / q.length;
    var qc = all.join(''), tc = t.join('');
    if (qc.length < 3) return byWords;
    if (startsWith(tc, qc)) return 1;
    var cd = Math.max(qc.length, 3);
    if (1 - Math.abs(qc.length - tc.length) / cd <= byWords) return byWords; // der Abstand kann nicht mehr helfen
    return Math.max(byWords, Math.max(0, 1 - distance(qc, tc) / cd));
  }

  // Die getippten Wörter einmal zerlegen, dann mit vielen Namen vergleichen
  function prepare(query) {
    // Sehr lange Eingaben bringen nichts: die ersten sechs Wörter, höchstens 40 Zeichen
    var t = tokens(String(query == null ? '' : query).slice(0, 80)).slice(0, 6);
    while (t.join('').length > 40 && t.length > 1) t.pop();
    return { words: t, sounds: t.map(sound) };
  }
  function score(p, text) {
    var c = parts(text);
    var a = rawScore(p.words, c.t);
    return a >= 1 ? a : Math.max(a, rawScore(p.sounds, c.s));
  }

  // Lockerere Fragen für den Server, höchstens sechs
  function variants(query) {
    var toks = tokens(query), whole = normalize(query), out = [];
    function add(s) { if (s.length >= 3 && s !== whole && out.indexOf(s) < 0) out.push(s); }
    // Vertauschte Buchstaben am Wortanfang ("nroa" für "nora")
    function swaps(w) {
      for (var i = 0; i < Math.min(2, Math.max(0, w.length - 1)); i++) {
        if (w.charAt(i) === w.charAt(i + 1)) continue;
        add(w.slice(0, i) + w.charAt(i + 1) + w.charAt(i) + w.slice(i + 2));
      }
    }
    if (toks.length > 1) {
      var words = toks.filter(function (w) { return w.length >= 3 && !FILLER[w]; });
      words.forEach(add);
      words.forEach(swaps);
      var longest = words.slice().sort(function (a, b) { return b.length - a.length; })[0];
      if (longest && longest.length >= 5) add(longest.slice(0, 3));
    } else if (toks.length === 1) {
      var w = toks[0];
      swaps(w);
      if (w.length >= 4) add(w.slice(0, 3));
    }
    return out.slice(0, 6);
  }

  // ---- Bewertung der Treffer
  function artistText(a) { return a.name || ''; }
  function albumText(a) { return (a.name || a.title || '') + ' ' + (a.artist || ''); }
  function songText(s) { return (s.title || '') + ' ' + (s.artist || ''); }

  // Passung 0 bis 1; ein Name, der genau so heißt wie getippt, liegt vor jedem Favoriten, der nur so anfängt
  function fit(p, text) {
    var v = score(p, text);
    return v >= 1 && parts(text).t.join(' ') === p.words.join(' ') ? v + 0.25 : v;
  }

  // Favoriten und oft Gehörtes kommen nach vorn: ein kleiner Zuschlag, der nur zwischen ähnlich guten Treffern entscheidet
  function taste(x) {
    var b = 0;
    if (x.starred) b += 0.12;
    var pc = x.playCount || 0;
    if (pc > 0) b += Math.min(0.08, Math.log(1 + pc) / 60);
    return b;
  }

  function rank(list, p, textOf, min) {
    var scored = [];
    list.forEach(function (x, i) {
      var s = fit(p, textOf(x));
      if (s >= min) scored.push({ x: x, s: s, v: s + taste(x), i: i });
    });
    scored.sort(function (a, b) { return (b.v - a.v) || (a.i - b.i); });
    return scored;
  }

  function mergeInto(target, add) {
    ['artists', 'albums', 'songs'].forEach(function (k) {
      var seen = {};
      target[k].forEach(function (x) { seen[x.id] = 1; });
      (add[k] || []).forEach(function (x) { if (!seen[x.id]) { seen[x.id] = 1; target[k].push(x); } });
    });
  }

  function empty() { return { artists: [], albums: [], songs: [] }; }

  // Nur brauchbare Treffer: ohne Eintrag oder ohne Nummer taugt nichts
  function clean(r) {
    var out = empty();
    ['artists', 'albums', 'songs'].forEach(function (k) {
      var l = r && r[k];
      out[k] = (Array.isArray(l) ? l : []).filter(function (x) { return x && x.id != null; });
    });
    return out;
  }

  function total(r) { return r.artists.length + r.albums.length + r.songs.length; }

  /* Sucht und liefert { artists, albums, songs, similar }. similar ist true, wenn nichts richtig passte und die
     nächsten Treffer gezeigt werden. search(q, counts) ist die Server-Suche, sie darf scheitern. */
  function run(query, search, pool) {
    var p = prepare(query);
    return Promise.resolve().then(function () { return search(query); }).then(clean).then(function (base) {
      var best = 0;
      ['artists', 'albums', 'songs'].forEach(function (k) {
        base[k].forEach(function (x) { best = Math.max(best, score(p, (k === 'artists' ? artistText : k === 'albums' ? albumText : songText)(x))); });
      });
      var need = best < FULL_HIT && p.words.join('').length >= 3;
      if (!need) return { base: base, extra: empty() };
      // Lockere Fragen an den Server und die Künstlerliste (einmal geladen, hier verglichen): scheitert eins davon, zählt der Rest
      var asks = variants(query).map(function (v) { return Promise.resolve().then(function () { return search(v, true); }).then(clean, function () { return empty(); }); });
      var names = pool ? Promise.resolve().then(pool).then(function (list) { return clean({ artists: list }); }, function () { return empty(); }) : Promise.resolve(empty());
      return Promise.all(asks.concat([names])).then(function (lists) {
        var extra = empty();
        lists.forEach(function (l) { mergeInto(extra, l); });
        return { base: base, extra: extra };
      });
    }).then(function (r) {
      // Die normalen Treffer bleiben in ihrer Reihenfolge, die Favoriten rücken nur nach vorn
      var out = { artists: [], albums: [], songs: [], similar: false };
      var pools = { artists: artistText, albums: albumText, songs: songText };
      Object.keys(pools).forEach(function (k) {
        var baseIds = {};
        var main = r.base[k].map(function (x, i) { baseIds[x.id] = 1; return { x: x, v: fit(p, pools[k](x)) + taste(x) - i * 0.0001 }; });
        main.sort(function (a, b) { return b.v - a.v; });
        var extra = rank(r.extra[k].filter(function (x) { return !baseIds[x.id]; }), p, pools[k], EXTRA_MIN).map(function (e) { return e.x; });
        out[k] = main.map(function (m) { return m.x; }).concat(extra);
      });
      if (total(out)) return out;
      // Nichts passt richtig: die nächsten Treffer aus allem, was die lockeren Fragen gebracht haben
      var all = empty();
      mergeInto(all, r.base); mergeInto(all, r.extra);
      var near = { artists: [], albums: [], songs: [], similar: true };
      Object.keys(pools).forEach(function (k) {
        near[k] = rank(all[k], p, pools[k], NEAREST_MIN).slice(0, k === 'songs' ? 20 : 10).map(function (e) { return e.x; });
      });
      return near;
    });
  }

  // ---- Zuletzt gesucht (pro Konto, höchstens fünf)
  var LIMIT = 5;
  function recents() {
    var list = U.ustore.get('recents', []);
    return Array.isArray(list) ? list.filter(function (r) { return r && r.t && r.name; }).slice(0, LIMIT) : [];
  }
  function remember(item) {
    if (!item || !item.name) return;
    var key = item.t + ':' + (item.t === 'query' ? normalize(item.name) : item.id);
    var list = recents().filter(function (r) { return (r.t + ':' + (r.t === 'query' ? normalize(r.name) : r.id)) !== key; });
    list.unshift(item);
    U.ustore.set('recents', list.slice(0, LIMIT));
  }
  function forget(item) {
    var list = recents().filter(function (r) { return !(r.t === item.t && r.id === item.id && r.name === item.name); });
    U.ustore.set('recents', list);
  }
  function clear() { U.ustore.set('recents', []); }

  return { normalize: normalize, tokens: tokens, sound: sound, distance: distance, prepare: prepare, score: score, variants: variants,
    run: run, recents: recents, remember: remember, forget: forget, clear: clear };
})();
