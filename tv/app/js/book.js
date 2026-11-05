/* Hörbuch-Player: spielt ein Hörbuch oder eine Podcast-Folge von Audiobookshelf. Eigenes Audio-Element, die Musik
   (Player) bleibt dabei unangetastet; es spielt immer nur eins von beiden. Der Server bekommt die Position über eine
   Hörsitzung (alle 15 s und beim Pausieren), so macht jedes andere Gerät dort weiter. */
var Book = (function () {
  'use strict';
  var audio = new Audio();
  audio.preload = 'auto';
  var listeners = {};

  var itemId = null, episodeId = null;
  var info = null;            // {title, author} zum Anzeigen
  var session = null;         // Hörsitzung vom Server
  var trackIndex = 0;
  var pendingPos = 0;         // Position, solange noch keine Datei geladen ist
  var opening = null;         // läuft gerade das Öffnen? (Zähler, damit Veraltetes verfällt)
  var token = 0;
  var loading = false;
  var listened = 0, lastTick = 0, lastSync = 0;
  var retried = false;
  var watchdog = null;
  var sleepAt = 0, sleepChapter = false;
  var rate = +U.store.get('bookRate', 1) || 1;
  var RATES = [0.75, 1, 1.25, 1.5, 1.75, 2, 2.5];
  var BACK = 15, FORWARD = 30;
  var skipReport = false;
  var seekTarget = null;      // Stelle in der Datei, die nach dem Laden angesprungen wird

  function on(evt, fn) { (listeners[evt] = listeners[evt] || []).push(fn); }
  function emit(evt) { (listeners[evt] || []).forEach(function (fn) { try { fn(); } catch (e) { console.error(e); } }); }

  function active() { return !!session || loading; }
  function ready() { return !!session; }
  function playing() { return !!session && !audio.paused; }
  function duration() { return session ? session.duration : 0; }
  function tracks() { return session ? session.audioTracks || [] : []; }
  function position() {
    if (!session) return pendingPos;
    var t = tracks()[trackIndex];
    if (!t) return pendingPos;
    var p = t.startOffset + (seekTarget != null ? seekTarget : audio.currentTime || 0);
    return Math.max(0, Math.min(p, session.duration));
  }
  function chapters() { return session ? session.chapters || [] : []; }
  function chapterIndex() {
    var p = position() + 0.5, c = chapters(), idx = -1;
    for (var i = 0; i < c.length; i++) if (c[i].start <= p) idx = i;
    return idx;
  }
  function chapter() { var i = chapterIndex(); return i >= 0 ? chapters()[i] : null; }
  function describe(t, a) { info = { title: t || (info && info.title) || '', author: a || (info && info.author) || '' }; emit('track'); emit('state'); }
  function title() { return info ? info.title : ''; }
  function author() { return info ? info.author : ''; }

  // ---------- Starten und Beenden
  // Macht dort weiter, wo der Server sagt, dass es aufgehört wurde – oder bei `at`
  function start(id, episode, at, meta) {
    if (itemId === id && (episodeId || null) === (episode || null) && session) {
      if (at != null) seek(at);
      if (audio.paused) play();
      return Promise.resolve();
    }
    close();
    var mine = ++token;
    itemId = id;
    episodeId = episode || null;
    info = meta || { title: '', author: '' };
    loading = true;
    retried = false;
    pendingPos = at || 0;
    pauseMusic();
    emit('track');
    emit('state');
    return open(mine, at, true);
  }

  function open(mine, at, autoplay) {
    return ABS.startSession(itemId, episodeId).then(function (s) {
      if (mine !== token) {
        // inzwischen woanders hin: die Sitzung ordentlich schließen
        ABS.syncSession(s.id, s.currentTime, 0, s.duration, true).catch(function () { });
        return;
      }
      session = s;
      loading = false;
      if (s.displayTitle || s.displayAuthor) info = { title: (s.episodeId && s.displayTitle) || (info && info.title) || s.displayTitle || '', author: (info && info.author) || s.displayAuthor || '' };
      var from = at != null ? at : s.currentTime || 0;
      if (from >= s.duration - 5) from = 0; // schon fertig gehört: von vorn
      pendingPos = from;
      listened = 0;
      lastTick = 0;
      lastSync = Date.now();
      ABS.noteListening(itemId, episodeId, from, s.duration);
      loadTrack(from, autoplay);
      emit('track');
      emit('state');
    }).catch(function (e) {
      if (mine !== token) return;
      loading = false;
      var m = e && e.message;
      itemId = null; episodeId = null; info = null; session = null;
      emit('track');
      emit('state');
      U.toast(m || T('Das kann gerade nicht abgespielt werden.'), 4000);
    });
  }

  function loadTrack(time, autoplay) {
    var list = tracks();
    var i = 0;
    for (var k = 0; k < list.length; k++) if (list[k].startOffset <= time + 0.01) i = k;
    var t = list[i];
    if (!t) return;
    trackIndex = i;
    seekTarget = Math.max(0, time - t.startOffset);
    audio.src = ABS.trackUrl(session.id, t.index);
    audio.playbackRate = rate;
    audio.defaultPlaybackRate = rate;
    if (autoplay) {
      var p = audio.play();
      if (p && p.catch) p.catch(function () { });
      watch(token);
    }
  }

  // Bleibt es still, ohne dass ein Fehler kommt (z. B. ein Format, das der TV nicht abspielen kann): einmal neu versuchen
  // Opus/Ogg: am echten TV hängt das still (und ein neuer Versuch ändert daran nichts) – dort schnell und ohne Wiederholung
  function opusOnTv() { var t = tracks()[trackIndex]; return !U.desktop && !!t && /ogg|opus/i.test(t.mimeType || ''); }

  function watch(mine) {
    clearTimeout(watchdog);
    watchdog = setTimeout(function () {
      if (mine !== token || !session || audio.paused) return;
      if (audio.currentTime > 0.2 && audio.readyState >= 3) return;
      failed();
    }, opusOnTv() ? 5000 : 12000);
  }

  function failed() {
    clearTimeout(watchdog);
    if (!session) return;
    if (retried || opusOnTv()) {
      audio.pause();
      emit('state');
      // Der TV hängt bei Opus still, ohne Fehler (am echten TV gesehen) – dann lieber sagen, woran es liegt
      if (opusOnTv()) U.toast(T('Dieses Hörbuch hat das Format Opus, das der Fernseher nicht abspielen kann.'), 6000);
      else U.toast(T('Das kann gerade nicht abgespielt werden.'), 4000);
      return;
    }
    // Der Server vergisst Sitzungen nach einer Weile: eine neue öffnen und an derselben Stelle weitermachen
    retried = true;
    var at = position();
    var old = session;
    session = null;
    loading = true;
    emit('state');
    ABS.syncSession(old.id, at, 0, old.duration, true).catch(function () { });
    open(token, at, true);
  }

  // Beendet die Sitzung und meldet die letzte Position
  function close() {
    token++;
    clearTimeout(watchdog);
    if (session && !skipReport) report(true);
    audio.pause();
    audio.removeAttribute('src');
    try { audio.load(); } catch (e) { /* egal */ }
    var was = active();
    session = null; loading = false; itemId = null; episodeId = null; info = null;
    pendingPos = 0; seekTarget = null; listened = 0; lastTick = 0; sleepAt = 0; sleepChapter = false;
    if (was) { emit('track'); emit('state'); }
  }

  // ---------- Bedienung
  function play() {
    if (!session) return;
    pauseMusic();
    var p = audio.play();
    if (p && p.catch) p.catch(function () { });
    watch(token);
  }
  function pause() {
    if (!session) return;
    audio.pause();
    report(false);
  }
  function toggle() { if (!session) return; if (audio.paused) play(); else pause(); }

  function seek(t) {
    if (!session) { pendingPos = Math.max(0, t); return; }
    var target = Math.max(0, Math.min(t, session.duration - 1));
    var list = tracks(), cur = list[trackIndex];
    if (cur && target >= cur.startOffset && target < cur.startOffset + cur.duration && audio.readyState >= 1) {
      audio.currentTime = target - cur.startOffset;
      seekTarget = null;
    } else {
      var was = !audio.paused;
      loadTrack(target, was);
    }
    emit('time');
    emit('state');
  }
  function skip(sec) { seek(position() + sec); }
  function skipBack() { skip(-BACK); }
  function skipForward() { skip(FORWARD); }
  function nextChapter() { var i = chapterIndex(), c = chapters(); if (i >= 0 && i + 1 < c.length) seek(c[i + 1].start); }
  // Zum Anfang des kapitels, kurz nach dem Anfang zum vorigen
  function prevChapter() {
    var i = chapterIndex(), c = chapters();
    if (i < 0) { seek(0); return; }
    seek(position() - c[i].start > 5 || i === 0 ? c[i].start : c[i - 1].start);
  }

  function setRate(r) {
    r = +r;
    if (!(r >= 0.5 && r <= 3)) return;
    rate = r;
    U.store.set('bookRate', r);
    audio.playbackRate = r;
    audio.defaultPlaybackRate = r;
    emit('state');
  }

  // Einschlaf-Timer: Minuten, oder bis zum Ende des Kapitels
  function setSleep(min) { sleepAt = Date.now() + min * 60000; sleepChapter = false; emit('sleep'); }
  function setSleepChapter() { sleepChapter = true; sleepAt = 0; emit('sleep'); }
  function cancelSleep() { sleepAt = 0; sleepChapter = false; emit('sleep'); }
  // Restzeit in ms, -1 = am Ende des Kapitels, 0 = aus
  function sleepLeft() { return sleepChapter ? -1 : sleepAt ? Math.max(1, sleepAt - Date.now()) : 0; }
  function sleepFired() { cancelSleep(); audio.pause(); report(false); }

  // ---------- Meldungen an den Server
  function report(closing) {
    if (!session) return;
    var s = session, at = position(), amount = listened;
    listened = 0;
    lastSync = Date.now();
    ABS.noteListening(itemId, episodeId, at, s.duration);
    ABS.syncSession(s.id, at, amount, s.duration, closing).catch(function (e) {
      // Sitzung beim Server weg: wenigstens die Position sichern
      if (e && e.status === 404) ABS.saveProgress(itemId, episodeId, at, s.duration).catch(function () { });
      else if (!closing) listened += amount;
    });
    ABS.emit();
  }

  function pauseMusic() { try { if (!Player.paused()) Player.pause(); } catch (e) { /* noch nicht da */ } }

  // ---------- Audio-Ereignisse
  audio.addEventListener('loadedmetadata', function () {
    if (seekTarget != null && session) {
      try { audio.currentTime = seekTarget; } catch (e) { /* egal */ }
      seekTarget = null;
    }
  });
  audio.addEventListener('playing', function () {
    clearTimeout(watchdog);
    retried = false;
    lastTick = Date.now();
    emit('state');
  });
  audio.addEventListener('pause', function () { lastTick = 0; emit('state'); });
  audio.addEventListener('waiting', function () { emit('state'); });
  audio.addEventListener('timeupdate', function () {
    if (!session) return;
    var now = Date.now();
    if (!audio.paused) {
      if (lastTick) listened += Math.min(5, (now - lastTick) / 1000); // Wiedergabezeit, nicht Hörzeit mal Tempo
      lastTick = now;
      if (listened > 0 && now - lastSync >= 15000) report(false);
    } else {
      lastTick = 0;
    }
    if (sleepAt && now >= sleepAt) sleepFired();
    var c = chapter();
    if (sleepChapter && !audio.paused && c && position() >= c.end - 0.6) sleepFired();
    emit('time');
  });
  audio.addEventListener('ended', function () {
    if (!session) return;
    var list = tracks();
    if (trackIndex + 1 < list.length) {
      loadTrack(list[trackIndex + 1].startOffset, true);
      return;
    }
    // Ende: als gehört melden und aufräumen
    ABS.noteListening(itemId, episodeId, session.duration, session.duration);
    var s = session, id = itemId, ep = episodeId;
    ABS.syncSession(s.id, s.duration, listened, s.duration, true).catch(function () { ABS.saveProgress(id, ep, s.duration, s.duration).catch(function () { }); });
    skipReport = true;
    close();
    skipReport = false;
    ABS.emit();
  });
  audio.addEventListener('error', function () {
    if (!session || !audio.getAttribute('src')) return;
    failed();
  });

  // Läuft Musik an, ruht das Hörbuch
  function init() {
    // Die Lautstärke-Regler am PC gelten auch fürs Hörbuch
    try { audio.volume = Player.volume(); Player.on('volume', function () { audio.volume = Player.volume(); }); } catch (e) { /* ohne */ }
    try { Player.on('state', function () { if (session && !audio.paused && !Player.paused()) { audio.pause(); report(false); } }); } catch (e) { /* egal */ }
  }

  return {
    on: on, init: init, start: start, close: close, active: active, ready: ready, playing: playing, loading: function () { return loading; },
    play: play, pause: pause, toggle: toggle, seek: seek, skip: skip, skipBack: skipBack, skipForward: skipForward,
    nextChapter: nextChapter, prevChapter: prevChapter, position: position, duration: duration,
    describe: describe, chapters: chapters, chapter: chapter, chapterIndex: chapterIndex, title: title, author: author,
    itemId: function () { return itemId; }, episodeId: function () { return episodeId; },
    rate: function () { return rate; }, setRate: setRate, rates: RATES, back: BACK, forward: FORWARD,
    setSleep: setSleep, setSleepChapter: setSleepChapter, cancelSleep: cancelSleep, sleepLeft: sleepLeft,
    buffering: function () { return !!session && !audio.paused && audio.readyState < 3; }
  };
})();
