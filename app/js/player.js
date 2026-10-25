/* Audio-Player mit Warteschlange, Shuffle, Repeat, Scrobbling und Resume */
var Player = (function () {
  'use strict';

  var audio = new Audio();
  audio.preload = 'auto';

  var queue = [];        // Songs in Abspielreihenfolge
  var original = null;   // Originalreihenfolge, wenn Shuffle aktiv
  var index = -1;
  var shuffleOn = false;
  var repeat = 'off';    // off | all | one
  var offset = 0;        // bei transkodierten Streams: Startposition (timeOffset)
  var scrobbled = false;
  var errorStreak = 0;
  var pendingSeek = 0;
  var listeners = {};

  function on(evt, fn) { (listeners[evt] = listeners[evt] || []).push(fn); }
  function emit(evt, data) { (listeners[evt] || []).forEach(function (fn) { try { fn(data); } catch (e) { console.error(e); } }); }

  function settings() { return App.settings(); }

  function current() { return queue[index] || null; }
  function duration() {
    var s = current();
    if (s && s.duration) return s.duration;
    return isFinite(audio.duration) ? audio.duration : 0;
  }
  function position() { return offset + (audio.currentTime || 0); }
  function transcoding() { return !!settings().maxBitRate; }

  function load(startAt, autoplay) {
    var s = current();
    if (!s) return;
    scrobbled = false;
    offset = 0;
    pendingSeek = 0;
    var opts = { maxBitRate: settings().maxBitRate, format: settings().format };
    if (startAt > 1) {
      if (transcoding()) { opts.offset = startAt; offset = Math.floor(startAt); }
      else pendingSeek = startAt;
    }
    audio.src = API.streamUrl(s.id, opts);
    if (autoplay !== false) {
      var p = audio.play();
      if (p && p.catch) p.catch(function (e) { console.warn('play()', e); });
    }
    if (settings().scrobble && autoplay !== false) API.scrobble(s.id, false);
    emit('track', s);
    persist();
  }

  function playList(songs, start, opts) {
    songs = (songs || []).filter(Boolean);
    if (!songs.length) { U.toast('Keine Titel zum Abspielen'); return; }
    start = start || 0;
    shuffleOn = !!(opts && opts.shuffle);
    if (shuffleOn) {
      var first = (opts && opts.shuffle && start === 0 && !(opts && opts.keepStart)) ? null : songs[start];
      original = songs.slice();
      var rest = U.shuffle(songs.filter(function (s, i) { return !first || i !== start; }));
      queue = first ? [first].concat(rest) : rest;
      index = 0;
    } else {
      original = null;
      queue = songs.slice();
      index = Math.min(start, queue.length - 1);
    }
    errorStreak = 0;
    load(0, true);
    emit('queue', queue);
    emit('mode');
  }

  function playNext(songs) {
    songs = U.asArray(songs);
    if (!queue.length) return playList(songs, 0);
    Array.prototype.splice.apply(queue, [index + 1, 0].concat(songs));
    if (original) original = original.concat(songs);
    emit('queue', queue); persist();
    U.toast(songs.length === 1 ? 'Wird als Nächstes gespielt' : songs.length + ' Titel als Nächstes');
  }

  function enqueue(songs) {
    songs = U.asArray(songs);
    if (!queue.length) return playList(songs, 0);
    queue = queue.concat(songs);
    if (original) original = original.concat(songs);
    emit('queue', queue); persist();
    U.toast(songs.length === 1 ? 'Zur Warteschlange hinzugefügt' : songs.length + ' Titel hinzugefügt');
  }

  function jump(i) {
    if (i < 0 || i >= queue.length) return;
    index = i; load(0, true); emit('queue', queue);
  }

  function removeAt(i) {
    if (i < 0 || i >= queue.length) return;
    var wasCurrent = i === index;
    var removed = queue.splice(i, 1)[0];
    if (original) original = original.filter(function (s) { return s !== removed; });
    if (i < index) index--;
    if (wasCurrent) {
      if (!queue.length) { stop(); }
      else { if (index >= queue.length) index = 0; load(0, !audio.paused); }
    }
    emit('queue', queue); persist();
  }

  function next(auto) {
    if (!queue.length) return;
    if (auto && repeat === 'one') { load(0, true); return; }
    if (index < queue.length - 1) index++;
    else if (repeat === 'all' || !auto) index = 0;
    else { audio.pause(); emit('state'); return; }
    load(0, true);
    emit('queue', queue);
  }

  function prev() {
    if (!queue.length) return;
    if (position() > 3) { seek(0); return; }
    index = index > 0 ? index - 1 : (repeat === 'all' ? queue.length - 1 : 0);
    load(0, true);
    emit('queue', queue);
  }

  function toggle() {
    if (!current()) return;
    if (!audio.src) { load(U.ustore.get('pos', 0), true); return; }
    if (audio.paused) audio.play(); else audio.pause();
  }
  function play() { if (audio.paused) toggle(); }
  function pause() { if (!audio.paused) audio.pause(); }

  function stop() {
    audio.pause();
    audio.removeAttribute('src');
    try { audio.load(); } catch (e) { /* egal */ }
    queue = []; original = null; index = -1;
    emit('track', null); emit('queue', queue); emit('state');
    persist();
  }

  function seek(sec) {
    var d = duration();
    sec = Math.max(0, d ? Math.min(sec, d - 1) : sec);
    if (transcoding()) {
      var wasPaused = audio.paused;
      load(sec, !wasPaused);
    } else {
      try { audio.currentTime = sec; } catch (e) { /* noch nicht geladen */ }
    }
    emit('time');
  }
  function seekBy(delta) { seek(position() + delta); }

  function setShuffle(on) {
    if (on === shuffleOn) return;
    var cur = current();
    shuffleOn = on;
    if (on) {
      original = queue.slice();
      var rest = U.shuffle(queue.filter(function (s, i) { return i !== index; }));
      queue = cur ? [cur].concat(rest) : rest;
      index = 0;
    } else if (original) {
      queue = original;
      original = null;
      index = Math.max(0, queue.indexOf(cur));
    }
    emit('queue', queue); emit('mode'); persist();
  }

  function cycleRepeat() {
    repeat = repeat === 'off' ? 'all' : repeat === 'all' ? 'one' : 'off';
    emit('mode'); persist();
  }

  function setStarred(song, on) {
    queue.forEach(function (s) { if (s.id === song.id) s.starred = on ? new Date().toISOString() : undefined; });
    emit('track', current());
  }

  // ---- Persistenz (Warteschlange beim nächsten Start wiederherstellen)
  var persistTimer;
  function persistNow() {
    clearTimeout(persistTimer);
    U.ustore.set('queue', queue.slice(0, 1000));
    U.ustore.set('index', index);
    U.ustore.set('repeat', repeat);
    U.ustore.set('shuffle', shuffleOn);
    // Ohne geladenen Stream ist die Position 0 – gespeicherte Position dann nicht überschreiben
    if (audio.src) U.ustore.set('pos', Math.floor(position()));
  }
  function persist() {
    clearTimeout(persistTimer);
    persistTimer = setTimeout(persistNow, 300);
  }

  // Beim Benutzerwechsel: Zustand des alten Kontos sichern und Player leeren (ohne gespeicherte Daten zu löschen)
  function detach() {
    if (queue.length) persistNow();
    clearTimeout(persistTimer);
    audio.pause();
    audio.removeAttribute('src');
    try { audio.load(); } catch (e) { /* egal */ }
    queue = []; original = null; index = -1; offset = 0;
    emit('track', null); emit('queue', queue); emit('state');
  }

  function restore() {
    queue = U.ustore.get('queue', []) || [];
    index = U.ustore.get('index', -1);
    repeat = U.ustore.get('repeat', 'off');
    shuffleOn = U.ustore.get('shuffle', false);
    if (index >= queue.length) index = queue.length ? 0 : -1;
    if (current()) { emit('track', current()); emit('queue', queue); emit('mode'); }
  }

  // ---- Audio-Events
  audio.addEventListener('loadedmetadata', function () {
    if (pendingSeek) { try { audio.currentTime = pendingSeek; } catch (e) { /* egal */ } pendingSeek = 0; }
  });
  audio.addEventListener('playing', function () { errorStreak = 0; emit('state'); });
  audio.addEventListener('pause', function () { emit('state'); persist(); });
  audio.addEventListener('waiting', function () { emit('state'); });
  audio.addEventListener('ended', function () { next(true); });
  audio.addEventListener('timeupdate', function () {
    emit('time');
    var s = current(), d = duration(), p = position();
    if (s && !scrobbled && settings().scrobble && d && (p > d / 2 || p > 240)) {
      scrobbled = true;
      API.scrobble(s.id, true);
    }
    if (Math.floor(p) % 5 === 0) persist();
  });
  audio.addEventListener('error', function () {
    if (!audio.src || !current()) return;
    errorStreak++;
    var code = audio.error ? audio.error.code : '?';
    U.toast('Wiedergabefehler (' + code + ') – ' + (errorStreak < 4 ? 'überspringe Titel' : 'gestoppt'));
    if (errorStreak < 4 && queue.length > 1) setTimeout(function () { next(true); }, 1200);
    emit('state');
  });

  return {
    on: on,
    playList: playList,
    playNext: playNext,
    enqueue: enqueue,
    jump: jump,
    removeAt: removeAt,
    next: function () { next(false); },
    prev: prev,
    toggle: toggle,
    play: play,
    pause: pause,
    stop: stop,
    seek: seek,
    seekBy: seekBy,
    setShuffle: setShuffle,
    cycleRepeat: cycleRepeat,
    setStarred: setStarred,
    restore: restore,
    detach: detach,
    current: current,
    queue: function () { return queue; },
    index: function () { return index; },
    position: position,
    duration: duration,
    paused: function () { return audio.paused; },
    buffering: function () { return !audio.paused && audio.readyState < 3; },
    shuffle: function () { return shuffleOn; },
    repeat: function () { return repeat; },
    reloadCurrent: function () { if (current() && audio.src) load(position(), !audio.paused); }
  };
})();
