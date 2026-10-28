/* Endlos-Radio: wird die Warteschlange knapp, kommen Songs dazu wie die, die zu Ende gehört oder mit
   einem Herz versehen wurden – und weniger von Künstlern, die übersprungen werden. Ohne Last.fm auf dem
   Server bleibt es stattdessen im Genre. Was es lernt, gilt nur, solange die App läuft. */
var Radio = (function () {
  'use strict';

  var seeds = [];      // Songs, auf denen das Radio aufbaut, neueste zuletzt
  var genre = null;    // ein Genre-Radio bleibt in seinem Genre
  var skips = {};      // übersprungene Songs pro Künstler: einmal = später, zweimal = gar nicht mehr
  var seen = {};       // alles, was schon lief oder eingereiht ist – nichts kommt doppelt
  var noSimilar = false; // Server findet keine ähnlichen Songs (kein Last.fm): nicht ständig nachfragen
  var filling = false;

  function ids(list) { list.forEach(function (s) { seen[s.id] = true; }); }

  // Radio aus einem Song oder Künstler (seedId – der Server findet zu beiden ähnliche Songs),
  // aus ein paar Songs oder aus einem Genre. first läuft vor den Radio-Songs.
  function start(name, o) {
    o = o || {};
    seeds = (o.first ? [o.first] : []).concat(o.seeds || []);
    genre = o.genre || null;
    skips = {}; seen = {}; noSimilar = false;
    ids(seeds);
    U.toast(T('Radio wird erstellt …'));
    var similar = o.seedId ? API.similarSongs(o.seedId, 50) : Promise.resolve(null);
    return similar.then(function (list) {
      var songs = [];
      if (list) { noSimilar = !list.length; songs = fresh(list); }
      return songs.length < 10 ? candidates(25 - songs.length).then(function (more) { return songs.concat(more); }) : songs;
    }).then(function (songs) {
      if (o.first) songs = [o.first].concat(songs.filter(function (s) { return s.id !== o.first.id; }));
      if (!songs.length) { U.toast(T('Keine ähnlichen Songs gefunden')); return false; }
      ids(songs);
      Player.playList(songs, 0, { context: { kind: 'radio', name: name } });
      return true;
    }).catch(App.error);
  }

  // Warteschlange zu Ende: mit Songs wie den letzten weiterspielen (Autoplay)
  function continueAfter(queue) {
    seeds = queue.slice(-5);
    genre = null; noSimilar = false; seen = {};
    ids(queue);
    return candidates(15).then(function (songs) { ids(songs); return songs; }).catch(function () { return []; });
  }

  function remember(song, again) {
    if (!again) seeds = seeds.filter(function (s) { return s.id !== song.id; });
    seeds.push(song);
    if (seeds.length > 20) seeds = seeds.slice(-20);
  }
  function listened(song) { remember(song); }
  // Ein Herz zählt mehr als nur Zuhören: es wird doppelt so oft zum Ausgangspunkt
  function liked(song) { remember(song); remember(song, true); }
  function skipped(song) {
    if (song.artist) skips[song.artist] = (skips[song.artist] || 0) + 1;
    seeds = seeds.filter(function (s) { return s.id !== song.id; });
  }

  // Bei jedem Songwechsel im Radio: rechtzeitig nachfüllen, bevor die Warteschlange leer ist
  function refillIfNeeded() {
    if (filling || Player.queue().length - Player.index() - 1 >= 5) return;
    filling = true;
    candidates(15).then(function (songs) {
      filling = false;
      var c = Player.context();
      if (!c || c.kind !== 'radio' || !songs.length) return;
      ids(songs);
      Player.enqueue(songs, true);
    }).catch(function () { filling = false; });
  }

  // Ähnliche Songs zu einem der letzten Lieblinge – ohne Last.fm und beim Genre-Radio Songs aus dem Genre
  function candidates(count) {
    var cur = Player.current();
    var recent = seeds.length ? seeds.slice(-5) : (cur ? [cur] : []);
    var seed = recent[Math.floor(Math.random() * recent.length)];
    var pool = [];
    var step = (!genre && !noSimilar && seed) ? API.similarSongs(seed.id, 50).then(function (list) {
      noSimilar = !list.length;
      pool = fresh(list);
    }) : Promise.resolve();
    return step.then(function () {
      if (pool.length >= count) return;
      var g = genre || (seed && seed.genre) || null;
      return API.randomSongs(60, g).catch(function () { return []; }).then(function (list) {
        pool = pool.concat(fresh(list));
        if (pool.length < count && g && !genre) {
          return API.randomSongs(40).catch(function () { return []; }).then(function (more) { pool = pool.concat(fresh(more)); });
        }
      });
    }).then(function () { return pick(pool, count); });
  }

  function skipCount(s) { return (s.artist && skips[s.artist]) || 0; }

  function fresh(list) {
    var queued = {};
    Player.queue().forEach(function (s) { queued[s.id] = true; });
    return list.filter(function (s) { return !seen[s.id] && !queued[s.id]; });
  }

  // Übersprungene Künstler nach hinten (oder raus), höchstens zwei Songs pro Künstler auf einmal
  function pick(pool, count) {
    var perArtist = {}, taken = {}, out = [];
    var sorted = U.shuffle(pool).sort(function (a, b) { return skipCount(a) - skipCount(b); });
    for (var i = 0; i < sorted.length && out.length < count; i++) {
      var s = sorted[i], artist = s.artist || '';
      if (skipCount(s) >= 2 || taken[s.id] || (perArtist[artist] || 0) >= 2) continue;
      perArtist[artist] = (perArtist[artist] || 0) + 1;
      taken[s.id] = true;
      out.push(s);
    }
    return spreadOut(out);
  }

  // Zwei Songs vom selben Künstler sollen nicht direkt hintereinander kommen
  function spreadOut(songs) {
    var rest = songs.slice(), out = [];
    while (rest.length) {
      var last = out.length ? out[out.length - 1].artist : null, i = 0;
      for (var k = 0; k < rest.length; k++) if (rest[k].artist !== last) { i = k; break; }
      out.push(rest.splice(i, 1)[0]);
    }
    return out;
  }

  return { start: start, continueAfter: continueAfter, listened: listened, liked: liked, skipped: skipped, refillIfNeeded: refillIfNeeded };
})();
